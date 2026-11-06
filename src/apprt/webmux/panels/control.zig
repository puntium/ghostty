//! The panels' control-socket commands. Each command enters at the same
//! function the GUI uses (a button's handler, a control's own signal, the
//! window's key handler), so the headless seat (no pointer) can exercise
//! them. `wmctl help` lists them with their arguments.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const conn = @import("../../../webmux/conn.zig");
const control = @import("../control.zig");
const Request = control.Request;
const iface = @import("../iface.zig");
const Application = @import("../application.zig").Application;
const key_event = @import("../key_event.zig");
const KeyEvent = key_event.KeyEvent;
const model = @import("model.zig");
const settings = @import("settings.zig");
const settings_panel = @import("settings_panel.zig");
const log_window = @import("log_window.zig");
const toast = @import("toast.zig");
const url = @import("url.zig");

pub fn register() void {
    const cmds = [_]control.Command{
        .{ .name = "settings", .help = "the applied settings, where they came from, writes through the engine, the app's scheme", .handler = &settingsGet },
        .{ .name = "settings-set", .help = "{theme, fade, min_cols, max_cols, persist=true}: change settings as the panel does (any subset)", .handler = &settingsSet },
        .{ .name = "settings-show", .help = "open the settings panel (app.show-settings)", .handler = &settingsShow },
        .{ .name = "settings-close", .help = "close the settings panel (Done)", .handler = &settingsClose },
        .{ .name = "settings-dump", .help = "the settings panel's controls (open, values, focus)", .handler = &settingsDump },
        .{ .name = "settings-ui", .help = "{control:theme|fade|min_cols|max_cols|open_log|done|release, value}: operate one panel control (release = the fade slider let go)", .handler = &settingsUi },
        .{ .name = "log-show", .help = "open or focus the connection log window (app.show-log)", .handler = &logShow },
        .{ .name = "log-close", .help = "close the log window", .handler = &logClose },
        .{ .name = "log-dump", .help = "{limit}: the log window's filters, hosts, status bar and visible rows (the last `limit`)", .handler = &logDump },
        .{ .name = "log-filter", .help = "{host:all|<name>|client (no host), level:debug+|info+|warn+|error, text, follow}: set the toolbar", .handler = &logFilter },
        .{ .name = "log-press", .help = "{button:copy_visible|copy_all|reveal|clear}: press a toolbar button", .handler = &logPress },
        .{ .name = "log-key", .help = "{key:\"Escape\"|\"ctrl+f\"|\"ctrl+shift+c\"|…}: a key through the log window's key handler", .handler = &logKey },
        .{ .name = "log-scroll", .help = "{to:top|bottom|<px from top>}: scroll the lines (follow reacts as to a user scroll)", .handler = &logScroll },
        .{ .name = "log-hover", .help = "{line}: hover a visible line (null: none)", .handler = &logHover },
        .{ .name = "log-push", .help = "{level, msg, conn, src:main|page, data:{…}, count=1}: push entries into the engine's log (sanitized like a page's POST /log)", .handler = &logPush },
        .{ .name = "status", .help = "{text, from}: show a status message (iface.services.status); `from` = the connection it comes from", .handler = &statusShow },
        .{ .name = "status-front", .help = "{name}: tell the toast which connection is in front (null: the connection page), as the chrome will", .handler = &statusFront },
        .{ .name = "status-dump", .help = "the toast of the active window: visible, text", .handler = &statusDump },
        .{ .name = "url", .help = "{target, action:open|copy|choose, pane}: iface.services.url, parent = terminal pane number `pane` (default: the focused one)", .handler = &urlAct },
        .{ .name = "url-sink", .help = "{mode:record|launch, clear}: the launch sink; returns what was recorded and last copied", .handler = &urlSink },
        .{ .name = "url-chooser", .help = "{press:cancel|copy|open}: the top link chooser's state, optionally press a button", .handler = &urlChooser },
        .{ .name = "panels-screenshot", .help = "{window:main|log, path, scale}: render that window (dialogs included) to a PNG", .handler = &screenshot },
        .{ .name = "panels-tree", .help = "{window:main|log, depth=12}: widget tree with CSS names and classes", .handler = &tree },
    };
    for (cmds) |c| control.register(c);
}

// ---------------------------------------------------------------------------
// settings

