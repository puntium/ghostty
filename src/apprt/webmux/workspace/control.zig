//! Control-socket commands for the workspace (registered from
//! control/commands.zig). They enter at the same functions the GTK
//! controllers and actions call, so the strip can be driven and checked
//! without a keyboard or a pointer (the headless seat has none).
const std = @import("std");
const glib = @import("glib");
const gdk = @import("gdk");
const gtk = @import("gtk");

const control = @import("../control.zig");
const Application = @import("../application.zig").Application;
const iface = @import("../iface.zig");
const layout = @import("../../../webmux/layout.zig");
const ws_mod = @import("workspace.zig");
const Workspace = ws_mod.Workspace;

pub fn register() void {
    control.register(.{ .name = "workspace", .help = "dump the strip: columns, panes (boxes, focus, fade, titles), dividers, scroll, animation state", .handler = &dump });
    control.register(.{ .name = "pane-command", .help = "name=<layout command> (new-terminal, close-pane, focus-left, …): activate pane.<cmd> on the workspace", .handler = &paneCommand });
    control.register(.{ .name = "workspace-wait", .help = "[panes=N] [timeout_ms=5000]: answer once the strip is settled (loaded, no animation, no scroll chase, no create in flight) and has N panes", .handler = &wait });
    control.register(.{ .name = "workspace-click", .help = "id=<pane> part=body|bar|close: the frame's press / title-bar click / ✕ handlers", .handler = &click });
    control.register(.{ .name = "workspace-divider", .help = "col=C row=R dy=PX [steps=N]: drag divider R of column C by dy through the drag handlers", .handler = &divider });
    control.register(.{ .name = "workspace-scroll", .help = "dx dy [unit=wheel|surface] [over=<pane id>]: the strip's capture then bubble scroll handlers", .handler = &scroll });
    control.register(.{ .name = "workspace-motion", .help = "[reduced=true|false|null] [time_scale=F]: test knobs for reduced motion and animation speed", .handler = &motion });
    control.register(.{ .name = "workspace-front", .help = "front=true|false: Workspace.setFront", .handler = &front });
    control.register(.{ .name = "workspace-reload", .help = "Workspace.reload: re-list the host's sessions and reconcile", .handler = &reload });
    control.register(.{ .name = "workspace-save", .help = "write the layout file now", .handler = &save });
    control.register(.{ .name = "workspace-settings", .help = "[fade=0..100] [min_cols] [max_cols]: replace iface.settings (dev/test only; the chrome owns them)", .handler = &settings });
}

/// The workspace a command acts on: by default the one in front (mapped:
/// the chrome hides the others' views), as the shortcuts and the header
/// buttons reach it; `index=N` picks the Nth in widget-tree order. (The
/// audit's "wrong host" pane-command was this function taking the first
/// workspace in the tree, a hidden host's, whatever was in front.)
fn workspace(req: *control.Request) ?*Workspace {
    const win = Application.default().activeWindow() orelse {
        req.fail("no window", .{});
        return null;
    };
    var buf: [16]*Workspace = undefined;
    var n: usize = 0;
    ws_mod.collect(win.as(gtk.Widget), &buf, &n);
    if (n == 0) {
        req.fail("no workspace in the window", .{});
        return null;
    }
    if (req.int("index")) |idx| {
        const i: usize = @intCast(@max(0, idx));
        if (i >= n) {
            req.fail("only {d} workspaces", .{n});
            return null;
        }
        return buf[i];
    }
    return frontOf(buf[0..n]) orelse {
        req.fail("no workspace in front (the connection page is showing)", .{});
        return null;
    };
}

fn frontOf(list: []const *Workspace) ?*Workspace {
    for (list) |ws| if (ws.as(gtk.Widget).getMapped() != 0) return ws;
    return null;
}

fn dump(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    const d = ws.dump(req.allocator()) catch return req.fail("out of memory", .{});
    req.ok(d);
}

fn paneCommand(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    const name = req.string("name") orelse return req.fail("missing \"name\"", .{});
    const cmd = layout.Command.fromName(name) orelse return req.fail("unknown command \"{s}\"", .{name});
    var buf: [64]u8 = undefined;
    const action = std.fmt.bufPrintSentinel(&buf, "{s}.{s}", .{ iface.actions.pane_group, cmd.name() }, 0) catch unreachable;
    const ok = ws.as(gtk.Widget).activateAction(action.ptr, null) != 0;
    req.ok(.{ .action = action, .activated = ok });
}

const Waiter = struct {
    req: *control.Request,
    /// Which workspace (`index`, as for every command here).
    index: ?usize,
    panes: ?usize,
    deadline_us: i64,
};

fn wait(req: *control.Request) void {
    _ = workspace(req) orelse return;
    const w = req.allocator().create(Waiter) catch return req.fail("out of memory", .{});
    w.* = .{
        .req = req,
        .index = if (req.int("index")) |i| @intCast(@max(0, i)) else null,
        .panes = if (req.int("panes")) |n| @intCast(n) else null,
        .deadline_us = glib.getMonotonicTime() + (req.int("timeout_ms") orelse 5000) * 1000,
    };
    if (!poll(w)) _ = glib.timeoutAdd(20, waitTick, w);
}

