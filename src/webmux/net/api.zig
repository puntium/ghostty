//! Typed helpers for the host's session API (host/internal/server/http.go):
//!
//!   GET    /                    → {ok, server, payloadHash, ptyhost}
//!   GET    /api/sessions        → [{id, cols, rows, title, createdAt, clients, pid}]
//!   POST   /api/sessions        {cols, rows} → 201 {id}
//!   DELETE /api/sessions/<id>   → {ok:true} | 404 {error}
//!
//! Failures from the host come back as `error.HttpStatus` with the status
//! and the host's `{"error": ...}` message in the optional `Diagnostics`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");

pub const Error = http.Error || error{
    /// Non-2xx answer; see Diagnostics.
    HttpStatus,
    /// 2xx answer whose body was not the expected JSON.
    InvalidBody,
};

/// Filled in on error.HttpStatus (and on InvalidBody, with the status).
pub const Diagnostics = struct {
    status: u16 = 0,
    /// The host's error message, truncated; empty if none.
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn message(self: *const Diagnostics) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn set(self: *Diagnostics, status: u16, body: []const u8, alloc: Allocator) void {
        self.status = status;
        self.message_len = 0;
        const parsed = std.json.parseFromSlice(struct { @"error": []const u8 = "" }, alloc, body, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const m = parsed.value.@"error";
        const n = @min(m.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], m[0..n]);
        self.message_len = n;
    }
};

pub const Health = struct {
    ok: bool = false,
    server: []const u8 = "",
    payloadHash: []const u8 = "",
    ptyhost: []const u8 = "",
};

pub const SessionInfo = struct {
    id: []const u8,
    cols: i64 = 0,
    rows: i64 = 0,
    title: []const u8 = "",
    createdAt: i64 = 0,
    clients: i64 = 0,
    pid: i64 = 0,
};

pub const CallOptions = struct {
    timeout_ms: ?u32 = 10_000,
    diag: ?*Diagnostics = null,
};

fn call(
    client: *const http.Client,
    alloc: Allocator,
    req: http.Options,
    comptime T: type,
    opts: CallOptions,
) Error!std.json.Parsed(T) {
    var r = req;
    r.timeout_ms = opts.timeout_ms;
    var resp = try client.fetch(alloc, r);
    defer resp.deinit();
    if (!resp.ok()) {
        if (opts.diag) |d| d.set(resp.status(), resp.body, alloc);
        return error.HttpStatus;
    }
    return resp.json(T, alloc) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            if (opts.diag) |d| d.* = .{ .status = resp.status() };
            return error.InvalidBody;
        },
    };
}

/// GET / — the liveness/identity probe (the connection supervisor polls it
/// with a 2 s timeout). Free with `deinit`.
pub fn health(client: *const http.Client, alloc: Allocator, opts: CallOptions) Error!std.json.Parsed(Health) {
    return call(client, alloc, .{ .target = "/" }, Health, opts);
}

/// GET /api/sessions. Free with `deinit`.
pub fn listSessions(client: *const http.Client, alloc: Allocator, opts: CallOptions) Error!std.json.Parsed([]SessionInfo) {
    return call(client, alloc, .{ .target = "/api/sessions" }, []SessionInfo, opts);
}

/// POST /api/sessions. Returns the new session id (owned by `alloc`).
pub fn createSession(client: *const http.Client, alloc: Allocator, cols: u16, rows: u16, opts: CallOptions) Error![]u8 {
    var buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"cols\":{d},\"rows\":{d}}}", .{ cols, rows }) catch unreachable;
    const parsed = try call(client, alloc, .{
        .method = .POST,
        .target = "/api/sessions",
        .content_type = "application/json",
        .body = .{ .bytes = body },
    }, struct { id: []const u8 }, opts);
    defer parsed.deinit();
    return alloc.dupe(u8, parsed.value.id);
}

/// DELETE /api/sessions/<id> (kills the session's shell). A missing session
/// is error.HttpStatus with status 404.
pub fn deleteSession(client: *const http.Client, alloc: Allocator, id: []const u8, opts: CallOptions) Error!void {
    const enc = try http.percentEncodeAlloc(alloc, id);
    defer alloc.free(enc);
    const target = try std.fmt.allocPrint(alloc, "/api/sessions/{s}", .{enc});
    defer alloc.free(target);
    const parsed = try call(client, alloc, .{ .method = .DELETE, .target = target }, struct { ok: bool = false }, opts);
    parsed.deinit();
}

/// The session WebSocket's request target: "/ws?session=<id>".
pub fn sessionWsTarget(alloc: Allocator, id: []const u8) Allocator.Error![]u8 {
    const enc = try http.percentEncodeAlloc(alloc, id);
    defer alloc.free(enc);
    return std.fmt.allocPrint(alloc, "/ws?session={s}", .{enc});
}