const SettingsView = struct {
    theme: []const u8,
    unfocused_fade: u8,
    min_cols: u16,
    max_cols: u16,

    fn of(s: *const conn.Settings) SettingsView {
        return .{ .theme = s.theme.slice(), .unfocused_fade = s.unfocused_fade, .min_cols = s.min_cols, .max_cols = s.max_cols };
    }
};

fn settingsResult(req: *Request) void {
    const s = settings.current();
    const theme = req.allocator().dupe(u8, s.theme.slice()) catch return req.fail("out of memory", .{});
    var v = SettingsView.of(&s);
    v.theme = theme;
    const stored: ?SettingsView = if (iface.engine) |e| blk: {
        const es = e.settings();
        var sv = SettingsView.of(&es);
        sv.theme = req.allocator().dupe(u8, es.theme.slice()) catch "";
        break :blk sv;
    } else null;
    req.ok(.{
        .applied = v,
        .stored = stored,
        .engine = iface.engine != null,
        .config_path = if (iface.engine) |e| e.configPath() else null,
        .source = @tagName(settings.source),
        .persisted = settings.persisted,
        .app_scheme = @tagName(Application.default().getScheme()),
        .adw_dark = Application.default().as(@import("adw").Application).getStyleManager().getDark() != 0,
        .css_dark = @import("style.zig").dark,
    });
}

fn settingsGet(req: *Request) void {
    settingsResult(req);
}

fn settingsSet(req: *Request) void {
    var patch: conn.SettingsPatch = .{};
    if (req.string("theme")) |t| patch.theme = t;
    if (req.get("fade")) |v| patch.unfocused_fade = model.numberFromJson(v) orelse std.math.nan(f64);
    if (req.get("min_cols")) |v| patch.min_cols = model.numberFromJson(v) orelse std.math.nan(f64);
    if (req.get("max_cols")) |v| patch.max_cols = model.numberFromJson(v) orelse std.math.nan(f64);
    _ = settings.update(patch, req.boolean("persist") orelse true);
    settingsResult(req);
}

fn settingsShow(req: *Request) void {
    Application.default().as(@import("gio").ActionGroup).activateAction("show-settings", null);
    req.ok(settings_panel.dump());
}

fn settingsClose(req: *Request) void {
    settings_panel.close();
    req.ok(.{ .closed = true });
}

fn settingsDump(req: *Request) void {
    req.ok(settings_panel.dump());
}

fn settingsUi(req: *Request) void {
    const name = req.string("control") orelse return req.fail("missing \"control\"", .{});
    if (std.mem.eql(u8, name, "release")) {
        settings_panel.flushFade();
        return settingsResult(req);
    }
    const which = std.meta.stringToEnum(settings_panel.Control, name) orelse return req.fail("unknown control {s}", .{name});
    const value: ?f64 = if (req.get("value")) |v| model.numberFromJson(v) else null;
    settings_panel.operate(which, value, req.string("value")) catch |err| return req.fail("{t}", .{err});
    settingsResult(req);
}

// ---------------------------------------------------------------------------
// log window

fn logShow(req: *Request) void {
    Application.default().as(@import("gio").ActionGroup).activateAction("show-log", null);
    req.ok(.{ .open = log_window.instance != null });
}

fn logClose(req: *Request) void {
    log_window.close();
    req.ok(.{ .open = log_window.instance != null });
}

const RowView = struct {
    seq: u64,
    time: []const u8,
    t: []const u8,
    level: []const u8,
    conn: ?[]const u8,
    src: []const u8,
    msg: []const u8,
    data: []const u8,
    line: []const u8,
};