fn poll(w: *Waiter) bool {
    const req = w.req;
    const win = Application.default().activeWindow();
    if (win) |wn| {
        var buf: [16]*Workspace = undefined;
        var n: usize = 0;
        ws_mod.collect(wn.as(gtk.Widget), &buf, &n);
        const pick: ?*Workspace = if (w.index) |i| (if (i < n) buf[i] else null) else frontOf(buf[0..n]);
        if (pick) |ws| {
            const d = ws.dump(req.allocator()) catch null;
            if (d) |dd| if (ws.settled() and (w.panes == null or dd.pane_count == w.panes.?)) {
                req.ok(.{ .settled = true, .panes = dd.pane_count });
                return true;
            };
        }
    }
    if (glib.getMonotonicTime() >= w.deadline_us) {
        req.fail("timed out waiting for the workspace to settle", .{});
        return true;
    }
    return false;
}

fn waitTick(ud: ?*anyopaque) callconv(.c) c_int {
    const w: *Waiter = @ptrCast(@alignCast(ud.?));
    return if (poll(w)) 0 else 1;
}

fn click(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    const id = req.string("id") orelse return req.fail("missing \"id\"", .{});
    const part = req.string("part") orelse "body";
    const frame = ws.paneFrame(id) orelse return req.fail("no pane {s}", .{id});
    // Every press goes through the frame's capture-phase handler first.
    frame.pressed();
    if (std.mem.eql(u8, part, "bar")) {
        frame.barClicked();
    } else if (std.mem.eql(u8, part, "close")) {
        frame.closeButton();
    } else if (!std.mem.eql(u8, part, "body")) return req.fail("part must be body, bar or close", .{});
    req.ok(.{ .clicked = id, .part = part });
}

fn divider(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    const col: usize = @intCast(req.int("col") orelse 0);
    const row: usize = @intCast(req.int("row") orelse 0);
    const dy: f64 = @floatFromInt(req.int("dy") orelse return req.fail("missing \"dy\"", .{}));
    const steps: usize = @intCast(@max(1, req.int("steps") orelse 4));
    const d = ws.dividerAt(col, row) orelse return req.fail("no divider {d} in column {d}", .{ row, col });
    // As GestureDrag would: begin at the divider's middle, a few updates,
    // then the end (the layout is saved on release).
    const start = d.box.y + d.box.h / 2;
    ws.dividerDragBegin(d, start);
    for (1..steps + 1) |i| ws.dividerDragTo(d, start + dy * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps)));
    ws.dividerDragEnd(d);
    req.ok(.{ .col = col, .row = row, .dy = dy });
}

fn scroll(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    const num = struct {
        fn get(r: *control.Request, k: []const u8) f64 {
            return switch (r.get(k) orelse return 0) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => 0,
            };
        }
    };
    const dx = num.get(req, "dx");
    const dy = num.get(req, "dy");
    const unit: gdk.ScrollUnit = if (std.mem.eql(u8, req.string("unit") orelse "surface", "wheel")) .wheel else .surface;
    const over = ws.scrollOver(req.string("over"));
    const cap = ws.handleScroll(dx, dy, unit, true, over);
    // A file browser at its edge lets the event bubble up to the strip;
    // a terminal (or nothing) never gets that far once captured.
    const bub = if (!cap and over == .files) ws.handleScroll(dx, dy, unit, false, null) else false;
    const d = ws.dump(req.allocator()) catch return req.fail("out of memory", .{});
    req.ok(.{ .capture = cap, .bubble = bub, .scroll = d.scroll });
}

fn motion(req: *control.Request) void {
    if (req.get("reduced")) |v| switch (v) {
        .bool => |b| Workspace.reduced_override = b,
        .null => Workspace.reduced_override = null,
        else => return req.fail("reduced must be true, false or null", .{}),
    };
    if (req.get("time_scale")) |v| switch (v) {
        .integer => |i| Workspace.time_scale = @floatFromInt(@max(1, i)),
        .float => |f| Workspace.time_scale = @max(0.01, f),
        else => return req.fail("time_scale must be a number", .{}),
    };
    req.ok(.{ .reduced_override = Workspace.reduced_override, .time_scale = Workspace.time_scale });
}

fn front(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    const f = req.boolean("front") orelse return req.fail("missing \"front\"", .{});
    ws.setFront(f);
    req.ok(.{ .front = f });
}

fn reload(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    ws.reload();
    req.ok(.{ .reloading = true });
}

fn save(req: *control.Request) void {
    const ws = workspace(req) orelse return;
    ws.saveNow();
    req.ok(.{ .saved = true });
}

fn settings(req: *control.Request) void {
    var s = iface.settings.get();
    if (req.int("fade")) |f| s.unfocused_fade = @intCast(std.math.clamp(f, 0, 100));
    if (req.int("min_cols")) |v| s.min_cols = @intCast(std.math.clamp(v, 40, 400));
    if (req.int("max_cols")) |v| s.max_cols = @intCast(std.math.clamp(v, 40, 400));
    if (s.max_cols < s.min_cols) s.max_cols = s.min_cols;
    iface.settings.set(s);
    req.ok(.{ .fade = s.unfocused_fade, .min_cols = s.min_cols, .max_cols = s.max_cols });
}
