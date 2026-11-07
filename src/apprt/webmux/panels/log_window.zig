//! The connection log window (PARITY G-20…G-29; electron/logs.html,
//! electron/main.js openLogWindow).
//!
//! One window of its own (900×560, `webmux — connection log`), a native
//! `AdwWindow` with libadwaita's look (deviation 72). Opening it again
//! presents the existing one; after it is closed a new one can be opened;
//! it goes away with the last main window. It loads the engine's ring and
//! then tails it live: every log push wakes the main loop, which pulls the
//! entries newer than the last one it has (`Log.since`), so entries arrive
//! in sequence order whatever thread pushed them and the initial load
//! never duplicates one (G-21).
//!
//! Header bar: Copy visible (primary) and a menu with Copy all, Reveal
//! file (the file manager) and Clear. Below it a toolbar that wraps in a
//! narrow window: Host (`all`, then each host in order of first
//! appearance, `client (no host)` for app-wide entries), Level (`debug+`,
//! `info+` default, `warn+`, `error`), the text filter (case-insensitive
//! substring of the file-format line, applied 80 ms after typing stops),
//! and Follow. Lines are a read-only text view (selectable across lines),
//! laid out as logs.html lays them out, in libadwaita's colours (the
//! accent, success, warning and error colours and the dim text of the
//! current scheme; read back from the style, so they follow the scheme
//! and the accent colour). Status bar: the count, a 2 s copy flash and the
//! file path. Keys: Escape closes, Ctrl+F the text filter, Ctrl+Shift+C
//! copies the visible lines, and the app shortcuts work as in the main
//! window.
//!
//! The window keeps at most `model.max_rows` entries (the ring's size); the
//! Electron window grows without bound while open.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const conn = @import("../../../webmux/conn.zig");
const Log = conn.Log;
const ext = @import("../ext.zig");
const iface = @import("../iface.zig");
const mainloop = @import("../mainloop.zig");
const shortcuts = @import("../shortcuts.zig");
const KeyEvent = @import("../key_event.zig").KeyEvent;
const Application = @import("../application.zig").Application;
const Window = @import("../window.zig").Window;
const model = @import("model.zig");
const url = @import("url.zig");
const WrapBox = @import("wrap_box.zig").WrapBox;

const log = std.log.scoped(.webmux_panels);
const alloc = std.heap.c_allocator;

pub const title = "webmux — connection log";
pub const default_width = 900;
pub const default_height = 560;
pub const flash_ms = 2000;
pub const search_delay_ms = 80;

const no_engine_text = "There is no connection log: the connection engine is not running.";

pub const Row = struct {
    seq: u64,
    level: Log.Level,
    src: Log.Source,
    conn: ?[]u8,
    /// ISO timestamp (the tooltip)
    t: [:0]u8,
    /// local HH:MM:SS.mmm
    time: [:0]u8,
    msg: []u8,
    /// logs.html dataOf
    data: []u8,
    /// the file-format line (filtering and copying)
    line: []u8,

    fn deinit(r: *Row) void {
        if (r.conn) |c| alloc.free(c);
        alloc.free(r.t);
        alloc.free(r.time);
        alloc.free(r.msg);
        alloc.free(r.data);
        alloc.free(r.line);
        alloc.destroy(r);
    }
};

/// The style colours the lines are drawn in, each read from a hidden
/// label carrying that style class (libadwaita defines them in CSS only).
const Probe = enum { dim, accent, success, warning, @"error" };
const probe_classes = [_][:0]const u8{ "dim-label", "accent", "success", "warning", "error" };

pub const LogWindow = struct {
    window: *gtk.Window,
    host_dd: *gtk.DropDown,
    host_list: *gtk.StringList,
    /// parallel to host_list; [0] is "all" (null)
    host_keys: std.ArrayList(?[]u8) = .empty,
    level_dd: *gtk.DropDown,
    search: *gtk.SearchEntry,
    follow: *gtk.CheckButton,
    copy_visible: *gtk.Button,
    /// Copy all, Reveal file, Clear (`log.` actions on the window).
    menu: *gtk.MenuButton,
    actions: *gio.SimpleActionGroup,
    scroll: *gtk.ScrolledWindow,
    view: *gtk.TextView,
    buffer: *gtk.TextBuffer,
    empty: *adw.StatusPage,
    count: *gtk.Label,
    flash: *gtk.Label,
    file: *gtk.Label,
    probes: [probe_classes.len]*gtk.Label,
    style_ids: [2]c_ulong = .{ 0, 0 },
    recolour_source: c_uint = 0,

    rows: std.ArrayList(*Row) = .empty,
    /// the rows in the text view, in order: buffer line i is shown[i]
    shown: std.ArrayList(*Row) = .empty,
    last_seq: u64 = 0,
    query_buf: [256]u8 = undefined,
    query: []const u8 = "",
    sub_id: ?u64 = null,
    flash_timer: c_uint = 0,
    hover_line: ?usize = null,
    /// a programmatic scroll to the end is in progress
    pinning: bool = false,
    /// monotonic µs until which a value change away from the bottom
    /// counts as the user's (an upward wheel or touchpad scroll, scrollbar
    /// drag, or key)
    user_scroll_until: i64 = 0,

    pub fn filter(self: *const LogWindow) model.Filter {
        const hi = self.host_dd.getSelected();
        const host: ?[]const u8 = if (hi < self.host_keys.items.len) self.host_keys.items[hi] else null;
        const li = self.level_dd.getSelected();
        const min: Log.Level = if (li < 4) @fromBackingInt(@intCast(li)) else model.default_level;
        return .{ .host = host, .min = min, .text = self.query };
    }
};