fn logDump(req: *Request) void {
    const w = log_window.instance orelse return req.ok(.{ .open = false });
    const a = req.allocator();
    const limit: usize = if (req.int("limit")) |l| @intCast(@max(0, l)) else w.shown.items.len;
    const from = w.shown.items.len -| limit;
    const rows = a.alloc(RowView, w.shown.items.len - from) catch return req.fail("out of memory", .{});
    for (w.shown.items[from..], rows) |r, *v| v.* = .{
        .seq = r.seq,
        .time = r.time,
        .t = r.t,
        .level = @tagName(r.level),
        .conn = r.conn,
        .src = @tagName(r.src),
        .msg = r.msg,
        .data = r.data,
        .line = r.line,
    };
    var hosts = a.alloc([]const u8, w.host_keys.items.len) catch return req.fail("out of memory", .{});
    for (w.host_keys.items, 0..) |k, i| hosts[i] = if (k) |s| (if (std.mem.eql(u8, s, model.client_key)) model.client_label else s) else "all";
    const f = w.filter();
    const adj = w.scroll.getVadjustment();
    const empty_visible = w.empty.as(gtk.Widget).getVisible() != 0;
    req.ok(.{
        .open = true,
        .title = std.mem.span(w.window.getTitle() orelse ""),
        .size = .{ .width = w.window.as(gtk.Widget).getWidth(), .height = w.window.as(gtk.Widget).getHeight() },
        .active = w.window.isActive() != 0,
        .filters = .{
            .host = hosts[w.host_dd.getSelected()],
            .level = model.level_labels[w.level_dd.getSelected()],
            .text = f.text,
            .follow = w.follow.getActive() != 0,
        },
        .hosts = hosts,
        .total = w.rows.items.len,
        .shown = w.shown.items.len,
        .last_seq = w.last_seq,
        .count = std.mem.span(w.count.getText()),
        .flash = std.mem.span(w.flash.getText()),
        .file = std.mem.span(w.file.getText()),
        .empty = if (empty_visible) std.mem.span(w.empty.getText()) else null,
        .scroll = .{ .value = adj.getValue(), .upper = adj.getUpper(), .page = adj.getPageSize() },
        .hover = w.hover_line,
        .buttons_sensitive = w.copy_visible.as(gtk.Widget).getSensitive() != 0,
        .focus = focusName(w),
        .toolbar = toolbarBounds(req, w),
        .rows = rows,
    });
}

const Bounds = struct { name: []const u8, x: i32, y: i32, w: i32, h: i32 };

fn boundsIn(widget: *gtk.Widget, target: *gtk.Widget) ?Bounds {
    var r: graphene.Rect = undefined;
    if (widget.computeBounds(target, &r) == 0) return null;
    return .{ .name = std.mem.span(widget.getCssName()), .x = @intFromFloat(@round(r.f_origin.f_x)), .y = @intFromFloat(@round(r.f_origin.f_y)), .w = @intFromFloat(@round(r.f_size.f_width)), .h = @intFromFloat(@round(r.f_size.f_height)) };
}

/// Every toolbar item's box in window coordinates (geometry checks).
fn toolbarBounds(req: *Request, w: *log_window.LogWindow) []Bounds {
    var list: std.ArrayList(Bounds) = .empty;
    const bar = w.search.as(gtk.Widget).getParent() orelse return &.{};
    var c = bar.getFirstChild();
    while (c) |child| : (c = child.getNextSibling()) {
        if (boundsIn(child, w.window.as(gtk.Widget))) |b| list.append(req.allocator(), b) catch {};
    }
    return list.items;
}

fn focusName(w: *log_window.LogWindow) ?[]const u8 {
    const f = w.window.getFocus() orelse return null;
    if (f == w.search.as(gtk.Widget) or f.isAncestor(w.search.as(gtk.Widget)) != 0) return "search";
    if (f == w.view.as(gtk.Widget)) return "lines";
    return std.mem.span(f.getCssName());
}

fn logFilter(req: *Request) void {
    log_window.setFilters(req.string("host"), req.string("level"), req.string("text")) catch |err| return req.fail("{t}", .{err});
    if (req.boolean("follow")) |on| if (log_window.instance) |w| w.follow.setActive(@intFromBool(on));
    req.ok(.{ .ok = true });
}

fn logPress(req: *Request) void {
    const name = req.string("button") orelse return req.fail("missing \"button\"", .{});
    const which = std.meta.stringToEnum(log_window.Button, name) orelse return req.fail("unknown button {s}", .{name});
    if (log_window.instance == null) return req.fail("log window not open", .{});
    log_window.press(which);
    req.ok(.{ .pressed = name });
}

fn logKey(req: *Request) void {
    const w = log_window.instance orelse return req.fail("log window not open", .{});
    const spec = req.string("key") orelse return req.fail("missing \"key\"", .{});
    const chord = key_event.parseChord(spec) catch |err| return req.fail("bad key: {t}", .{err});
    const ev = KeyEvent.synthesize(w.window.as(gtk.Widget).getDisplay(), .press, chord.keyval, chord.state);
    const did = log_window.handleKey(w, ev);
    req.ok(.{ .handled = @tagName(did), .open = log_window.instance != null });
}

