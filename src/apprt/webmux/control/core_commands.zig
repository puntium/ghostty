//! The foundation's control-socket commands. See control.zig for the
//! protocol and WEBMUX.md › Control socket for the reference.

const std = @import("std");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const control = @import("../control.zig");
const Request = control.Request;
const Application = @import("../application.zig").Application;
const Window = @import("../window.zig").Window;
const TerminalPane = @import("../pane.zig").TerminalPane;
const key_event = @import("../key_event.zig");
const KeyEvent = key_event.KeyEvent;
const shortcuts = @import("../shortcuts.zig");
const termconfig = @import("../config.zig");
const iface = @import("../iface.zig");

const log = std.log.scoped(.webmux_control);

pub fn register() void {
    control.register(.{ .name = "help", .help = "list commands", .handler = &help });
    control.register(.{ .name = "dump", .help = "window, focused pane, grid, visible text, render path", .handler = &dump });
    control.register(.{ .name = "screenshot", .help = "{path, scale=<surface scale>}: render the active window through GTK to a PNG", .handler = &screenshot });
    control.register(.{ .name = "text", .help = "{text}: type a string into the focused pane, key by key", .handler = &text });
    control.register(.{ .name = "key", .help = "{key:\"ctrl+shift+w\"} or {key, action:press|release}: one key through shortcuts and the pane", .handler = &key });
    control.register(.{ .name = "mouse", .help = "{action:move|press|release|click|drag|scroll, x,y | col,row, x2,y2 | col2,row2, button, mods, dx,dy}: pointer input into the focused pane (CSS px)", .handler = &mouse });
    control.register(.{ .name = "selection", .help = "the focused pane's selected text (null if none)", .handler = &selection });
    control.register(.{ .name = "wait", .help = "{contains, timeout_ms=5000}: answer once the focused pane's visible text contains a string", .handler = &wait });
    control.register(.{ .name = "resize", .help = "{width, height}: set the active window's size", .handler = &resize });
    control.register(.{ .name = "theme", .help = "{scheme:dark|light}: switch the terminal colour scheme", .handler = &theme });
    control.register(.{ .name = "clipboard-sync", .help = "run iface.hooks.clipboardSync for the focused pane's connection (what the chrome does on window focus)", .handler = &clipboardSync });
    control.register(.{ .name = "focus", .help = "{value:bool}: give the focused pane keyboard focus, or take it away from the window's widgets", .handler = &focus });
    control.register(.{ .name = "shown", .help = "{value:bool}: Pane.setShown on the focused pane", .handler = &shown });
    control.register(.{ .name = "quit", .help = "quit the application (answers first)", .handler = &quit });
}

fn help(req: *Request) void {
    const Entry = struct { name: []const u8, help: []const u8 };
    const cmds = control.commands();
    const out = req.allocator().alloc(Entry, cmds.len) catch return req.fail("out of memory", .{});
    for (cmds, out) |c, *e| e.* = .{ .name = c.name, .help = c.help };
    req.ok(out);
}

//---------------------------------------------------------------
// dump

const PaneDump = struct {
    focused: bool,
    /// Remote panes: the host session; null for a local shell.
    session_id: ?[]const u8,
    /// Remote panes: "connecting" | "up" | "down"; null for local.
    link: ?[]const u8,
    /// Remote panes: snapshots replayed (first attach + one per reconnect).
    snapshots: ?u32,
    /// Remote panes: the last snapshot replay (bytes, wall ms), or null.
    last_replay: ?struct { bytes: usize, ms: u32 },
    /// Remote panes: the session's exit code once it exited.
    exit_code: ?i64,
    /// Rendering (mapped, shown, window not suspended).
    visible: bool,
    /// The core's scrollbar: total rows, viewport offset, viewport rows.
    scrollbar: struct { total: usize, offset: usize, len: usize },
    title: ?[]const u8,
    pwd: ?[]const u8,
    /// Size of the render surface in device pixels.
    size_px: struct { width: u32, height: u32 },
    /// What the shell told the core (from the pixel size and cell size).
    grid: ?struct { columns: u32, rows: u32 },
    /// What the terminal has applied (io thread; may lag briefly).
    terminal: ?TerminalPane.TerminalState,
    cell_px: struct { width: u32, height: u32 },
    /// Grid padding in device pixels (left, top).
    padding_px: struct { left: u32, top: u32 },
    /// The terminal area's top-left in window coordinates (CSS px), for
    /// aiming real pointer events (webmux-dev/realpointer).
    origin: struct { x: f64, y: f64 },
    content_scale: f32,
    renderer_health: []const u8,
    /// Frames presented per path: tells DMABUF from CPU fallback.
    frames: struct { dmabuf: u64, memory: u64, dmabuf_import_failures: u64 },
    text: ?[]const u8,
};