pub var instance: ?*LogWindow = null;

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------

/// `app.show-log`: open the window, or bring the open one forward.
pub fn show() void {
    if (instance) |w| {
        w.window.present();
        return;
    }
    const w = build() catch {
        log.err("log window: out of memory", .{});
        return;
    };
    instance = w;
    if (iface.engine) |e| {
        w.sub_id = e.subscribeLog(.{ .ctx = null, .func = onLogPushed }) catch null;
        if (e.log().filePath()) |p| setFile(w, p);
        _ = pull(w);
        render(w);
    } else {
        setButtonsSensitive(w, false);
        render(w);
    }
    w.window.present();
    _ = w.view.as(gtk.Widget).grabFocus();
}

pub fn close() void {
    const w = instance orelse return;
    w.window.destroy();
}

/// The last main window went away: the log window goes with it.
pub fn onAppWindowRemoved(app: *gtk.Application) void {
    const w = instance orelse return;
    var it: ?*glib.List = app.getWindows();
    while (it) |node| : (it = node.f_next) {
        const gw: *gtk.Window = @ptrCast(@alignCast(node.f_data orelse continue));
        if (gobject.ext.cast(Window, gw) != null) return;
    }
    w.window.destroy();
}

fn onDestroy(_: *gtk.Window, w: *LogWindow) callconv(.c) void {
    if (instance == w) instance = null;
    if (w.sub_id) |id| if (iface.engine) |e| e.unsubscribeLog(id);
    const sm = adw.StyleManager.getDefault();
    for (w.style_ids) |id| if (id != 0) gobject.signalHandlerDisconnect(sm.as(gobject.Object), id);
    if (w.recolour_source != 0) _ = glib.Source.remove(w.recolour_source);
    if (w.flash_timer != 0) _ = glib.Source.remove(w.flash_timer);
    for (w.rows.items) |r| r.deinit();
    w.rows.deinit(alloc);
    w.shown.deinit(alloc);
    for (w.host_keys.items) |k| if (k) |s| alloc.free(s);
    w.host_keys.deinit(alloc);
    w.actions.unref();
    alloc.destroy(w);
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

fn toolbarLabel(text: [:0]const u8) *gtk.Widget {
    const l = gtk.Label.new(text.ptr);
    l.as(gtk.Widget).addCssClass("dim-label");
    return l.as(gtk.Widget);
}

/// A drop-down item factory: one label, ellipsized after `chars`.
/// `chars` = 0: never ellipsized (the popup list shows full names).
fn labelFactory(comptime chars: c_int) *gtk.ListItemFactory {
    const f = gtk.SignalListItemFactory.new();
    const H = struct {
        fn setup(_: *gtk.SignalListItemFactory, obj: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
            const item = gobject.ext.cast(gtk.ListItem, obj) orelse return;
            const l = gtk.Label.new("");
            l.setXalign(0);
            if (chars > 0) {
                l.setEllipsize(.end);
                l.setMaxWidthChars(chars);
            }
            item.setChild(l.as(gtk.Widget));
        }
        fn bind(_: *gtk.SignalListItemFactory, obj: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
            const item = gobject.ext.cast(gtk.ListItem, obj) orelse return;
            const l = gobject.ext.cast(gtk.Label, item.getChild() orelse return) orelse return;
            const so = gobject.ext.cast(gtk.StringObject, item.getItem() orelse return) orelse return;
            l.setText(so.getString());
            l.as(gtk.Widget).setTooltipText(so.getString());
        }
    };
    _ = gtk.SignalListItemFactory.signals.setup.connect(f, ?*anyopaque, H.setup, null, .{});
    _ = gtk.SignalListItemFactory.signals.bind.connect(f, ?*anyopaque, H.bind, null, .{});
    return f.as(gtk.ListItemFactory);
}

const menu_actions = [_]ext.actions.Action(LogWindow){
    .init("copy-all", actCopyAll, null),
    .init("reveal", actReveal, null),
    .init("clear", actClear, null),
};

fn build() !*LogWindow {
    const app = Application.default();
    const aw = adw.Window.new();
    const window = aw.as(gtk.Window);
    window.setApplication(app.as(gtk.Application));
    window.setTitle(title);
    window.setDefaultSize(default_width, default_height);

    const tv = adw.ToolbarView.new();
    tv.setTopBarStyle(.raised_border);
    tv.setBottomBarStyle(.raised_border);

    // --- header bar: the title, Copy visible, and the other actions in a
    // menu.
    const header = adw.HeaderBar.new();
    const wt = adw.WindowTitle.new("Connection Log", "");
    header.setTitleWidget(wt.as(gtk.Widget));
    const copy_visible = gtk.Button.newFromIconName("edit-copy-symbolic");
    copy_visible.as(gtk.Widget).setTooltipText("Copy the lines currently shown (Ctrl+Shift+C)");
    const menu_model = gio.Menu.new();
    defer menu_model.unref();
    menu_model.append("Copy All Entries", "log.copy-all");
    menu_model.append("Reveal Log File", "log.reveal");
    menu_model.append("Clear Log", "log.clear");
    const menu = gtk.MenuButton.new();
    menu.setIconName("view-more-symbolic");
    menu.setMenuModel(menu_model.as(gio.MenuModel));
    menu.as(gtk.Widget).setTooltipText("More");
    header.packEnd(menu.as(gtk.Widget));
    header.packEnd(copy_visible.as(gtk.Widget));
    tv.addTopBar(header.as(gtk.Widget));

    // --- toolbar: the filters (logs.html #toolbar); it wraps onto more
    // lines rather than clipping a control or widening the window.
    const bar = WrapBox.new(6, 6);
    bar.as(gtk.Widget).addCssClass("toolbar");

    const host_strings = [_:null]?[*:0]const u8{"all"};
    const host_list = gtk.StringList.new(@ptrCast(&host_strings));
    const host_dd = gtk.DropDown.new(host_list.as(gio.ListModel), null);
    // Long profile names are ellipsized in the button (full in the list),
    // so the select never outgrows the window.
    const button_factory = labelFactory(24);
    defer button_factory.as(gobject.Object).unref();
    const list_factory = labelFactory(0);
    defer list_factory.as(gobject.Object).unref();
    host_dd.setFactory(button_factory);
    host_dd.setListFactory(list_factory);
    const host_box = gtk.Box.new(.horizontal, 6);
    host_box.append(toolbarLabel("Host"));
    host_box.append(host_dd.as(gtk.Widget));
    bar.append(host_box.as(gtk.Widget));

    var level_strings: [model.level_labels.len + 1]?[*:0]const u8 = undefined;
    for (model.level_labels, 0..) |l, i| level_strings[i] = l.ptr;
    level_strings[model.level_labels.len] = null;
    const level_dd = gtk.DropDown.newFromStrings(@ptrCast(&level_strings));
    level_dd.setSelected(@backingInt(model.default_level));
    const level_box = gtk.Box.new(.horizontal, 6);
    level_box.append(toolbarLabel("Level"));
    level_box.append(level_dd.as(gtk.Widget));
    bar.append(level_box.as(gtk.Widget));

    const search = gtk.SearchEntry.new();
    search.setPlaceholderText("Filter text");
    search.setSearchDelay(search_delay_ms);
    // 200px wide, as logs.html's; its own character width must not ask
    // for more.
    search.as(gtk.Widget).setSizeRequest(200, -1);
    search.as(gtk.Editable).setWidthChars(1);
    search.as(gtk.Editable).setMaxWidthChars(1);
    bar.append(search.as(gtk.Widget));

    const follow = gtk.CheckButton.newWithLabel("Follow");
    follow.setActive(1);
    follow.as(gtk.Widget).setTooltipText("Keep the newest entry in view");
    bar.append(follow.as(gtk.Widget));
    tv.addTopBar(bar.as(gtk.Widget));

    // --- lines
    const view = gtk.TextView.new();
    view.setEditable(0);
    view.setCursorVisible(0);
    view.setMonospace(1);
    view.setWrapMode(.word_char);
    view.setLeftMargin(12);
    view.setRightMargin(12);
    view.setTopMargin(6);
    view.setBottomMargin(6);
    view.setPixelsAboveLines(1);
    view.setPixelsBelowLines(2);
    view.setPixelsInsideWrap(1);
    view.as(gtk.Widget).setHasTooltip(1);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setChild(view.as(gtk.Widget));
    scroll.setPolicy(.never, .automatic);
    scroll.as(gtk.Widget).setVexpand(1);

    const empty = adw.StatusPage.new();
    empty.setTitle(model.empty_no_entries);
    empty.as(gtk.Widget).addCssClass("compact");
    empty.as(gtk.Widget).setVexpand(1);

    const body = gtk.Box.new(.vertical, 0);
    body.as(gtk.Widget).setVexpand(1);
    body.append(scroll.as(gtk.Widget));
    body.append(empty.as(gtk.Widget));
    tv.setContent(body.as(gtk.Widget));

    // --- status bar
    const status = gtk.Box.new(.horizontal, 12);
    status.as(gtk.Widget).addCssClass("toolbar");
    const count = gtk.Label.new("");
    count.as(gtk.Widget).addCssClass("dim-label");
    const flash = gtk.Label.new("");
    flash.as(gtk.Widget).addCssClass("accent");
    const file = gtk.Label.new("");
    file.as(gtk.Widget).addCssClass("dim-label");
    file.as(gtk.Widget).addCssClass("monospace");
    file.setEllipsize(.end);
    file.as(gtk.Widget).setHexpand(1);
    file.setXalign(1);
    status.append(count.as(gtk.Widget));
    status.append(flash.as(gtk.Widget));
    status.append(file.as(gtk.Widget));
    // The colour probes: in the tree (so the style applies), never shown.
    var probes: [probe_classes.len]*gtk.Label = undefined;
    for (probe_classes, &probes) |class, *p| {
        p.* = gtk.Label.new("");
        p.*.as(gtk.Widget).addCssClass(class.ptr);
        p.*.as(gtk.Widget).setVisible(0);
        status.append(p.*.as(gtk.Widget));
    }
    tv.addBottomBar(status.as(gtk.Widget));

    aw.setContent(tv.as(gtk.Widget));

    const w = try alloc.create(LogWindow);
    w.* = .{
        .window = window,
        .host_dd = host_dd,
        .host_list = host_list,
        .level_dd = level_dd,
        .search = search,
        .follow = follow,
        .copy_visible = copy_visible,
        .menu = menu,
        .actions = gio.SimpleActionGroup.new(),
        .scroll = scroll,
        .view = view,
        .buffer = view.getBuffer(),
        .empty = empty,
        .count = count,
        .flash = flash,
        .file = file,
        .probes = probes,
    };
    try w.host_keys.append(alloc, null);
    ext.actions.addToMap(LogWindow, w, w.actions.as(gio.ActionMap), &menu_actions);
    window.as(gtk.Widget).insertActionGroup("log", w.actions.as(gio.ActionGroup));
    createTags(w);
    colourTags(w);
    const sm = adw.StyleManager.getDefault();
    w.style_ids[0] = gobject.Object.signals.notify.connect(sm, *LogWindow, onStyleChanged, w, .{ .detail = "dark" });
    w.style_ids[1] = gobject.Object.signals.notify.connect(sm, *LogWindow, onStyleChanged, w, .{ .detail = "accent-color" });

    _ = gtk.Widget.signals.destroy.connect(window, *LogWindow, onDestroy, w, .{});
    _ = gobject.Object.signals.notify.connect(host_dd, *LogWindow, onFilterChanged, w, .{ .detail = "selected" });
    _ = gobject.Object.signals.notify.connect(level_dd, *LogWindow, onFilterChanged, w, .{ .detail = "selected" });
    _ = gtk.SearchEntry.signals.search_changed.connect(search, *LogWindow, onSearch, w, .{});
    _ = gtk.CheckButton.signals.toggled.connect(follow, *LogWindow, onFollowToggled, w, .{});
    _ = gtk.Button.signals.clicked.connect(copy_visible, *LogWindow, onCopyVisible, w, .{});
    const adj = scroll.getVadjustment();
    _ = gtk.Adjustment.signals.value_changed.connect(adj, *LogWindow, onScrolled, w, .{});
    _ = gtk.Adjustment.signals.changed.connect(adj, *LogWindow, onAdjChanged, w, .{});
    _ = gtk.Widget.signals.query_tooltip.connect(view, *LogWindow, onQueryTooltip, w, .{});
    const motion = gtk.EventControllerMotion.new();
    _ = gtk.EventControllerMotion.signals.motion.connect(motion, *LogWindow, onMotion, w, .{});
    _ = gtk.EventControllerMotion.signals.leave.connect(motion, *LogWindow, onLeave, w, .{});
    view.as(gtk.Widget).addController(motion.as(gtk.EventController));
    // What counts as the user scrolling (G-24 follow).
    const wheel = gtk.EventControllerScroll.new(.{ .vertical = true });
    wheel.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerScroll.signals.scroll.connect(wheel, *LogWindow, onUserWheel, w, .{});
    scroll.as(gtk.Widget).addController(wheel.as(gtk.EventController));
    const drag = gtk.GestureDrag.new();
    drag.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.GestureDrag.signals.drag_update.connect(drag, *LogWindow, onUserDrag, w, .{});
    scroll.getVscrollbar().addController(drag.as(gtk.EventController));
    const view_keys = gtk.EventControllerKey.new();
    _ = gtk.EventControllerKey.signals.key_pressed.connect(view_keys, *LogWindow, onViewKey, w, .{});
    view.as(gtk.Widget).addController(view_keys.as(gtk.EventController));

    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *LogWindow, onKey, w, .{});
    window.as(gtk.Widget).addController(keys.as(gtk.EventController));
    return w;
}