fn logScroll(req: *Request) void {
    const w = log_window.instance orelse return req.fail("log window not open", .{});
    const adj = w.scroll.getVadjustment();
    const to = req.get("to") orelse return req.fail("missing \"to\"", .{});
    const value: f64 = switch (to) {
        .string => |s| if (std.mem.eql(u8, s, "top")) 0 else if (std.mem.eql(u8, s, "bottom")) adj.getUpper() - adj.getPageSize() else model.numberFromJson(to) orelse return req.fail("to: top|bottom|<px>", .{}),
        else => model.numberFromJson(to) orelse return req.fail("to: top|bottom|<px>", .{}),
    };
    // As an upward wheel or scrollbar drag would.
    if (value < adj.getValue()) log_window.noteUserScroll(w);
    adj.setValue(value);
    req.ok(.{ .value = adj.getValue(), .follow = w.follow.getActive() != 0 });
}

fn logHover(req: *Request) void {
    const w = log_window.instance orelse return req.fail("log window not open", .{});
    const line: ?usize = if (req.int("line")) |l| @intCast(@max(0, l)) else null;
    if (line) |l| if (l >= w.shown.items.len) return req.fail("no visible line {d}", .{l});
    log_window.setHover(w, line);
    req.ok(.{ .hover = w.hover_line, .tooltip = if (line) |l| w.shown.items[l].t else null });
}

fn logPush(req: *Request) void {
    const e = iface.engine orelse return req.fail("no connection engine", .{});
    const count: usize = @intCast(@max(1, req.int("count") orelse 1));
    const src: conn.Log.Source = if (req.string("src")) |s| std.meta.stringToEnum(conn.Log.Source, s) orelse .main else .main;
    const name = req.string("conn");
    const lg = e.log();
    for (0..count) |_| lg.pushJson(name, src, .{ .object = req.args });
    req.ok(.{ .pushed = count, .seq = lg.seq });
}

// ---------------------------------------------------------------------------
// status

fn statusShow(req: *Request) void {
    const text = req.string("text") orelse return req.fail("missing \"text\"", .{});
    iface.services.status(req.string("from"), text);
    req.ok(toast.state());
}

fn statusFront(req: *Request) void {
    toast.setFront(req.string("name"));
    req.ok(toast.state());
}

fn statusDump(req: *Request) void {
    req.ok(toast.state());
}

// ---------------------------------------------------------------------------
// urls

fn urlAct(req: *Request) void {
    const target = req.string("target") orelse return req.fail("missing \"target\"", .{});
    const name = req.string("action") orelse "choose";
    const action = std.meta.stringToEnum(iface.services.UrlAction, name) orelse return req.fail("action: open|copy|choose", .{});
    const parent: ?*gtk.Widget = blk: {
        const w = Application.default().activeWindow() orelse break :blk null;
        if (req.int("pane")) |i| {
            var buf: [64]*@import("../pane.zig").TerminalPane = undefined;
            const ps = w.panes(&buf);
            if (i < 0 or i >= ps.len) return req.fail("no pane {d}", .{i});
            break :blk ps[@intCast(i)].as(gtk.Widget);
        }
        break :blk if (w.focusedPane()) |p| p.as(gtk.Widget) else null;
    };
    iface.services.url(target, action, parent);
    urlState(req);
}

fn urlState(req: *Request) void {
    const Rec = struct { kind: []const u8, target: []const u8 };
    const recs = req.allocator().alloc(Rec, url.recorded.items.len) catch return req.fail("out of memory", .{});
    for (url.recorded.items, recs) |r, *o| o.* = .{ .kind = @tagName(r.kind), .target = r.target };
    req.ok(.{
        .sink = @tagName(url.sink),
        .recorded = recs,
        .last_copied = url.last_copied,
        .choosers = url.choosers.items.len,
        .status = toast.state(),
    });
}

fn urlSink(req: *Request) void {
    if (req.string("mode")) |m| {
        url.sink = std.meta.stringToEnum(url.Sink, m) orelse return req.fail("mode: record|launch", .{});
    }
    if (req.boolean("clear") orelse false) url.clearRecorded();
    urlState(req);
}