fn paneDump(req: *Request, pane: *TerminalPane, focused: bool) !PaneDump {
    const alloc = req.allocator();
    const size = pane.getSize();
    const cell = pane.getCellSize();
    const stats = pane.renderSurface().stats();
    const grid = pane.gridSize();
    return .{
        .focused = focused,
        .session_id = if (pane.sessionId()) |id| id else null,
        .link = if (pane.getLink()) |l| @tagName(l) else null,
        .snapshots = if (pane.remoteState()) |st| st.snapshots else null,
        .last_replay = if (pane.remoteState()) |st| (if (st.last_replay) |r| .{ .bytes = r.bytes, .ms = r.ms } else null) else null,
        .exit_code = if (pane.remoteState()) |st| st.exit_code else null,
        .visible = pane.isVisible(),
        .scrollbar = blk: {
            const sb = pane.getScrollbar();
            break :blk .{ .total = sb.total, .offset = sb.offset, .len = sb.len };
        },
        .title = pane.getTitle(),
        .pwd = pane.getPwd(),
        .size_px = .{ .width = size.width, .height = size.height },
        .grid = if (grid) |g| .{ .columns = g.columns, .rows = g.rows } else null,
        .terminal = pane.terminalState(),
        .cell_px = .{ .width = cell.width, .height = cell.height },
        .padding_px = if (pane.core()) |s| .{ .left = s.size.padding.left, .top = s.size.padding.top } else .{ .left = 0, .top = 0 },
        .origin = blk: {
            const o = pane.windowOrigin();
            break :blk .{ .x = o.x, .y = o.y };
        },
        .content_scale = pane.getContentScale().x,
        .renderer_health = @tagName(pane.getRendererHealth()),
        .frames = .{
            .dmabuf = stats.frames_dmabuf,
            .memory = stats.frames_memory,
            .dmabuf_import_failures = stats.dmabuf_import_failures,
        },
        .text = if (req.boolean("text") orelse true) try pane.visibleText(alloc) else null,
    };
}

fn typeNameOf(obj: anytype) []const u8 {
    const inst: *gobject.TypeInstance = @ptrCast(@alignCast(obj));
    const class = inst.f_g_class orelse return "?";
    return std.mem.span(gobject.typeName(class.f_g_type) orelse return "?");
}

fn dump(req: *Request) void {
    dumpInner(req) catch |err| req.fail("dump failed: {t}", .{err});
}

fn dumpInner(req: *Request) !void {
    const app = Application.default();
    const win = app.activeWindow() orelse return req.fail("no window", .{});
    const gwin = win.as(gtk.Window);
    const widget = win.as(gtk.Widget);

    const focused_pane = win.focusedPane();
    var buf: [16]*TerminalPane = undefined;
    const panes = win.panes(&buf);
    const dumps = try req.allocator().alloc(PaneDump, panes.len);
    var focused_index: ?usize = null;
    for (panes, dumps, 0..) |p, *d, i| {
        const is_focused = p == focused_pane and p.getFocused();
        if (p == focused_pane) focused_index = i;
        d.* = try paneDump(req, p, is_focused);
    }

    const native = widget.getNative();
    const surface = if (native) |n| n.getSurface() else null;
    const gsk_renderer = if (native) |n| n.getRenderer() else null;

    req.ok(.{
        .window = .{
            .width = widget.getWidth(),
            .height = widget.getHeight(),
            .title = if (gwin.getTitle()) |t| std.mem.span(t) else null,
            .active = gwin.isActive() != 0,
            .scale = if (surface) |s| s.getScale() else 1.0,
            .gsk_renderer = if (gsk_renderer) |r| typeNameOf(r) else null,
            .display = std.mem.span(widget.getDisplay().getName()),
        },
        .scheme = @tagName(app.getScheme()),
        .focused_pane = focused_index,
        .last_shortcut = shortcuts.last_action,
        .panes = dumps,
    });
}