/// Without an engine there is nothing to copy, reveal or clear.
fn setButtonsSensitive(w: *LogWindow, on: bool) void {
    w.copy_visible.as(gtk.Widget).setSensitive(@intFromBool(on));
    for (menu_actions) |a| {
        const action = w.actions.as(gio.ActionMap).lookupAction(a.name.ptr) orelse continue;
        gobject.ext.cast(gio.SimpleAction, action).?.setEnabled(@intFromBool(on));
    }
}

// ---------------------------------------------------------------------------
// Tags and colours (logs.html .ln … rules, in the style's colours)
// ---------------------------------------------------------------------------

const tag_names = [_][:0]const u8{ "line", "t", "who", "who-page", "lvl", "lvl-info", "debug", "warn", "error", "data", "hit", "hover" };

fn createTags(w: *LogWindow) void {
    const table = w.buffer.getTagTable();
    for (tag_names) |n| {
        const t = gtk.TextTag.new(n.ptr);
        _ = table.add(t);
        t.unref();
    }
    setProp(w, "lvl", "weight", @as(c_int, 600));
    // A hanging indent: wrapped lines continue under the message, past
    // the time and level columns ("HH:MM:SS.mmm LEVEL ", 19 cells of the
    // monospace font at the usual 0.6em advance). Measuring the font would
    // need a direct libpango call, which the executable's rpath does not
    // cover.
    const indent: c_int = 137;
    // Pango's negative indent: the first line starts at the margin and
    // the wrapped ones `-indent` further in.
    setProp(w, "line", "left-margin", @as(c_int, 12));
    setProp(w, "line", "indent", @as(c_int, -indent));
}

