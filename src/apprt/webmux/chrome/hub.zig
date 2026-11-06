//! The chrome's state: the connection engine, one `Entry` per connection
//! (pill order), which content view is in front, and the window frame
//! (header strip on top, a stack of content views below). The port of
//! electron/main.js's "Window & views" and "Connections" sections, minus
//! everything the engine (src/webmux/conn) already does.
//!
//! Main thread only. Engine events arrive on engine threads and are
//! marshalled here with `mainloop.post`; status changes are coalesced into
//! one `refresh()` (a `snapshot()` reconciled against the entries).
//!
//! View rules (main.js show/userShow/surfaceFailure/onServerUp):
//!   - startup opens the Connections page; nothing connects by itself;
//!   - connecting from the page marks the entry `reveal`: its view comes to
//!     the front when the server first answers, unless the user navigated
//!     anywhere in the meantime (`userShow` clears every reveal);
//!   - a connection whose content never came up and fails while in front
//!     sends the window back to the Connections page; one with content
//!     rides out retries in place, and background failures only recolour
//!     its pill;
//!   - disconnecting the front host opens the Connections page.
const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const conn = @import("../../../webmux/conn.zig");
const global = @import("../../../global.zig");
const build_config = @import("../../../build_config.zig");
const iface = @import("../iface.zig");
const mainloop = @import("../mainloop.zig");
const Application = @import("../application.zig").Application;
const Window = @import("../window.zig").Window;
const TerminalPane = @import("../pane.zig").TerminalPane;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const ext = @import("../ext.zig");
const panels_settings = @import("../panels/settings.zig");
const settings_panel = @import("../panels/settings_panel.zig");
const toast = @import("../panels/toast.zig");

const keyring = @import("keyring.zig");
const probe = @import("probe.zig");
const sleep = @import("sleep.zig");
const header_mod = @import("header.zig");
const page_mod = @import("page.zig");
const menu_mod = @import("menu.zig");
const hostview = @import("hostview.zig");
const import_mod = @import("import.zig");
const register = @import("register.zig");
const conn_util = @import("../../../webmux/conn/util.zig");
const url_mod = @import("../panels/url.zig");

const log = std.log.scoped(.webmux_chrome);
pub const alloc = std.heap.c_allocator;

/// Development hook: the ssh program the engine runs (e.g. the fake ssh
/// of webmux-dev/fake-ssh). Unset: `ssh` from PATH.
pub const ssh_env_var = "WEBMUX_GTK_SSH";

/// One connection (main.js `conns` value).
pub const Entry = struct {
    /// Stable for the entry's life; async results carry it instead of a
    /// pointer.
    id: u64,
    /// Profile name (follows renames).
    name: []u8,
    /// Latest status (owned copy), null before the first snapshot.
    status: ?conn.Status = null,
    state: conn.State = .connecting,
    /// Switch to this view when the server first answers.
    reveal: bool = false,
    /// The view in the stack.
    view: hostview.View,
    /// Pane count and link health, from the workspace (or the fallback).
    panes: usize = 0,
    offline: bool = false,
    /// Remaining retry countdown has a ticking display.
    stack_name: [:0]u8,

    pub fn stateName(e: *const Entry) []const u8 {
        if (e.state == .connected and e.offline) return "degraded";
        return @tagName(e.state);
    }

    /// True when the tunnel is up (connected or degraded).
    pub fn isUp(e: *const Entry) bool {
        return e.state == .connected;
    }
};

pub const Hub = struct {
    engine: ?conn.Engine = null,
    engine_error: ?[]const u8 = null,
    entries: std.ArrayList(*Entry) = .empty,
    /// The host in front; null = the landing view.
    active: ?*Entry = null,
    next_id: u64 = 1,

    window: ?*Window = null,
    stack: ?*gtk.Stack = null,
    header: ?*header_mod.Header = null,
    page: ?*page_mod.Page = null,

    refresh_pending: std.atomic.Value(bool) = .init(false),
    tick_source: c_uint = 0,
    shut_down: bool = false,
    /// Names whose connect just started from the page (reveal once the
    /// entry exists).
    last_title: [256]u8 = undefined,
};

pub var hub: Hub = .{};

// ---------------------------------------------------------------------------
// Startup and shutdown
// ---------------------------------------------------------------------------