//---------------------------------------------------------------
// screenshot

fn screenshot(req: *Request) void {
    const path = req.string("path") orelse return req.fail("missing \"path\"", .{});
    const app = Application.default();
    const win = app.activeWindow() orelse return req.fail("no window", .{});
    const widget = win.as(gtk.Widget);

    // The window's last rendered node (what the compositor was sent),
    // rendered again by the window's own GSK renderer into a texture:
    // independent of the compositor, includes the terminal's DMABUF or
    // memory texture like any other node.
    const paintable = gtk.WidgetPaintable.new(widget);
    defer paintable.unref();
    const w: f64 = @floatFromInt(widget.getWidth());
    const h: f64 = @floatFromInt(widget.getHeight());
    if (w <= 0 or h <= 0) return req.fail("window has no size yet", .{});

    const native = widget.getNative() orelse return req.fail("window not realized", .{});
    const renderer = native.getRenderer() orelse return req.fail("window has no renderer", .{});

    // Device pixels by default (HiDPI screenshots are full resolution);
    // {"scale": 1} for logical size.
    const scale: f64 = if (req.get("scale")) |v| switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 1.0,
    } else if (native.getSurface()) |s| s.getScale() else 1.0;

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
    req.ok(.{
        .path = path,
        .width = texture.getWidth(),
        .height = texture.getHeight(),
        .gsk_renderer = typeNameOf(renderer),
    });
}

//---------------------------------------------------------------
// keys

fn display() *gdk.Display {
    return gdk.Display.getDefault().?;
}

fn pressRelease(win: *Window, keyval: c_uint, state: gdk.ModifierType) bool {
    const press = KeyEvent.synthesize(display(), .press, keyval, state);
    const consumed = win.dispatchKey(press);
    var release = press;
    release.action = .release;
    _ = win.dispatchKey(release);
    return consumed;
}

fn key(req: *Request) void {
    const spec = req.string("key") orelse return req.fail("missing \"key\"", .{});
    const chord = key_event.parseChord(spec) catch |err| return req.fail("bad key \"{s}\": {t}", .{ spec, err });
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});

    const action = req.string("action") orelse "tap";
    var consumed = false;
    if (std.mem.eql(u8, action, "tap")) {
        consumed = pressRelease(win, chord.keyval, chord.state);
    } else if (std.mem.eql(u8, action, "press") or std.mem.eql(u8, action, "release")) {
        const a: @import("../../../input.zig").Action = if (action[0] == 'p') .press else .release;
        consumed = win.dispatchKey(KeyEvent.synthesize(display(), a, chord.keyval, chord.state));
    } else return req.fail("action must be tap, press or release", .{});

    req.ok(.{ .consumed = consumed, .keyval = chord.keyval, .shortcut = shortcuts.last_action });
}

fn keyvalForCodepoint(cp: u21) c_uint {
    return switch (cp) {
        '\n', '\r' => 0xff0d, // Return
        '\t' => 0xff09, // Tab
        0x1b => 0xff1b, // Escape
        0x08, 0x7f => 0xff08, // BackSpace
        else => gdk.unicodeToKeyval(cp),
    };
}

fn text(req: *Request) void {
    const str = req.string("text") orelse return req.fail("missing \"text\"", .{});
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    const view = std.unicode.Utf8View.init(str) catch return req.fail("text is not UTF-8", .{});
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |cp| : (count += 1) {
        _ = pressRelease(win, keyvalForCodepoint(cp), .{});
    }
    req.ok(.{ .keys = count });
}

//---------------------------------------------------------------
// mouse

const input = @import("../../../input.zig");