fn tagNamed(w: *LogWindow, name: [:0]const u8) *gtk.TextTag {
    return w.buffer.getTagTable().lookup(name.ptr).?;
}

fn setProp(w: *LogWindow, name: [:0]const u8, prop: [:0]const u8, value: anytype) void {
    tagNamed(w, name).as(gobject.Object).set(prop.ptr, value, @as(?*anyopaque, null));
}

fn probeColour(w: *LogWindow, which: Probe) gdk.RGBA {
    var c: gdk.RGBA = undefined;
    w.probes[@backingInt(which)].as(gtk.Widget).getColor(&c);
    return c;
}

fn withAlpha(c: gdk.RGBA, alpha: f32) gdk.RGBA {
    var out = c;
    out.f_alpha = alpha;
    return out;
}

/// The lines' colours from the current style: the time, level and data
/// dim; `[conn]` in the accent colour and `page` in the success colour;
/// warnings and errors in theirs; a text-filter hit on a wash of the
/// warning colour; the hovered line on a wash of the text colour.
fn colourTags(w: *LogWindow) void {
    const dim = probeColour(w, .dim);
    const text = textColour(w);
    setProp(w, "t", "foreground-rgba", &dim);
    setProp(w, "who", "foreground-rgba", &probeColour(w, .accent));
    setProp(w, "who-page", "foreground-rgba", &probeColour(w, .success));
    setProp(w, "lvl-info", "foreground-rgba", &dim);
    setProp(w, "debug", "foreground-rgba", &dim);
    setProp(w, "warn", "foreground-rgba", &probeColour(w, .warning));
    setProp(w, "error", "foreground-rgba", &probeColour(w, .@"error"));
    setProp(w, "data", "foreground-rgba", &dim);
    setProp(w, "hit", "paragraph-background-rgba", &withAlpha(probeColour(w, .warning), 0.18));
    setProp(w, "hover", "paragraph-background-rgba", &withAlpha(text, 0.06));
}

