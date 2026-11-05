//! Worker threads for the file browser. Every host call blocks (net.http),
//! so it runs on a thread of its own and its result is marshalled back to
//! the GTK main loop (mainloop.post).
//!
//! `Shared` is the part of a browser that outlives it: the socket path and
//! a pointer back to the browser that the browser clears when it is
//! disposed. Workers hold a reference to it, never to the browser, so a
//! pane can close while requests are in flight; their results are then
//! dropped on the main thread.
//!
//!   Task(J)   one request: `J.work` on a thread, `J.done` on the main
//!             thread (only while the browser lives). Everything the job
//!             allocates comes from the task's arena, freed after `done`.
//!   Watch     one `GET /api/fs/watch` stream with EventSource semantics:
//!             reconnects 3 s after a drop, reports `reopened` when a
//!             stream opens again after having been open, `change`,
//!             `gone` (then stops) and `closed` (the server refused the
//!             stream: the browser forgets it and opens a new one on its
//!             next render, as files-widget.js does on a CLOSED source).
const std = @import("std");
const Allocator = std.mem.Allocator;

const net = @import("../../../webmux/net.zig");
const global = @import("../../../global.zig");
const mainloop = @import("../mainloop.zig");
const wire = @import("wire.zig");

const log = std.log.scoped(.webmux_files);
pub const alloc = std.heap.c_allocator;

pub const Shared = struct {
    rc: std.atomic.Value(u32) = .init(1),
    socket_path: [:0]u8,
    /// The browser while it lives (main thread only).
    browser: ?*anyopaque = null,

    pub fn create(socket_path: []const u8) Allocator.Error!*Shared {
        const self = try alloc.create(Shared);
        errdefer alloc.destroy(self);
        self.* = .{ .socket_path = try alloc.dupeSentinel(u8, socket_path, 0) };
        return self;
    }

    pub fn retain(self: *Shared) *Shared {
        _ = self.rc.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Shared) void {
        if (self.rc.fetchSub(1, .acq_rel) != 1) return;
        alloc.free(self.socket_path);
        alloc.destroy(self);
    }

    pub fn client(self: *const Shared, a: Allocator) Allocator.Error!net.http.Client {
        return net.http.Client.init(a, global.io(), self.socket_path);
    }
};

/// A one-shot job. `J` declares
///   fn work(job: *J, shared: *Shared, arena: Allocator) void   (worker thread)
///   fn done(job: *J, browser: *anyopaque, arena: Allocator) void (main thread)
pub fn Task(comptime J: type) type {
    return struct {
        const Self = @This();
        shared: *Shared,
        arena: std.heap.ArenaAllocator,
        job: J = undefined,

        /// Main thread. Fill `job` from `arena()`, then `start()`.
        pub fn create(shared: *Shared) Allocator.Error!*Self {
            const self = try alloc.create(Self);
            self.* = .{ .shared = shared.retain(), .arena = .init(alloc) };
            return self;
        }

        pub fn arenaAlloc(self: *Self) Allocator {
            return self.arena.allocator();
        }

        pub fn start(self: *Self) void {
            const thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
                log.warn("cannot start a worker thread ({t}); running inline", .{err});
                threadMain(self);
                return;
            };
            thread.detach();
        }

        fn threadMain(self: *Self) void {
            self.job.work(self.shared, self.arena.allocator());
            mainloop.post(Post{ .task = self }, Post.run);
        }

        const Post = struct {
            task: *Self,
            fn run(p: *Post) void {
                const self = p.task;
                defer {
                    self.arena.deinit();
                    self.shared.release();
                    alloc.destroy(self);
                }
                if (self.shared.browser) |b| self.job.done(b, self.arena.allocator());
            }
        };
    };
}

pub const WatchEvent = enum { change, gone, reopened, closed };