fn mouseButton(name: []const u8) ?input.MouseButton {
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "middle")) return .middle;
    if (std.mem.eql(u8, name, "right")) return .right;
    return null;
}

fn mouseMods(spec: []const u8) ?input.Mods {
    var mods: input.Mods = .{};
    if (spec.len == 0) return mods;
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |m| {
        if (std.mem.eql(u8, m, "ctrl")) mods.ctrl = true else if (std.mem.eql(u8, m, "shift")) mods.shift = true else if (std.mem.eql(u8, m, "alt")) mods.alt = true else if (std.mem.eql(u8, m, "super")) mods.super = true else return null;
    }
    return mods;
}

/// A point from {x, y} (CSS px in the pane) or {col, row} (cell centre),
/// with an optional key suffix ("" or "2" for drag ends).
fn mousePoint(req: *Request, pane: *TerminalPane, comptime suffix: []const u8) ?struct { x: f64, y: f64 } {
    if (req.int("col" ++ suffix)) |c| {
        const r = req.int("row" ++ suffix) orelse return null;
        const p = pane.cellCenter(@intCast(c), @intCast(r)) orelse return null;
        return .{ .x = p.x, .y = p.y };
    }
    const x = req.get("x" ++ suffix) orelse return null;
    const y = req.get("y" ++ suffix) orelse return null;
    const fx: f64 = switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    const fy: f64 = switch (y) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    return .{ .x = fx, .y = fy };
}

fn mouse(req: *Request) void {
    mouseInner(req) catch |err| req.fail("mouse failed: {t}", .{err});
}

fn mouseInner(req: *Request) !void {
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    const pane = win.focusedPane() orelse return req.fail("no pane", .{});
    const action = req.string("action") orelse "click";
    const button = mouseButton(req.string("button") orelse "left") orelse
        return req.fail("button must be left, middle or right", .{});
    const mods = mouseMods(req.string("mods") orelse "") orelse
        return req.fail("mods must be like ctrl+shift", .{});

    var consumed = false;
    if (std.mem.eql(u8, action, "scroll")) {
        const dy: f64 = @floatFromInt(req.int("dy") orelse 0);
        const dx: f64 = @floatFromInt(req.int("dx") orelse 0);
        if (mousePoint(req, pane, "")) |p| _ = try pane.injectMouse(.{ .motion = .{ .x = p.x, .y = p.y } }, mods);
        consumed = try pane.injectMouse(.{ .scroll = .{ .dx = dx, .dy = dy } }, mods);
    } else {
        const p = mousePoint(req, pane, "") orelse return req.fail("need {{x,y}} or {{col,row}}", .{});
        _ = try pane.injectMouse(.{ .motion = .{ .x = p.x, .y = p.y } }, mods);
        if (std.mem.eql(u8, action, "move")) {
            consumed = true;
        } else if (std.mem.eql(u8, action, "press")) {
            consumed = try pane.injectMouse(.{ .press = button }, mods);
        } else if (std.mem.eql(u8, action, "release")) {
            consumed = try pane.injectMouse(.{ .release = button }, mods);
        } else if (std.mem.eql(u8, action, "click")) {
            consumed = try pane.injectMouse(.{ .press = button }, mods);
            _ = try pane.injectMouse(.{ .release = button }, mods);
        } else if (std.mem.eql(u8, action, "drag")) {
            const p2 = mousePoint(req, pane, "2") orelse return req.fail("drag needs {{x2,y2}} or {{col2,row2}}", .{});
            consumed = try pane.injectMouse(.{ .press = button }, mods);
            // A few intermediate motions, like a real drag.
            for (1..5) |i| {
                const t = @as(f64, @floatFromInt(i)) / 4.0;
                _ = try pane.injectMouse(.{ .motion = .{
                    .x = p.x + (p2.x - p.x) * t,
                    .y = p.y + (p2.y - p.y) * t,
                } }, mods);
            }
            _ = try pane.injectMouse(.{ .release = button }, mods);
        } else return req.fail("action must be move, press, release, click, drag or scroll", .{});
    }

    const surface = pane.core().?;
    req.ok(.{
        .consumed = consumed,
        .has_selection = surface.hasSelection(),
        .mouse_reporting = surface.mouseReportingActive(),
        // The core's hover state: the link under the pointer is underlined.
        .over_link = surface.mouse.over_link,
    });
}