fn textColour(w: *LogWindow) gdk.RGBA {
    var c: gdk.RGBA = undefined;
    w.view.as(gtk.Widget).getColor(&c);
    return c;
}

/// The scheme or the accent colour changed: recolour once the style has
/// settled (libadwaita swaps its stylesheet in the same notification).
fn onStyleChanged(_: *adw.StyleManager, _: *gobject.ParamSpec, w: *LogWindow) callconv(.c) void {
    if (w.recolour_source != 0) return;
    w.recolour_source = glib.idleAdd(recolourIdle, w);
}

fn recolourIdle(ud: ?*anyopaque) callconv(.c) c_int {
    const w: *LogWindow = @ptrCast(@alignCast(ud.?));
    w.recolour_source = 0;
    colourTags(w);
    return 0;
}

// ---------------------------------------------------------------------------
// Live tail
// ---------------------------------------------------------------------------

var wake_pending: std.atomic.Value(bool) = .init(false);

/// Log subscriber: runs on whichever thread pushed. Only wakes the main
/// loop (once per burst); `pull` reads the ring there.
fn onLogPushed(_: ?*anyopaque, _: *const Log.Entry) void {
    if (wake_pending.swap(true, .acq_rel)) return;
    mainloop.post(Wake{}, Wake.run);
}

const Wake = struct {
    /// mainloop.post needs a sized value
    _pad: u8 = 0,
    fn run(_: *Wake) void {
        wake_pending.store(false, .release);
        const w = instance orelse return;
        const before = w.rows.items.len;
        const first_new = pull(w);
        appendFrom(w, first_new, before);
    }
};

/// Take every ring entry newer than the last one seen; returns the index
/// in `rows` of the first new row.
fn pull(w: *LogWindow) usize {
    const e = iface.engine orelse return w.rows.items.len;
    var snap = e.log().since(alloc, w.last_seq) catch return w.rows.items.len;
    defer snap.deinit();
    var first: usize = w.rows.items.len;
    var evicted: usize = 0;
    for (snap.entries, snap.lines) |*entry, line| {
        if (entry.seq <= w.last_seq) continue;
        const row = makeRow(entry, line) catch continue;
        w.last_seq = entry.seq;
        w.rows.append(alloc, row) catch {
            row.deinit();
            continue;
        };
        noteHost(w, entry.conn);
        if (w.rows.items.len > model.max_rows) {
            evict(w);
            evicted += 1;
        }
    }
    first -|= evicted;
    return first;
}

/// Drop the oldest row (and its line, if shown).
fn evict(w: *LogWindow) void {
    const old = w.rows.orderedRemove(0);
    if (w.shown.items.len > 0 and w.shown.items[0] == old) {
        _ = w.shown.orderedRemove(0);
        var a: gtk.TextIter = undefined;
        var b: gtk.TextIter = undefined;
        w.buffer.getStartIter(&a);
        if (w.buffer.getIterAtLine(&b, 1) == 0) w.buffer.getEndIter(&b);
        w.buffer.delete(&a, &b);
        if (w.hover_line) |*h| {
            if (h.* == 0) w.hover_line = null else h.* -= 1;
        }
    }
    old.deinit();
}

fn appendFrom(w: *LogWindow, first: usize, before: usize) void {
    _ = before;
    const f = w.filter();
    var any = false;
    for (w.rows.items[@min(first, w.rows.items.len)..]) |row| {
        if (!model.passes(f, row.conn, row.level, row.line)) continue;
        appendRow(w, row, f.text.len > 0);
        any = true;
    }
    updateCount(w);
    updateEmpty(w);
    if (any and w.follow.getActive() != 0) scrollToEnd(w);
}

fn makeRow(e: *const Log.Entry, line: []const u8) !*Row {
    const r = try alloc.create(Row);
    errdefer alloc.destroy(r);
    const t = try alloc.dupeSentinel(u8, e.t, 0);
    r.* = .{
        .seq = e.seq,
        .level = e.level,
        .src = e.src,
        .conn = if (e.conn) |c| try alloc.dupe(u8, c) else null,
        .t = t,
        .time = try localTime(t),
        .msg = try alloc.dupe(u8, e.msg),
        .data = try model.displayDataAlloc(alloc, e.data),
        .line = try alloc.dupe(u8, line),
    };
    return r;
}