pub const Watch = struct {
    rc: std.atomic.Value(u32) = .init(2), // the browser's and the thread's
    shared: *Shared,
    dir: []u8,
    on_event: *const fn (browser: *anyopaque, w: *Watch, ev: WatchEvent) void,
    stop_flag: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    reader: ?*net.sse.Reader = null,
    /// Main thread: the browser stopped it (events still queued are dropped).
    stopped: bool = false,

    pub fn start(shared: *Shared, dir: []const u8, on_event: *const fn (*anyopaque, *Watch, WatchEvent) void) Allocator.Error!*Watch {
        const self = try alloc.create(Watch);
        errdefer alloc.destroy(self);
        self.* = .{ .shared = shared.retain(), .dir = try alloc.dupe(u8, dir), .on_event = on_event };
        const thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
            log.warn("cannot start a watch thread for {s}: {t}", .{ dir, err });
            self.stopped = true;
            self.release(); // the thread's reference
            return self;
        };
        thread.detach();
        return self;
    }

    /// Main thread: stop the stream and drop the browser's reference.
    pub fn stop(self: *Watch) void {
        self.stopped = true;
        self.stop_flag.store(true, .release);
        const io = global.io();
        self.mutex.lockUncancelable(io);
        if (self.reader) |r| r.interrupt();
        self.mutex.unlock(io);
        self.release();
    }

    fn release(self: *Watch) void {
        if (self.rc.fetchSub(1, .acq_rel) != 1) return;
        self.shared.release();
        alloc.free(self.dir);
        alloc.destroy(self);
    }

    fn stopping(self: *Watch) bool {
        return self.stop_flag.load(.acquire);
    }

    /// Sleep `ms`, waking early when stopped.
    fn nap(self: *Watch, ms: u32) void {
        var left = ms;
        while (left > 0 and !self.stopping()) {
            const step = @min(left, 100);
            global.io().sleep(.fromMilliseconds(step), .awake) catch {};
            left -= step;
        }
    }

    fn post(self: *Watch, ev: WatchEvent) void {
        _ = self.rc.fetchAdd(1, .monotonic);
        mainloop.post(Deliver{ .w = self, .ev = ev }, Deliver.run);
    }

    const Deliver = struct {
        w: *Watch,
        ev: WatchEvent,
        fn run(d: *Deliver) void {
            defer d.w.release();
            if (d.w.stopped) return;
            const b = d.w.shared.browser orelse return;
            d.w.on_event(b, d.w, d.ev);
        }
    };

    /// EventSource's default reconnection delay (Chromium: 3 s).
    const retry_ms = 3000;

    fn threadMain(self: *Watch) void {
        defer self.release();
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var client = self.shared.client(a) catch return;
        const target = wire.watchTarget(a, self.dir) catch return;
        var opened = false;
        while (!self.stopping()) {
            const r = net.sse.Reader.open(&client, alloc, target, .{
                .timeout_ms = 10_000,
                .idle_timeout_ms = 60_000,
            }) catch |err| switch (err) {
                error.BadResponse => {
                    self.post(.closed);
                    return;
                },
                else => {
                    self.nap(retry_ms);
                    continue;
                },
            };
            const io = global.io();
            self.mutex.lockUncancelable(io);
            if (self.stopping()) {
                self.mutex.unlock(io);
                r.close();
                return;
            }
            self.reader = r;
            self.mutex.unlock(io);

            if (opened) self.post(.reopened);
            opened = true;
            var gone = false;
            while (true) {
                const ev = (r.next() catch break) orelse break;
                if (std.mem.eql(u8, ev.event, "change")) {
                    self.post(.change);
                } else if (std.mem.eql(u8, ev.event, "gone")) {
                    gone = true;
                    break;
                }
            }
            self.mutex.lockUncancelable(io);
            self.reader = null;
            self.mutex.unlock(io);
            r.close();
            if (gone) {
                self.post(.gone);
                return;
            }
            if (!self.stopping()) self.nap(retry_ms);
        }
    }
};