/// Application startup (not in dev mode): create the engine, register the
/// app actions, watch for wake-from-sleep. No widgets yet.
pub fn start(app: *Application) void {
    menu_mod.registerActions(app);

    var env = global.environMap() catch {
        hub.engine_error = "out of memory";
        return;
    };
    defer env.deinit();

    const ssh_path: []const u8 = if (std.c.getenv(ssh_env_var)) |v| std.mem.span(v) else "ssh";
    if (!std.mem.eql(u8, ssh_path, "ssh")) log.warn("using ssh program {s} ({s})", .{ ssh_path, ssh_env_var });

    // The keyring backend for the "client started" line, and the
    // has-password hint (needs the state dir: resolve it the engine's way).
    const backend = keyring.backendName();
    log.info("password store: {s}", .{backend});

    const engine = conn.Engine.init(alloc, global.io(), .{
        .env = &env,
        .ssh_path = ssh_path,
        .probe = probe.probeFn(),
        .password = keyring.passwordFn(),
        .listener = .{ .func = onEngineEvent },
        .version = build_config.version_string,
        .password_store = backend,
    }) catch |err| {
        log.err("connection engine failed to start: {t}", .{err});
        hub.engine_error = @errorName(err);
        return;
    };
    hub.engine = engine;
    iface.engine = &(hub.engine.?);

    keyring.init(engine.stateDir());
    // N2: ids config.json gave to several profiles were re-issued; the
    // secret stored under such an id is never offered to any of them.
    for (engine.droppedPasswordIds()) |id| keyring.forget(id);
    // Orphaned secrets are cleaned up only against a config.json that
    // exists and lists profiles: a missing or emptied file (moved away for
    // a while, a different machine's setup) must not cost every password.
    const refs: ?[][]u8 = blk: {
        if (!conn_util.fileExists(engine.configPath())) break :blk null;
        var list = engine.listProfiles(alloc) catch break :blk null;
        defer list.deinit();
        if (list.profiles.len == 0) break :blk null;
        break :blk engine.referencedIds(alloc) catch null;
    };
    keyring.scanAsync(refs);

    import_mod.firstRun(engine);

    // The panels own iface.settings and the colour scheme: they apply the
    // stored settings now, before the first window is presented (E-07).
    panels_settings.load();

    sleep.start(onResume);
}

/// Quit (W-06): the windows are already gone; stop every tunnel and
/// deploy step and wait for the engine's threads. Remote sessions survive.
pub fn shutdown() void {
    if (hub.shut_down) return;
    hub.shut_down = true;
    if (hub.tick_source != 0) {
        _ = glib.Source.remove(hub.tick_source);
        hub.tick_source = 0;
    }
    sleep.stop();
    // Views went with the window; forget them.
    for (hub.entries.items) |e| freeEntry(e);
    hub.entries.clearRetainingCapacity();
    hub.active = null;
    if (hub.engine) |e| {
        iface.engine = null;
        e.deinit();
        hub.engine = null;
    }
}

// ---------------------------------------------------------------------------
// The window frame
// ---------------------------------------------------------------------------

/// Fill a new main window: header strip + content stack (the landing view
/// first, under the preferences dialog). Main thread.
pub fn populate(win: *Window) void {
    hub.window = win;
    _ = gtk.Widget.signals.destroy.connect(win.as(gtk.Widget), ?*anyopaque, onWindowDestroy, null, .{});
    _ = gobject.Object.signals.notify.connect(win.as(gtk.Window), ?*anyopaque, onWindowActive, null, .{ .detail = "is-active" });
    _ = gobject.Object.signals.notify.connect(win.as(gtk.Window), ?*anyopaque, onFocusWidget, null, .{ .detail = "focus-widget" });

    const frame = gtk.Box.new(.vertical, 0);
    frame.as(gtk.Widget).addCssClass("wm-frame");

    const header = header_mod.Header.create();
    hub.header = header;
    frame.append(header.widget());

    const stack = gtk.Stack.new();
    stack.setTransitionType(.none);
    stack.as(gtk.Widget).setVexpand(1);
    stack.as(gtk.Widget).setHexpand(1);
    hub.stack = stack;

    const page = page_mod.Page.create();
    hub.page = page;
    _ = stack.addNamed(page.widget(), "connections");
    frame.append(stack.as(gtk.Widget));

    win.setBody(frame.as(gtk.Widget));

    const style = Application.default().as(adw.Application).getStyleManager();
    _ = gobject.Object.signals.notify.connect(style, ?*anyopaque, onStyleDark, null, .{ .detail = "dark" });
    syncScheme();

    // Entries that exist already (a second window after a reopen).
    for (hub.entries.items) |e| addView(e);
    show(null);
    // Status messages: no host is in front at start.
    toast.setFront(if (hub.active) |x| x.name else null);
    if (hub.engine == null) page.showEngineError(hub.engine_error orelse "unknown error");
    if (hub.engine) |engine| if (engine.configProblem()) |msg| page.showConfigProblem(msg);
}