/// logs.html timeOf: local `HH:MM:SS.mmm`, 24 h; the ISO text if it does
/// not parse.
fn localTime(iso: [:0]const u8) ![:0]u8 {
    const utc = glib.DateTime.newFromIso8601(iso.ptr, null) orelse return alloc.dupeSentinel(u8, iso, 0);
    defer utc.unref();
    const local = utc.toLocal() orelse return alloc.dupeSentinel(u8, iso, 0);
    defer local.unref();
    const hms = local.format("%H:%M:%S") orelse return alloc.dupeSentinel(u8, iso, 0);
    defer glib.free(hms);
    const ms: u32 = @intCast(@divTrunc(local.getMicrosecond(), 1000));
    return std.fmt.allocPrintSentinel(alloc, "{s}.{d:0>3}", .{ std.mem.span(hms), ms }, 0);
}

fn noteHost(w: *LogWindow, conn_name: ?[]const u8) void {
    const key = model.hostKey(conn_name);
    for (w.host_keys.items[1..]) |k| if (std.mem.eql(u8, k.?, key)) return;
    const dup = alloc.dupe(u8, key) catch return;
    w.host_keys.append(alloc, dup) catch {
        alloc.free(dup);
        return;
    };
    const label_src = conn_name orelse model.client_label;
    const z = alloc.dupeSentinel(u8, label_src, 0) catch return;
    defer alloc.free(z);
    w.host_list.append(z.ptr);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn insertTagged(w: *LogWindow, text: []const u8, tags: []const [:0]const u8) void {
    if (text.len == 0) return;
    var it: gtk.TextIter = undefined;
    w.buffer.getEndIter(&it);
    const start_off = it.getOffset();
    w.buffer.insert(&it, @ptrCast(text.ptr), @intCast(text.len));
    var a: gtk.TextIter = undefined;
    w.buffer.getIterAtOffset(&a, start_off);
    var b: gtk.TextIter = undefined;
    w.buffer.getEndIter(&b);
    for (tags) |t| w.buffer.applyTagByName(t.ptr, &a, &b);
}

/// logs.html lineHtml, as text: time, level (5 wide), [conn] / [conn]
/// page, message, data.
fn appendRow(w: *LogWindow, row: *Row, hit: bool) void {
    var start: gtk.TextIter = undefined;
    w.buffer.getEndIter(&start);
    if (w.shown.items.len > 0) w.buffer.insert(&start, "\n", 1);
    w.buffer.getEndIter(&start);
    const line_start = start.getOffset();

    const debug = row.level == .debug;
    const sev: ?[:0]const u8 = switch (row.level) {
        .warn => "warn",
        .@"error" => "error",
        else => null,
    };
    insertTagged(w, row.time, if (debug) &.{ "t", "debug" } else &.{"t"});
    insertTagged(w, " ", &.{});
    var lvl_buf: [8]u8 = undefined;
    const up = row.level.upper();
    @memcpy(lvl_buf[0..up.len], up);
    @memset(lvl_buf[up.len..5], ' ');
    const lvl = lvl_buf[0..@max(5, up.len)];
    if (sev) |s| insertTagged(w, lvl, &.{ "lvl", s }) else if (debug) insertTagged(w, lvl, &.{ "lvl", "debug" }) else insertTagged(w, lvl, &.{ "lvl", "lvl-info" });
    insertTagged(w, " ", &.{});
    if (row.conn) |c| {
        var who_buf: [128]u8 = undefined;
        const who = std.fmt.bufPrint(&who_buf, "[{s}]{s}", .{ c, if (row.src == .page) " page" else "" }) catch c;
        const who_tag: [:0]const u8 = if (row.src == .page) "who-page" else "who";
        insertTagged(w, who, if (debug) &.{ who_tag, "debug" } else &.{who_tag});
        insertTagged(w, " ", &.{});
    }
    if (sev) |s| insertTagged(w, row.msg, &.{s}) else if (debug) insertTagged(w, row.msg, &.{"debug"}) else insertTagged(w, row.msg, &.{});
    if (row.data.len > 0) {
        insertTagged(w, " ", &.{});
        insertTagged(w, row.data, &.{"data"});
    }

    var a: gtk.TextIter = undefined;
    w.buffer.getIterAtOffset(&a, line_start);
    var b: gtk.TextIter = undefined;
    w.buffer.getEndIter(&b);
    w.buffer.applyTagByName("line", &a, &b);
    if (hit) w.buffer.applyTagByName("hit", &a, &b);
    w.shown.append(alloc, row) catch {};
}

/// logs.html render: rebuild the view from the filters.
fn render(w: *LogWindow) void {
    w.buffer.setText("", 0);
    w.shown.clearRetainingCapacity();
    w.hover_line = null;
    const f = w.filter();
    for (w.rows.items) |row| {
        if (model.passes(f, row.conn, row.level, row.line)) appendRow(w, row, f.text.len > 0);
    }
    updateCount(w);
    updateEmpty(w);
    if (w.follow.getActive() != 0) scrollToEnd(w);
}

fn updateCount(w: *LogWindow) void {
    var buf: [64]u8 = undefined;
    const t = model.countText(&buf, w.shown.items.len, w.rows.items.len);
    var z: [65]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&z, "{s}", .{t}, 0) catch return;
    w.count.setText(s.ptr);
}

fn updateEmpty(w: *LogWindow) void {
    const none = w.shown.items.len == 0;
    w.scroll.as(gtk.Widget).setVisible(@intFromBool(!none));
    w.empty.as(gtk.Widget).setVisible(@intFromBool(none));
    if (!none) return;
    if (iface.engine == null) {
        w.empty.setTitle(no_engine_text);
    } else {
        const t = model.emptyText(w.rows.items.len);
        w.empty.setTitle(if (t.ptr == model.empty_no_entries.ptr) model.empty_no_entries else model.empty_no_match);
    }
}