fn urlChooser(req: *Request) void {
    if (req.string("press")) |p| {
        const which = std.meta.stringToEnum(url.Chooser.Button, p) orelse return req.fail("press: cancel|copy|open", .{});
        const c = url.topChooser() orelse return req.fail("no link chooser open", .{});
        url.press(c, which);
    }
    const c = url.topChooser() orelse return req.ok(.{ .open = false, .count = url.choosers.items.len });
    const focus: ?[]const u8 = blk: {
        const f = c.dialog.as(adw.Dialog).getFocus() orelse break :blk null;
        if (gobject.ext.cast(gtk.Button, f)) |b| if (b.getLabel()) |l| break :blk std.mem.span(l);
        break :blk std.mem.span(f.getCssName());
    };
    req.ok(.{
        .open = true,
        .count = url.choosers.items.len,
        .url = c.url,
        .kind = @tagName(c.kind),
        .open_label = model.chooserOpenLabel(c.kind),
        .focus = focus,
        .shown_text = std.mem.span(c.label.getText()),
        .markup = std.mem.span(c.label.getLabel()),
    });
}

// ---------------------------------------------------------------------------
// screenshots and widget tree

fn pickWindow(req: *Request) ?*gtk.Widget {
    const which = req.string("window") orelse "main";
    if (std.mem.eql(u8, which, "log")) {
        const w = log_window.instance orelse return null;
        return w.window.as(gtk.Widget);
    }
    const win = Application.default().activeWindow() orelse return null;
    return win.as(gtk.Widget);
}

fn screenshot(req: *Request) void {
    const path = req.string("path") orelse return req.fail("missing \"path\"", .{});
    const widget = pickWindow(req) orelse return req.fail("no such window", .{});
    const paintable = gtk.WidgetPaintable.new(widget);
    defer paintable.unref();
    const w: f64 = @floatFromInt(widget.getWidth());
    const h: f64 = @floatFromInt(widget.getHeight());
    if (w <= 0 or h <= 0) return req.fail("window has no size yet", .{});
    const native = widget.getNative() orelse return req.fail("window not realized", .{});
    const renderer = native.getRenderer() orelse return req.fail("window has no renderer", .{});
    const scale: f64 = if (req.get("scale")) |v| (model.numberFromJson(v) orelse 1.0) else if (native.getSurface()) |s| s.getScale() else 1.0;
    const snap = gtk.Snapshot.new();
    snap.scale(@floatCast(scale), @floatCast(scale));
    paintable.as(gdk.Paintable).snapshot(snap.as(gdk.Snapshot), w, h);
    const node = snap.freeToNode() orelse return req.fail("window has not been drawn yet", .{});
    defer node.unref();
    const viewport: graphene.Rect = .{
        .f_origin = .{ .f_x = 0, .f_y = 0 },
        .f_size = .{ .f_width = @floatCast(w * scale), .f_height = @floatCast(h * scale) },
    };
    const texture = renderer.renderTexture(node, &viewport);
    defer texture.unref();
    const path_z = req.allocator().dupeSentinel(u8, path, 0) catch return req.fail("out of memory", .{});
    if (texture.saveToPng(path_z.ptr) == 0) return req.fail("could not write {s}", .{path});
    req.ok(.{ .path = path, .width = texture.getWidth(), .height = texture.getHeight() });
}

fn tree(req: *Request) void {
    const widget = pickWindow(req) orelse return req.fail("no such window", .{});
    const depth: usize = @intCast(@max(1, req.int("depth") orelse 12));
    var aw: std.Io.Writer.Allocating = .init(req.allocator());
    walk(&aw.writer, widget, 0, depth) catch return req.fail("out of memory", .{});
    req.ok(.{ .tree = aw.written() });
}

fn walk(out: *std.Io.Writer, widget: *gtk.Widget, level: usize, max: usize) !void {
    if (level >= max) return;
    for (0..level) |_| try out.writeAll("  ");
    try out.print("{s}", .{std.mem.span(widget.getCssName())});
    const cs: [*:null]?[*:0]u8 = @ptrCast(widget.getCssClasses());
    var i: usize = 0;
    while (cs[i]) |c| : (i += 1) try out.print(".{s}", .{std.mem.span(c)});
    @import("glib").strfreev(@ptrCast(cs));
    const st = widget.getStateFlags();
    try out.print(" {d}x{d}{s}{s}{s}\n", .{
        widget.getWidth(),
        widget.getHeight(),
        if (widget.getVisible() == 0) " (hidden)" else "",
        if (st.prelight) " :hover" else "",
        if (st.focus_within and !st.focus_visible) " :focus-within" else if (st.focus_visible) " :focus-visible" else "",
    });
    var child = widget.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) try walk(out, c, level + 1, max);
}