fn onWindowDestroy(_: *gtk.Widget, _: ?*anyopaque) callconv(.c) void {
    hub.window = null;
    hub.stack = null;
    if (hub.header) |h| h.destroyed();
    if (hub.page) |p| p.destroyed();
    hub.header = null;
    hub.page = null;
    for (hub.entries.items) |e| e.view.widgetGone();
}

fn onStyleDark(_: *adw.StyleManager, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    syncScheme();
}

/// The chrome's light palette hangs off `wm-light` on the main window
/// (chrome.css), following libadwaita's dark/light, which the
/// application forces from the colour-scheme setting.
fn syncScheme() void {
    const win = hub.window orelse return;
    const dark = Application.default().as(adw.Application).getStyleManager().getDark() != 0;
    header_mod.setClass(win.as(gtk.Widget), "wm-light", !dark);
}

// ---------------------------------------------------------------------------
// Keyboard focus around popovers (N1)
//
// The last widget outside any popover that had keyboard focus (a terminal,
// a file browser, a form field) is remembered. When focus ends up nowhere
// (a popover closed by Escape, by an item, by a click elsewhere or on its
// button), it goes back there; the Edit menu items act on it.
// ---------------------------------------------------------------------------

var content_focus: WeakRef(gtk.Widget) = .empty;
var restore_source: c_uint = 0;

fn inPopover(w: *gtk.Widget) bool {
    return ext.getAncestor(gtk.Popover, w) != null;
}

/// The header strip never keeps keyboard focus (W-05); GTK hands it to
/// a menu button when its popover closes.
fn inHeader(w: *gtk.Widget) bool {
    const h = hub.header orelse return false;
    const hw = h.widget();
    return w == hw or w.isAncestor(hw) != 0;
}

fn onFocusWidget(win: *gtk.Window, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    const f = win.getFocus();
    textFocusMoved(f);
    if (f) |w| {
        if (inHeader(w)) {
            scheduleFocusRestore();
        } else if (!inPopover(w)) content_focus.set(w);
    } else scheduleFocusRestore();
}

// ---------------------------------------------------------------------------
// Text fields keep their cursor and selection across a focus round trip
//
// GTK selects a whole entry when it gets focus by grab_focus (a dialog or
// popover giving focus back, a view switch), so the next keystroke would
// replace what was typed. When focus leaves a text field, its cursor and
// selection are recorded; when focus comes back to that field and GTK has
// selected all of it although that was not the state it was left in, the
// recorded state is put back. A click (cursor where clicked) is left alone.
// ---------------------------------------------------------------------------

var focused_text: WeakRef(gtk.Text) = .empty;
var left_text: WeakRef(gtk.Text) = .empty;
var left_pos: c_int = 0;
var left_anchor: c_int = 0;
var text_fix_source: c_uint = 0;

fn editableOf(t: *gtk.Text) *gtk.Editable {
    return t.as(gtk.Editable);
}

/// The state of a text field: cursor and the selection's other end.
fn textState(t: *gtk.Text, pos: *c_int, anchor: *c_int) void {
    const ed = editableOf(t);
    pos.* = ed.getPosition();
    var a: c_int = 0;
    var b: c_int = 0;
    if (ed.getSelectionBounds(&a, &b) != 0) {
        anchor.* = if (pos.* == a) b else a;
    } else anchor.* = pos.*;
}

fn textFocusMoved(new: ?*gtk.Widget) void {
    const new_text: ?*gtk.Text = if (new) |w| gobject.ext.cast(gtk.Text, w) else null;
    if (focused_text.get()) |old| {
        defer old.unref();
        if (new_text != old) {
            // Leaving a text field: remember how it was.
            textState(old, &left_pos, &left_anchor);
            left_text.set(old);
        }
    }
    focused_text.set(new_text);
    const t = new_text orelse return;
    const left = left_text.get() orelse return;
    defer left.unref();
    if (left != t) return;
    // Back in the field it was left from: undo a select-all on the idle,
    // after GTK has finished the focus change.
    if (text_fix_source == 0) text_fix_source = glib.idleAdd(fixTextSelection, null);
}