fn setFile(w: *LogWindow, path: []const u8) void {
    const z = alloc.dupeSentinel(u8, path, 0) catch return;
    defer alloc.free(z);
    w.file.setText(z.ptr);
    w.file.as(gtk.Widget).setTooltipText(z.ptr);
}

// ---------------------------------------------------------------------------
// Follow (G-24)
// ---------------------------------------------------------------------------

fn scrollToEnd(w: *LogWindow) void {
    const adj = w.scroll.getVadjustment();
    w.pinning = true;
    defer w.pinning = false;
    adj.setValue(adj.getUpper() - adj.getPageSize());
}

/// The content grew (or the window resized): while following, stay at
/// the bottom. This also covers the text view finishing its layout of
/// lines it had only estimated.
fn onAdjChanged(_: *gtk.Adjustment, w: *LogWindow) callconv(.c) void {
    if (w.follow.getActive() != 0) scrollToEnd(w);
}

/// Scrolling more than 4px away from the bottom unticks follow; scrolling
/// back to the bottom reticks it. Only the user's scrolling unticks it:
/// the text view also moves the value on its own (it keeps its top line
/// anchored while it lays lines out, and when the oldest line is dropped),
/// and while following such a drift is pinned back to the bottom.
fn onScrolled(adj: *gtk.Adjustment, w: *LogWindow) callconv(.c) void {
    if (w.pinning) return;
    const bottom = model.atBottom(adj.getUpper(), adj.getValue(), adj.getPageSize());
    const following = w.follow.getActive() != 0;
    if (bottom) {
        if (!following) w.follow.setActive(1);
    } else if (following) {
        if (userScrolling(w)) w.follow.setActive(0) else scrollToEnd(w);
    }
}

fn userScrolling(w: *LogWindow) bool {
    return glib.getMonotonicTime() < w.user_scroll_until;
}

/// The user is scrolling up: for the next half second a move away from
/// the bottom unticks follow. (Scrolling down never unticks it, so the
/// text view's own drift right after the user reached the bottom is still
/// pinned back.)
pub fn noteUserScroll(w: *LogWindow) void {
    w.user_scroll_until = glib.getMonotonicTime() + 500 * std.time.us_per_ms;
}

fn onUserWheel(_: *gtk.EventControllerScroll, _: f64, dy: f64, w: *LogWindow) callconv(.c) c_int {
    if (dy < 0) noteUserScroll(w);
    return 0;
}

fn onUserDrag(_: *gtk.GestureDrag, _: f64, offset_y: f64, w: *LogWindow) callconv(.c) void {
    if (offset_y < 0) noteUserScroll(w);
}

fn onViewKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, w: *LogWindow) callconv(.c) c_int {
    switch (keyval) {
        gdk.KEY_Up, gdk.KEY_KP_Up, gdk.KEY_Page_Up, gdk.KEY_KP_Page_Up, gdk.KEY_Home, gdk.KEY_KP_Home => noteUserScroll(w),
        else => {},
    }
    return 0;
}

