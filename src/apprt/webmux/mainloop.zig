//! Running code on the GTK main thread.
//!
//! GTK objects may only be touched on the main thread, but the pure
//! packages (`src/webmux/`) and the core's own threads (renderer, termio)
//! deliver callbacks on theirs. This is the one sanctioned way across:
//!
//!     // On any thread:
//!     mainloop.post(Update{ .pane = pane.ref(), .state = .up }, Update.run);
//!
//!     const Update = struct {
//!         pane: *TerminalPane, // strong ref taken above, dropped in run
//!         state: LinkState,
//!         fn run(self: *Update) void { // on the main thread
//!             defer self.pane.unref();
//!             self.pane.setLinkState(self.state);
//!         }
//!     };
//!
//! `post` copies the value to the heap (glib allocator, aborts on OOM like
//! the rest of glib, so it cannot fail), queues an idle source on the
//! default main context and returns immediately. The function runs on the
//! next main-loop iteration, then the copy is freed. Values posted from one
//! thread run in the order they were posted.
//!
//! Lifetime is the caller's problem: anything the value points at must
//! still be alive when it runs. For GObjects, take a strong reference
//! (`ref()`) before posting and drop it in the callback, or post a
//! `WeakRef` and `get()` it there. Never post a borrowed pointer to
//! something the main thread might free in the meantime.

const std = @import("std");
const glib = @import("glib");

/// Run `func(&copy_of_value)` on the GTK main thread. Callable from any
/// thread, including the main thread (then it runs on a later iteration,
/// never re-entrantly).
pub fn post(value: anytype, comptime func: fn (*@TypeOf(value)) void) void {
    const T = @TypeOf(value);
    const Box = struct {
        value: T,

        fn run(ud: ?*anyopaque) callconv(.c) void {
            const box: *@This() = @ptrCast(@alignCast(ud.?));
            defer glib.ext.destroy(box);
            func(&box.value);
        }
    };

    const box = glib.ext.create(Box);
    box.* = .{ .value = value };
    // g_idle_add_once uses the global default main context, which is the
    // one Application.run iterates. It is documented thread-safe.
    _ = glib.idleAddOnce(Box.run, box);
}

/// True when called on the thread that owns the default main context
/// (the GTK main thread while Application.run is active).
pub fn isMainThread() bool {
    return glib.MainContext.isOwner(glib.MainContext.default()) != 0;
}

/// Debug check for functions that must only run on the main thread.
pub fn assertMainThread() void {
    std.debug.assert(isMainThread());
}

test "post from another thread runs on the owning thread, in order" {
    const testing = std.testing;

    const ctx = glib.MainContext.default();
    try testing.expect(glib.MainContext.acquire(ctx) != 0);
    defer glib.MainContext.release(ctx);

    const State = struct {
        var seen: [3]u32 = .{ 0, 0, 0 };
        var count: usize = 0;
        var on_main: bool = true;
    };

    const Msg = struct {
        n: u32,
        fn run(self: *@This()) void {
            if (!isMainThread()) State.on_main = false;
            State.seen[State.count] = self.n;
            State.count += 1;
        }
    };

    const Worker = struct {
        fn work() void {
            post(Msg{ .n = 1 }, Msg.run);
            post(Msg{ .n = 2 }, Msg.run);
            post(Msg{ .n = 3 }, Msg.run);
        }
    };

    const thread = try std.Thread.spawn(.{}, Worker.work, .{});
    thread.join();

    // Nothing ran on the worker thread.
    try testing.expectEqual(@as(usize, 0), State.count);

    var spins: usize = 0;
    while (State.count < 3 and spins < 1000) : (spins += 1) {
        _ = glib.MainContext.iteration(ctx, 0);
    }

    try testing.expectEqual(@as(usize, 3), State.count);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, &State.seen);
    try testing.expect(State.on_main);
}