fn fixTextSelection(_: ?*anyopaque) callconv(.c) c_int {
    text_fix_source = 0;
    const t = focused_text.get() orelse return 0;
    defer t.unref();
    const left = left_text.get() orelse return 0;
    defer left.unref();
    if (left != t) return 0;
    const ed = editableOf(t);
    const len: c_int = @intCast(std.unicode.utf8CountCodepoints(std.mem.span(ed.getText())) catch return 0);
    var a: c_int = 0;
    var b: c_int = 0;
    const all = len > 0 and ed.getSelectionBounds(&a, &b) != 0 and a == 0 and b == len;
    const was_all = len > 0 and @min(left_pos, left_anchor) == 0 and @max(left_pos, left_anchor) == len;
    if (!all or was_all) return 0;
    const pos = @min(left_pos, len);
    const anchor = @min(left_anchor, len);
    if (pos == anchor) ed.setPosition(pos) else ed.selectRegion(anchor, pos);
    return 0;
}

/// Give focus back to a widget the way it was left (a text field without
/// selecting its content).
pub fn refocus(w: *gtk.Widget) bool {
    if (gobject.ext.cast(gtk.Text, w)) |t| return t.grabFocusWithoutSelecting() != 0;
    return w.grabFocus() != 0;
}

/// After a popover closed: put focus back where it was before it opened
/// (on an idle, once GTK has finished with the popover's own focus).
pub fn scheduleFocusRestore() void {
    if (restore_source != 0) return;
    restore_source = glib.idleAdd(restoreFocus, null);
}

fn restoreFocus(_: ?*anyopaque) callconv(.c) c_int {
    restore_source = 0;
    if (hub.shut_down) return 0;
    const win = (hub.window orelse return 0).as(gtk.Window);
    if (win.getFocus()) |f| {
        // Something real already has it (an item that moved focus on).
        if (!inPopover(f) and !inHeader(f)) return 0;
        if (inPopover(f) and f.getMapped() != 0) return 0; // still open
    }
    if (content_focus.get()) |w| {
        defer w.unref();
        if (w.getMapped() != 0 and w.isSensitive() != 0 and w.getRoot() == win.as(gtk.Root) and refocus(w)) return 0;
    }
    focusContent();
    return 0;
}

/// The remembered content focus if it lies inside `container` (borrowed).
pub fn contentFocusIn(container: *gtk.Widget) ?*gtk.Widget {
    const w = content_focus.get() orelse return null;
    w.unref();
    if (w == container or w.isAncestor(container) != 0) return w;
    return null;
}

/// The widget the user was working in before a popover took focus
/// (borrowed; valid until control returns to the main loop), or null.
pub fn contentFocus() ?*gtk.Widget {
    const win = (hub.window orelse return null).as(gtk.Window);
    if (win.getFocus()) |f| if (!inPopover(f) and !inHeader(f)) return f;
    const w = content_focus.get() orelse return null;
    w.unref(); // the widget tree still holds it
    return w;
}

fn onWindowActive(win: *gtk.Window, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    if (win.isActive() == 0) return;
    // A-14: mirror the clipboard image into the visible host on focus.
    if (hub.active) |e| clipboardSync(e);
}

fn addView(e: *Entry) void {
    const stack = hub.stack orelse return;
    _ = stack.addNamed(e.view.build(e), e.stack_name.ptr);
}

// ---------------------------------------------------------------------------
// Showing views
// ---------------------------------------------------------------------------

/// Explicit navigation (pill click, Ctrl+N, Ctrl+PageUp/Down, Connections):
/// cancels every pending reveal-on-connect first (X-28).
pub fn userShow(e: ?*Entry) void {
    for (hub.entries.items) |x| x.reveal = false;
    if (e != null) return show(e);
    // Connections opens over whatever is in front (deviation 67).
    if (hub.page) |p| p.present();
}