fn selection(req: *Request) void {
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    const pane = win.focusedPane() orelse return req.fail("no pane", .{});
    const surface = pane.core() orelse return req.fail("pane not ready", .{});
    const sel = surface.selectionString(req.allocator()) catch |err| return req.fail("{t}", .{err});
    req.ok(.{ .text = sel });
}

//---------------------------------------------------------------
// wait

const Waiter = struct {
    req: *Request,
    needle: []const u8,
    deadline_us: i64,
};

fn wait(req: *Request) void {
    const needle = req.string("contains") orelse return req.fail("missing \"contains\"", .{});
    const timeout_ms = req.int("timeout_ms") orelse 5000;
    const waiter = req.allocator().create(Waiter) catch return req.fail("out of memory", .{});
    waiter.* = .{
        .req = req,
        .needle = needle,
        .deadline_us = glib.getMonotonicTime() + timeout_ms * 1000,
    };
    if (!pollWaiter(waiter)) _ = glib.timeoutAdd(50, waitTick, waiter);
}

/// True when answered.
fn pollWaiter(w: *Waiter) bool {
    const req = w.req;
    if (Application.default().activeWindow()) |win| {
        if (win.focusedPane()) |pane| {
            const visible = pane.visibleText(req.allocator()) catch null;
            if (visible) |t| if (std.mem.indexOf(u8, t, w.needle) != null) {
                req.ok(.{ .found = true });
                return true;
            };
        }
    }
    if (glib.getMonotonicTime() >= w.deadline_us) {
        req.fail("timed out waiting for \"{s}\"", .{w.needle});
        return true;
    }
    return false;
}

fn waitTick(ud: ?*anyopaque) callconv(.c) c_int {
    const w: *Waiter = @ptrCast(@alignCast(ud.?));
    return if (pollWaiter(w)) 0 else 1;
}

//---------------------------------------------------------------
// window, theme, quit

fn resize(req: *Request) void {
    const width = req.int("width") orelse return req.fail("missing \"width\"", .{});
    const height = req.int("height") orelse return req.fail("missing \"height\"", .{});
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    win.as(gtk.Window).setDefaultSize(@intCast(width), @intCast(height));
    req.ok(.{ .requested = .{ .width = width, .height = height } });
}

fn theme(req: *Request) void {
    const name = req.string("scheme") orelse return req.fail("missing \"scheme\"", .{});
    const scheme = termconfig.Scheme.fromString(name) orelse return req.fail("scheme must be dark or light", .{});
    Application.default().setScheme(scheme) catch |err| return req.fail("failed: {t}", .{err});
    req.ok(.{ .scheme = name });
}

fn clipboardSync(req: *Request) void {
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    const pane = win.focusedPane() orelse return req.fail("no pane", .{});
    const st = pane.remoteState() orelse return req.fail("not a remote pane", .{});
    const hook = iface.hooks.clipboardSync orelse return req.fail("no clipboardSync hook registered", .{});
    const c: iface.Conn = .{ .socket_path = st.socket_path, .slug = st.conn_name, .name = st.conn_name };
    hook(&c);
    req.ok(.{ .called = true });
}

fn focus(req: *Request) void {
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    if (req.boolean("value") orelse true) {
        const pane = win.focusedPane() orelse return req.fail("no pane", .{});
        pane.grabFocus();
    } else {
        win.as(gtk.Window).setFocus(null);
    }
    req.ok(.{});
}

fn shown(req: *Request) void {
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    const pane = win.focusedPane() orelse return req.fail("no pane", .{});
    pane.setShown(req.boolean("value") orelse true);
    req.ok(.{ .visible = pane.isVisible() });
}

fn quit(req: *Request) void {
    req.ok(.{ .quitting = true });
    _ = glib.idleAddOnce(struct {
        fn cb(_: ?*anyopaque) callconv(.c) void {
            Application.default().quit();
        }
    }.cb, null);
}