fn onFollowToggled(cb: *gtk.CheckButton, w: *LogWindow) callconv(.c) void {
    if (cb.getActive() != 0) scrollToEnd(w);
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

fn onFilterChanged(_: *gtk.DropDown, _: *gobject.ParamSpec, w: *LogWindow) callconv(.c) void {
    render(w);
}

fn onSearch(entry: *gtk.SearchEntry, w: *LogWindow) callconv(.c) void {
    const raw = std.mem.span(entry.as(gtk.Editable).getText());
    w.query = model.normalizeQuery(&w.query_buf, raw);
    render(w);
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

fn flashText(w: *LogWindow, text: []const u8) void {
    var z: [96]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&z, "{s}", .{text}, 0) catch return;
    w.flash.setText(s.ptr);
    if (w.flash_timer != 0) _ = glib.Source.remove(w.flash_timer);
    w.flash_timer = glib.timeoutAdd(flash_ms, onFlashDone, w);
}

fn onFlashDone(ud: ?*anyopaque) callconv(.c) c_int {
    const w: *LogWindow = @ptrCast(@alignCast(ud.?));
    w.flash_timer = 0;
    w.flash.setText("");
    return 0;
}

fn copyRows(w: *LogWindow, rows: []const *Row, visible: bool) void {
    const lines = alloc.alloc([]const u8, rows.len) catch return;
    defer alloc.free(lines);
    for (rows, lines) |r, *l| l.* = r.line;
    const text = model.copyText(alloc, lines) catch return;
    defer alloc.free(text);
    url.copyToClipboard(text, null);
    var buf: [64]u8 = undefined;
    flashText(w, model.copiedText(&buf, rows.len, visible));
}

pub const Button = enum { copy_visible, copy_all, reveal, clear };

/// What each toolbar button does; the control socket enters here too.
pub fn press(which: Button) void {
    const w = instance orelse return;
    if (iface.engine == null) return; // the buttons and actions are insensitive
    switch (which) {
        .copy_visible => copyRows(w, w.shown.items, true),
        .copy_all => copyRows(w, w.rows.items, false),
        .reveal => if (iface.engine.?.log().filePath()) |p| url.launch(.reveal, p, w.window),
        .clear => {
            // Empty the window first: the ring's "log cleared" marker then
            // arrives through the tail like any entry (A-16: it is shown).
            for (w.rows.items) |r| r.deinit();
            w.rows.clearRetainingCapacity();
            render(w);
            iface.engine.?.log().clear();
        },
    }
}

fn onCopyVisible(_: *gtk.Button, _: *LogWindow) callconv(.c) void {
    press(.copy_visible);
}
fn actCopyAll(_: *gio.SimpleAction, _: ?*glib.Variant, _: *LogWindow) callconv(.c) void {
    press(.copy_all);
}
fn actReveal(_: *gio.SimpleAction, _: ?*glib.Variant, _: *LogWindow) callconv(.c) void {
    press(.reveal);
}
fn actClear(_: *gio.SimpleAction, _: ?*glib.Variant, _: *LogWindow) callconv(.c) void {
    press(.clear);
}

// ---------------------------------------------------------------------------
// Keys (G-28)
// ---------------------------------------------------------------------------

pub const Key = enum { escape, find, copy_visible, app_shortcut, none };

/// Classify and run a key in the log window. Returns what it did.
pub fn handleKey(w: *LogWindow, ev: KeyEvent) Key {
    if (ev.action == .release or ev.is_modifier) return .none;
    const display = w.window.as(gtk.Widget).getDisplay();
    const base = ev.baseKeyval(display);
    const mods = shortcuts.Mods.fromGdk(ev.state);
    if (base == gdk.KEY_Escape and !mods.ctrl and !mods.alt and !mods.super) {
        w.window.close();
        return .escape;
    }
    if (mods.ctrl and !mods.alt and !mods.super) {
        if (mods.shift and base == gdk.KEY_c) {
            press(.copy_visible);
            return .copy_visible;
        }
        if (!mods.shift and base == gdk.KEY_f) {
            _ = w.search.as(gtk.Widget).grabFocus();
            w.search.as(gtk.Editable).selectRegion(0, -1);
            return .find;
        }
    }
    // The app shortcuts (connections, settings, log, hosts) work here too;
    // pane chords do not exist in this window.
    const chord: shortcuts.Chord = .{ .keyval = base, .mods = mods };
    if (shortcuts.lookup(chord)) |action| {
        if (std.mem.startsWith(u8, action, "app.")) {
            _ = shortcuts.dispatch(w.window.as(gtk.Widget), chord);
            return .app_shortcut;
        }
    }
    return .none;
}

fn onKey(ec: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType, w: *LogWindow) callconv(.c) c_int {
    const ev = KeyEvent.fromController(ec, .press, keyval, keycode, state) orelse return 0;
    return @intFromBool(handleKey(w, ev) != .none);
}

// ---------------------------------------------------------------------------
// Hover and tooltip (G-23)
// ---------------------------------------------------------------------------

fn lineAt(w: *LogWindow, x: f64, y: f64) ?usize {
    var bx: c_int = 0;
    var by: c_int = 0;
    w.view.windowToBufferCoords(.widget, @intFromFloat(x), @intFromFloat(y), &bx, &by);
    var it: gtk.TextIter = undefined;
    _ = w.view.getIterAtLocation(&it, bx, by);
    const line: usize = @intCast(it.getLine());
    return if (line < w.shown.items.len) line else null;
}

/// Give one line the hover background (null: none).
pub fn setHover(w: *LogWindow, line: ?usize) void {
    if (line == w.hover_line) return;
    var a: gtk.TextIter = undefined;
    var b: gtk.TextIter = undefined;
    w.buffer.getBounds(&a, &b);
    w.buffer.removeTagByName("hover", &a, &b);
    w.hover_line = line;
    const l = line orelse return;
    if (w.buffer.getIterAtLine(&a, @intCast(l)) == 0) return;
    b = a;
    _ = b.forwardToLineEnd();
    w.buffer.applyTagByName("hover", &a, &b);
}

fn onMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, w: *LogWindow) callconv(.c) void {
    setHover(w, lineAt(w, x, y));
}

fn onLeave(_: *gtk.EventControllerMotion, w: *LogWindow) callconv(.c) void {
    setHover(w, null);
}

fn onQueryTooltip(_: *gtk.TextView, x: c_int, y: c_int, keyboard: c_int, tooltip: *gtk.Tooltip, w: *LogWindow) callconv(.c) c_int {
    if (keyboard != 0) return 0;
    const line = lineAt(w, @floatFromInt(x), @floatFromInt(y)) orelse return 0;
    tooltip.setText(w.shown.items[line].t.ptr);
    return 1;
}

// ---------------------------------------------------------------------------
// Control socket
// ---------------------------------------------------------------------------

pub fn setFilters(host: ?[]const u8, level: ?[]const u8, text: ?[]const u8) error{ NotOpen, BadHost, BadLevel }!void {
    const w = instance orelse return error.NotOpen;
    if (host) |h| {
        const want: ?[]const u8 = if (std.mem.eql(u8, h, "all")) null else if (std.mem.eql(u8, h, model.client_label)) model.client_key else h;
        var idx: ?usize = null;
        for (w.host_keys.items, 0..) |k, i| {
            if (k == null and want == null) idx = i;
            if (k != null and want != null and std.mem.eql(u8, k.?, want.?)) idx = i;
        }
        w.host_dd.setSelected(@intCast(idx orelse return error.BadHost));
    }
    if (level) |l| {
        var idx: ?usize = null;
        for (model.level_labels, 0..) |lab, i| if (std.mem.eql(u8, lab, l) or std.mem.eql(u8, @tagName(@as(Log.Level, @fromBackingInt(@intCast(i)))), l)) {
            idx = i;
        };
        w.level_dd.setSelected(@intCast(idx orelse return error.BadLevel));
    }
    if (text) |t| {
        const z = alloc.dupeSentinel(u8, t, 0) catch return;
        defer alloc.free(z);
        // Through the entry, like typing; search-changed fires after the
        // 80 ms delay.
        w.search.as(gtk.Editable).setText(z.ptr);
    }
}