pub fn show(e_: ?*Entry) void {
    const e = if (e_) |x| (if (indexOf(x) != null) x else null) else null;
    const old = hub.active;
    hub.active = e;
    if (hub.stack) |stack| stack.setVisibleChildName(if (e) |x| x.stack_name.ptr else "connections");
    if (old != e) {
        if (old) |o| o.view.setFront(false);
        if (e) |x| x.view.setFront(true);
        // Status messages follow the front host (null: the page).
        toast.setFront(if (e) |x| x.name else null);
    }
    syncChoosers();
    // A host in front closes the dialog; with none, Connections is where
    // the user goes next (startup, a disconnect, a failed connect).
    if (e != null) {
        settings_panel.close();
    } else if (hub.page) |p| p.present();
    focusContent();
    if (old != e) if (e) |x| clipboardSync(x);
    changed();
}

/// Keyboard focus belongs to the visible content view (W-05).
pub fn focusContent() void {
    if (settings_panel.isOpen()) return;
    if (hub.active) |e| {
        e.view.grabFocus();
    } else if (hub.page) |p| p.focus();
}

/// Ctrl+PageUp/PageDown: previous/next host, wrapping; from the
/// landing view the last/first.
pub fn showAdjacent(dir: i32) void {
    const n: i32 = @intCast(hub.entries.items.len);
    if (n == 0) return;
    const i: i32 = if (hub.active) |a| @intCast(indexOf(a).?) else if (dir > 0) -1 else n;
    const j: usize = @intCast(@mod(i + dir + n, n));
    userShow(hub.entries.items[j]);
}

/// Ctrl+<n>: the nth connected host in pill order (no-op if none).
pub fn showNth(n: usize) void {
    if (n >= hub.entries.items.len) return;
    userShow(hub.entries.items[n]);
}

pub fn indexOf(e: *Entry) ?usize {
    return std.mem.indexOfScalar(*Entry, hub.entries.items, e);
}

