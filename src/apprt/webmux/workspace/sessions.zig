//! The workspace's calls to the host's session API (`net.api`), each on a
//! worker thread of its own, with the result marshalled back to the GTK
//! main loop (`mainloop.post`). The target (the workspace widget) is held
//! by a strong reference for the round trip.
const std = @import("std");
const Allocator = std.mem.Allocator;
const net = @import("../../../webmux/net.zig");
const global = @import("../../../global.zig");
const mainloop = @import("../mainloop.zig");

const log = std.log.scoped(.webmux_workspace);
const alloc = std.heap.c_allocator;

pub const Session = struct {
    id: []u8,
    title: []u8,
};

pub const ListResult = struct {
    /// Owned; null on failure.
    sessions: ?[]Session = null,
    /// The error's name on failure.
    err: []const u8 = "",

    pub fn deinit(self: *ListResult) void {
        if (self.sessions) |all| {
            for (all) |s| {
                alloc.free(s.id);
                alloc.free(s.title);
            }
            alloc.free(all);
        }
        self.* = .{};
    }
};

pub const CreateResult = struct {
    /// Owned; null on failure.
    id: ?[]u8 = null,
    err: []const u8 = "",
    /// The host's error message, if it gave one.
    message: [256]u8 = undefined,
    message_len: usize = 0,
    /// What the command asked for (new column / below).
    below: bool = false,
};

/// GET /api/sessions; calls `target.onSessionList(*ListResult)` on the main
/// loop and then `target.unref()`.
pub fn list(comptime T: type, target: *T, socket_path: []const u8) !void {
    const sock = try alloc.dupe(u8, socket_path);
    errdefer alloc.free(sock);
    const t = try std.Thread.spawn(.{}, listThread(T).run, .{ target.ref(), sock });
    t.detach();
}

fn listThread(comptime T: type) type {
    return struct {
        const Post = struct {
            target: *T,
            result: ListResult,
            fn deliver(self: *Post) void {
                defer self.target.unref();
                defer self.result.deinit();
                self.target.onSessionList(&self.result);
            }
        };
        fn run(target: *T, sock: []u8) void {
            defer alloc.free(sock);
            mainloop.post(Post{ .target = target, .result = fetch(sock) }, Post.deliver);
        }
    };
}

fn fetch(sock: []const u8) ListResult {
    var client = net.http.Client.init(alloc, global.io(), sock) catch return .{ .err = "OutOfMemory" };
    defer client.deinit();
    const parsed = net.api.listSessions(&client, alloc, .{}) catch |err| return .{ .err = @errorName(err) };
    defer parsed.deinit();
    const out = alloc.alloc(Session, parsed.value.len) catch return .{ .err = "OutOfMemory" };
    var n: usize = 0;
    for (parsed.value) |s| {
        const id = alloc.dupe(u8, s.id) catch break;
        const title = alloc.dupe(u8, s.title) catch {
            alloc.free(id);
            break;
        };
        out[n] = .{ .id = id, .title = title };
        n += 1;
    }
    if (n < parsed.value.len) {
        var r: ListResult = .{ .sessions = out[0..n] };
        r.deinit();
        return .{ .err = "OutOfMemory" };
    }
    return .{ .sessions = out };
}

/// POST /api/sessions {cols:80, rows:24} (app.js createServerSession); calls
/// `target.onSessionCreated(*CreateResult)` on the main loop, then unref.
pub fn create(comptime T: type, target: *T, socket_path: []const u8, below: bool) !void {
    const sock = try alloc.dupe(u8, socket_path);
    errdefer alloc.free(sock);
    const t = try std.Thread.spawn(.{}, createThread(T).run, .{ target.ref(), sock, below });
    t.detach();
}

fn createThread(comptime T: type) type {
    return struct {
        const Post = struct {
            target: *T,
            result: CreateResult,
            fn deliver(self: *Post) void {
                defer self.target.unref();
                defer if (self.result.id) |id| alloc.free(id);
                self.target.onSessionCreated(&self.result);
            }
        };
        fn run(target: *T, sock: []u8, below: bool) void {
            defer alloc.free(sock);
            var result: CreateResult = .{ .below = below };
            var diag: net.api.Diagnostics = .{};
            if (net.http.Client.init(alloc, global.io(), sock)) |c| {
                var client = c;
                defer client.deinit();
                if (net.api.createSession(&client, alloc, 80, 24, .{ .diag = &diag })) |id| {
                    result.id = id;
                } else |err| {
                    result.err = @errorName(err);
                    const m = diag.message();
                    @memcpy(result.message[0..m.len], m);
                    result.message_len = m.len;
                }
            } else |_| result.err = "OutOfMemory";
            mainloop.post(Post{ .target = target, .result = result }, Post.deliver);
        }
    };
}

/// DELETE /api/sessions/<id>, errors ignored (app.js removeTile's kill).
pub fn delete(socket_path: []const u8, id: []const u8) void {
    const sock = alloc.dupe(u8, socket_path) catch return;
    const id_copy = alloc.dupe(u8, id) catch {
        alloc.free(sock);
        return;
    };
    const t = std.Thread.spawn(.{}, deleteThread, .{ sock, id_copy }) catch {
        alloc.free(sock);
        alloc.free(id_copy);
        return;
    };
    t.detach();
}

fn deleteThread(sock: []u8, id: []u8) void {
    defer alloc.free(sock);
    defer alloc.free(id);
    var client = net.http.Client.init(alloc, global.io(), sock) catch return;
    defer client.deinit();
    net.api.deleteSession(&client, alloc, id, .{}) catch |err| {
        log.debug("delete session {s}: {t} (ignored)", .{ id, err });
    };
}
