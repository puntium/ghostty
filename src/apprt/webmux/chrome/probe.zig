//! The engine's liveness probe: `GET /` through the tunnel's local socket
//! (main.js probe: any HTTP response within the timeout is an answer).
//! Runs on supervisor threads.
const std = @import("std");
const conn = @import("../../../webmux/conn.zig");
const net = @import("../../../webmux/net.zig");
const global = @import("../../../global.zig");

const alloc = std.heap.c_allocator;

pub fn probeFn() conn.ProbeFn {
    return .{ .func = probe };
}

fn probe(_: ?*anyopaque, socket_path: []const u8, timeout_ms: u32, why: *[]const u8) bool {
    var client = net.http.Client.init(alloc, global.io(), socket_path) catch {
        why.* = "OutOfMemory";
        return false;
    };
    defer client.deinit();
    var resp = client.fetch(alloc, .{
        .target = "/",
        .timeout_ms = timeout_ms,
        .max_body = 64 * 1024,
    }) catch |err| {
        why.* = @errorName(err);
        return false;
    };
    resp.deinit();
    return true;
}