pub fn find(name: []const u8) ?*Entry {
    for (hub.entries.items) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

pub fn findId(id: u64) ?*Entry {
    for (hub.entries.items) |e| if (e.id == id) return e;
    return null;
}

fn clipboardSync(e: *Entry) void {
    const hook = iface.hooks.clipboardSync orelse return;
    const c = e.view.iconn() orelse return;
    hook(c);
}

// ---------------------------------------------------------------------------
// Actions the UI invokes
// ---------------------------------------------------------------------------

/// profiles:connect from the page (Connect, Show, Save & Connect): an
/// already-connected profile is just shown; anything else (re)starts the
/// connect cycle and reveals the view when the server first answers.
pub fn connectProfile(name: []const u8) ?[]const u8 {
    const engine = hub.engine orelse return "the connection engine is not running";
    if (find(name)) |e| if (e.state == .connected) {
        show(e);
        return null;
    };
    if (engine.connect(name)) |err| {
        log.info("connect {s}: {s}", .{ name, err });
        return err;
    }
    refresh();
    if (find(name)) |e| {
        e.reveal = true;
        if (e.state == .connected) {
            e.reveal = false;
            show(e);
        }
    }
    return null;
}

/// Pill ✕, card Disconnect/Cancel (X-23).
pub fn disconnect(name: []const u8) void {
    const engine = hub.engine orelse return;
    engine.disconnect(name);
    refresh();
}

/// Ctrl+Shift+R / menu Reconnect (X-30): the visible host, else the page.
pub fn reconnectActive() void {
    const e = hub.active orelse return show(null);
    const engine = hub.engine orelse return;
    if (engine.reconnect(e.name)) |err| {
        log.warn("reconnect {s}: {s}", .{ e.name, err });
        var buf: [512]u8 = undefined;
        iface.services.status(null, std.fmt.bufPrint(&buf, "{s}: {s}", .{ e.name, err }) catch err);
    }
    refresh();
}

/// Pill drag (W-16): the new order.
pub fn reorder(names: []const []const u8) void {
    const engine = hub.engine orelse return;
    engine.reorder(names);
    refresh();
}

/// The page saved a profile under a new name: the live entry follows.
pub fn renamed(old: []const u8, new: []const u8) void {
    const e = find(old) orelse return;
    const copy = alloc.dupe(u8, new) catch return;
    register.alias(old, new);
    alloc.free(e.name);
    e.name = copy;
    e.view.renamed(copy);
    changed();
}

/// Run `pane.<cmd>` on the front workspace (header buttons, Pane menu),
/// then hand focus back to it. No-op without a live host view (W-18).
pub fn paneCommand(cmd: []const u8) void {
    const e = hub.active orelse return;
    var buf: [96]u8 = undefined;
    const action = std.fmt.bufPrintSentinel(&buf, "{s}.{s}", .{ iface.actions.pane_group, cmd }, 0) catch return;
    e.view.activate(action);
    focusContent();
}

/// Restart Sessions finished (engine event): notice on the page; reload
/// the host's view on success (deviation 12: that is the shell's job).
fn restartDone(name_at_start: []const u8, ok: bool, msg: []const u8) void {
    // The profile may have been renamed while the restart ran.
    var nb: [4096]u8 = undefined;
    const name = register.currentName(name_at_start, &nb);
    if (hub.page) |p| p.restartResult(name, msg);
    if (!ok) return;
    const e = find(name) orelse return;
    if (!e.view.hasContent()) return;
    if (hub.engine) |engine| engine.log().info(name, "reloading workspace after session restart", &.{});
    e.view.reload();
}

// ---------------------------------------------------------------------------
// Engine events
// ---------------------------------------------------------------------------

/// Engine thread.
fn onEngineEvent(_: ?*anyopaque, ev: *const conn.Event) void {
    switch (ev.*) {
        .status, .removed => scheduleRefresh(),
        .settings => |s| {
            const Post = struct {
                s: conn.Settings,
                fn run(p: *@This()) void {
                    if (hub.shut_down) return;
                    // One owner: the panels apply (idempotent).
                    panels_settings.external(&p.s);
                }
            };
            mainloop.post(Post{ .s = s.* }, Post.run);
        },
        .restart_done => |r| {
            const Post = struct {
                name: []u8,
                msg: []u8,
                ok: bool,
                fn run(p: *@This()) void {
                    defer alloc.free(p.name);
                    defer alloc.free(p.msg);
                    if (hub.shut_down) return;
                    restartDone(p.name, p.ok, p.msg);
                }
            };
            const name = alloc.dupe(u8, r.name) catch return;
            const msg = alloc.dupe(u8, r.msg) catch {
                alloc.free(name);
                return;
            };
            mainloop.post(Post{ .name = name, .msg = msg, .ok = r.ok }, Post.run);
        },
    }
}

fn scheduleRefresh() void {
    if (hub.refresh_pending.swap(true, .acq_rel)) return;
    const Post = struct {
        _: u8 = 0,
        fn run(_: *@This()) void {
            hub.refresh_pending.store(false, .release);
            if (hub.shut_down) return;
            refresh();
        }
    };
    mainloop.post(Post{}, Post.run);
}

/// Reconcile the entries with the engine's snapshot. Main thread.
pub fn refresh() void {
    const engine = hub.engine orelse return;
    var snap = engine.snapshot(alloc) catch return;
    defer snap.deinit();

    var order: std.ArrayList(*Entry) = .empty;
    defer order.deinit(alloc);
    for (snap.conns) |*st| {
        const e = find(st.name) orelse createEntry(st.name) orelse continue;
        order.append(alloc, e) catch {};
        applyStatus(e, st);
    }
    // Entries the engine no longer has: disconnected.
    var i: usize = 0;
    while (i < hub.entries.items.len) {
        const e = hub.entries.items[i];
        if (std.mem.indexOfScalar(*Entry, order.items, e) == null) {
            _ = hub.entries.orderedRemove(i);
            removeEntry(e);
        } else i += 1;
    }
    hub.entries.clearRetainingCapacity();
    hub.entries.appendSlice(alloc, order.items) catch {};
    updateTicker();
    changed();
}

fn createEntry(name: []const u8) ?*Entry {
    const e = alloc.create(Entry) catch return null;
    const id = hub.next_id;
    hub.next_id += 1;
    e.* = .{
        .id = id,
        .name = alloc.dupe(u8, name) catch return null,
        .view = .{ .entry_id = id },
        .stack_name = std.fmt.allocPrintSentinel(alloc, "host-{d}", .{id}, 0) catch return null,
    };
    hub.entries.append(alloc, e) catch return null;
    // A new connection under a name a renamed one used to have.
    register.removeAliasOf(name);
    addView(e);
    return e;
}

fn applyStatus(e: *Entry, st: *const conn.Status) void {
    const prev = e.state;
    if (e.status) |*old| old.deinit();
    e.status = copyStatus(st) catch null;
    e.state = st.state;
    e.view.noteState(e);
    if (st.state == .connected) {
        if (st.socket_path) |sock| {
            const slug = slugOf(st) catch "";
            const fresh = e.view.ensureContent(e, sock, slug);
            // The tunnel came back after an interruption or a reconnect
            // (Ctrl+Shift+R, S-13): let the workspace re-read the session
            // list (sessions may have been replaced while we were away).
            if (!fresh and prev != .connected) e.view.reload();
        }
        if (e.reveal) {
            e.reveal = false;
            show(e);
        }
    } else if (st.state == .failed and prev != .failed) {
        // X-20: a connection whose content never came up has nothing to
        // show; if it is the one on screen, fall back to the page.
        if (hub.active == e and !e.view.hasContent()) show(null);
    }
}

fn slugOf(st: *const conn.Status) ![]const u8 {
    const S = struct {
        var buf: [600]u8 = undefined;
    };
    return conn.hostSlug(st.host, st.instance, &S.buf);
}

fn copyStatus(st: *const conn.Status) !conn.Status {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    errdefer {
        arena.deinit();
        alloc.destroy(arena);
    }
    const a = arena.allocator();
    var s = st.*;
    s.name = try a.dupe(u8, st.name);
    s.msg = try a.dupe(u8, st.msg);
    s.stderr = try a.dupe(u8, st.stderr);
    s.host = try a.dupe(u8, st.host);
    s.instance = try a.dupe(u8, st.instance);
    s.socket_path = if (st.socket_path) |p| try a.dupe(u8, p) else null;
    s.remote_socket = if (st.remote_socket) |p| try a.dupe(u8, p) else null;
    s.arena = arena;
    return s;
}

/// Link choosers belong to the host whose pane raised them (re-check N3):
/// shown only while that host is in front, dismissed with its view.
fn chooserOwner(c: *const url_mod.Chooser) ?*Entry {
    const p = c.parent orelse return null;
    for (hub.entries.items) |e| {
        const box = e.view.box orelse continue;
        if (p == box.as(gtk.Widget) or p.isAncestor(box.as(gtk.Widget)) != 0) return e;
    }
    return null;
}

/// Choosers of hosts that are behind: closed, and raised again (same URL,
/// same pane) when their host comes back. A hidden AdwDialog would keep
/// the window's content from taking keyboard focus, so they are not just
/// hidden.
const Parked = struct { entry_id: u64, url: []u8, parent: *gtk.Widget };
var parked: std.ArrayList(Parked) = .empty;

fn syncChoosers() void {
    var closed_any = false;
    var i: usize = url_mod.choosers.items.len;
    while (i > 0) {
        i -= 1;
        if (i >= url_mod.choosers.items.len) continue;
        const c = url_mod.choosers.items[i];
        const owner = chooserOwner(c) orelse continue;
        if (owner == hub.active) continue;
        const p = c.parent orelse continue;
        const u = alloc.dupe(u8, c.url) catch continue;
        _ = p.as(gobject.Object).ref();
        parked.append(alloc, .{ .entry_id = owner.id, .url = u, .parent = p }) catch {
            alloc.free(u);
            p.as(gobject.Object).unref();
            continue;
        };
        url_mod.press(c, .cancel);
        closed_any = true;
    }
    // Raise the front host's parked choosers again, oldest first.
    if (hub.active) |e| {
        var k: usize = 0;
        while (k < parked.items.len) {
            const pk = parked.items[k];
            if (pk.entry_id != e.id) {
                k += 1;
                continue;
            }
            _ = parked.orderedRemove(k);
            defer alloc.free(pk.url);
            defer pk.parent.as(gobject.Object).unref();
            if (pk.parent.getRoot() != null) url_mod.showChooser(pk.url, pk.parent);
        }
    }
    // The closed chooser hands focus to its (now hidden) pane on an idle;
    // the view in front gets it back after that.
    if (closed_any) _ = glib.idleAddFull(glib.PRIORITY_LOW, refocusFront, null, null);
}

fn refocusFront(_: ?*anyopaque) callconv(.c) c_int {
    if (!hub.shut_down) focusContent();
    return 0;
}

fn dropParked(e: *Entry) void {
    var k: usize = 0;
    while (k < parked.items.len) {
        const pk = parked.items[k];
        if (pk.entry_id == e.id) {
            _ = parked.orderedRemove(k);
            alloc.free(pk.url);
            pk.parent.as(gobject.Object).unref();
        } else k += 1;
    }
}

fn dismissChoosers(e: *Entry) void {
    var i: usize = url_mod.choosers.items.len;
    while (i > 0) {
        i -= 1;
        if (i >= url_mod.choosers.items.len) continue;
        const c = url_mod.choosers.items[i];
        if (chooserOwner(c) == e) url_mod.press(c, .cancel);
    }
}

fn removeEntry(e: *Entry) void {
    log.info("connection {s} gone", .{e.name});
    dismissChoosers(e);
    dropParked(e);
    register.unalias(e.name);
    const was_active = hub.active == e;
    if (was_active) {
        e.view.setFront(false);
        hub.active = null;
    }
    if (hub.stack) |stack| e.view.removeFrom(stack);
    if (was_active) {
        show(null);
        toast.setFront(null);
    }
    // Free on an idle: callbacks from the dying view may still be on the
    // stack.
    _ = glib.idleAddOnce(freeIdle, e);
}

fn freeIdle(ud: ?*anyopaque) callconv(.c) void {
    const e: *Entry = @ptrCast(@alignCast(ud orelse return));
    if (hub.shut_down) return; // shutdown() freed everything
    freeEntry(e);
}

fn freeEntry(e: *Entry) void {
    e.view.deinit();
    if (e.status) |*s| s.deinit();
    alloc.free(e.name);
    alloc.free(e.stack_name);
    alloc.destroy(e);
}

// ---------------------------------------------------------------------------
// Workspace summaries
// ---------------------------------------------------------------------------

/// The view's pane count / link health changed (WorkspaceHost).
pub fn summaryChanged(e: *Entry, panes: usize, offline: bool) void {
    if (offline != e.offline) {
        if (hub.engine) |engine| {
            if (offline)
                engine.log().warn(e.name, "workspace reports its session sockets are down (degraded)", &.{})
            else
                engine.log().info(e.name, "workspace reports its session sockets are back", &.{});
        }
    }
    e.panes = panes;
    e.offline = offline;
    changed();
}

/// Something visible changed: header, page, title.
pub fn changed() void {
    if (hub.shut_down) return;
    if (hub.header) |h| h.update();
    if (hub.page) |p| p.update();
    updateTitle();
}

fn plural(w: *std.Io.Writer, n: usize, word: []const u8) !void {
    try w.print("{d} {s}{s}", .{ n, word, if (n == 1) "" else "s" });
}

/// W-03: `webmux — <H> host(s) · <P> pane(s)`, or `webmux`.
pub fn titleText(buf: []u8) [:0]const u8 {
    if (hub.entries.items.len == 0) return "webmux";
    var panes: usize = 0;
    for (hub.entries.items) |e| panes += e.panes;
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.writeAll("webmux — ") catch return "webmux";
    plural(&w, hub.entries.items.len, "host") catch return "webmux";
    w.writeAll(" · ") catch return "webmux";
    plural(&w, panes, "pane") catch return "webmux";
    const n = w.end;
    buf[n] = 0;
    return buf[0..n :0];
}

fn updateTitle() void {
    const win = hub.window orelse return;
    var buf: [128]u8 = undefined;
    const t = titleText(&buf);
    win.as(gtk.Window).setTitle(t.ptr);
}

/// While anything is retrying, redraw once a second so the countdowns move.
fn updateTicker() void {
    var retrying = false;
    for (hub.entries.items) |e| {
        if (e.state == .retry) retrying = true;
    }
    if (retrying and hub.tick_source == 0) {
        hub.tick_source = glib.timeoutAdd(500, onTick, null);
    } else if (!retrying and hub.tick_source != 0) {
        _ = glib.Source.remove(hub.tick_source);
        hub.tick_source = 0;
    }
}

fn onTick(_: ?*anyopaque) callconv(.c) c_int {
    if (hub.shut_down) {
        hub.tick_source = 0;
        return 0;
    }
    changed();
    return 1;
}

/// Seconds left on an entry's retry countdown (rounded up), or its delay.
pub fn retrySeconds(e: *const Entry) ?u32 {
    const st = e.status orelse return null;
    if (st.state != .retry) return null;
    const engine = hub.engine orelse return st.retry_delay_s;
    if (st.retry_at_ms == 0) return if (st.retry_delay_s > 0) st.retry_delay_s else null;
    const ms = st.retryRemainingMs(engine.nowMs());
    return @intCast(@divFloor(ms + 999, 1000));
}

// ---------------------------------------------------------------------------
// Settings, keyring, sleep
// ---------------------------------------------------------------------------

fn onResume() void {
    if (hub.engine) |e| e.notifyResume();
}

comptime {
    _ = adw;
    _ = gio;
    _ = TerminalPane;
}
