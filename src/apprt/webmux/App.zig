//! The apprt App: the struct `main_ghostty.zig` creates and the core calls
//! into (`performAction`, `wakeup`). It owns the GObject Application,
//! which does the real work (application.zig).
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");

const Application = @import("application.zig").Application;

/// GTK application id (`me.puntium.webmux.gtk`).
pub const application_id = Application.application_id;

app: *Application,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    // Required by the apprt interface but unused.
    opts: struct {},
) !void {
    _ = opts;
    const app: *Application = try .new(self, core_app);
    errdefer app.unref();
    self.* = .{ .app = app };
}

pub fn run(self: *App) !void {
    try self.app.run();
}

pub fn terminate(self: *App) void {
    // Other things may still hold references; force the cleanup now.
    self.app.deinit();
}

/// Called by the core (from any thread) to wake up the event loop.
pub fn wakeup(self: *App) void {
    self.app.wakeup();
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    return try self.app.performAction(target, action, value);
}

/// `ghostty +new-window` and friends talk to a running instance over
/// D-Bus. webmux-gtk has no such IPC.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}
