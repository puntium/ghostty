//! The host's file-system routes (host/internal/server/fs.go, watch.go),
//! typed, over `net.http.Client`. Pure Zig, no GTK; every call blocks, so
//! the browser calls them on worker threads.
//!
//!   GET  /api/fs/list?path=        {path, entries:[{name,type,symlink?}], truncated} | 400 {error}
//!   GET  /api/fs/preview?path=     {size, mtime, kind, …}                            | 400 {error}
//!   GET  /api/fs/raw?path=[&download=1]   the bytes                                 | 400 {error}
//!   POST /api/fs/upload?dir=&name= raw body ≤ 200 MiB → {name}                       | 400/413 {error}
//!   POST /api/fs/delete {path}     {ok:true}                                         | 400 {error}
//!   POST /api/fs/rename {path,name} {ok:true,name}                                   | 400 {error}
//!   GET  /api/fs/watch?path=       text/event-stream: ready | change | gone
//!
//! Every call returns `Result(T)`: the value, or the error text the
//! Electron client would show (the host's `error` code such as `ENOENT`,
//! or the transport error's name when the host could not be reached).
//! Everything is allocated from the caller's allocator; use an arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const net = @import("../../../webmux/net.zig");
const http = net.http;
const wire = @import("wire.zig");
const Result = wire.Result;
const Listing = wire.Listing;
const Preview = wire.Preview;
const target = wire.target;
const hostError = wire.hostError;
const errorField = wire.errorField;
pub const downloadTarget = wire.downloadTarget;
pub const watchTarget = wire.watchTarget;

fn transportError(err: anyerror) []const u8 {
    return @errorName(err);
}

fn fetchJson(client: *const http.Client, alloc: Allocator, opts: http.Options) Result([]const u8) {
    var resp = client.fetch(alloc, opts) catch |err| return .{ .err = transportError(err) };
    defer resp.head.deinit();
    if (!resp.ok()) return .{ .err = hostError(alloc, resp.status(), resp.body) };
    // A 200 can still carry {error} (files-widget.js fsApi checks out.error).
    if (errorField(alloc, resp.body)) |e| return .{ .err = e };
    return .{ .ok = resp.body };
}

pub fn list(client: *const http.Client, alloc: Allocator, path: []const u8) Allocator.Error!Result(Listing) {
    const tgt = try target(alloc, "/api/fs/list", .{ .path = path });
    const body = switch (fetchJson(client, alloc, .{ .target = tgt, .timeout_ms = 15_000 })) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    return wire.parseListing(alloc, body);
}

pub fn preview(client: *const http.Client, alloc: Allocator, path: []const u8) Allocator.Error!Result(Preview) {
    const tgt = try target(alloc, "/api/fs/preview", .{ .path = path });
    const body = switch (fetchJson(client, alloc, .{ .target = tgt, .timeout_ms = 15_000 })) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    return wire.parsePreview(alloc, body);
}

/// The whole file (image previews, markdown images). `max` caps it.
pub fn raw(client: *const http.Client, alloc: Allocator, path: []const u8, max: usize) Allocator.Error!Result([]const u8) {
    const tgt = try target(alloc, "/api/fs/raw", .{ .path = path });
    var resp = client.fetch(alloc, .{ .target = tgt, .timeout_ms = 60_000, .max_body = max }) catch |err|
        return .{ .err = transportError(err) };
    defer resp.head.deinit();
    if (!resp.ok()) return .{ .err = hostError(alloc, resp.status(), resp.body) };
    return .{ .ok = resp.body };
}

pub fn rename(client: *const http.Client, alloc: Allocator, path: []const u8, name: []const u8) Allocator.Error!Result([]const u8) {
    const body = try std.json.Stringify.valueAlloc(alloc, .{ .path = path, .name = name }, .{});
    const out = switch (fetchJson(client, alloc, .{
        .method = .POST,
        .target = "/api/fs/rename",
        .content_type = "application/json",
        .body = .{ .bytes = body },
    })) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    const parsed = std.json.parseFromSliceLeaky(struct { name: []const u8 = "" }, alloc, out, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{ .ok = name };
    return .{ .ok = if (parsed.name.len > 0) parsed.name else name };
}

pub fn delete(client: *const http.Client, alloc: Allocator, path: []const u8) Allocator.Error!Result(void) {
    const body = try std.json.Stringify.valueAlloc(alloc, .{ .path = path }, .{});
    return switch (fetchJson(client, alloc, .{
        .method = .POST,
        .target = "/api/fs/delete",
        .content_type = "application/json",
        .body = .{ .bytes = body },
    })) {
        .ok => .{ .ok = {} },
        .err => |e| .{ .err = e },
    };
}

/// Upload `length` bytes from `reader` as `dir/name` (`name` may contain
/// '/'). Returns the relative path the host wrote (deduped).
pub fn upload(
    client: *const http.Client,
    alloc: Allocator,
    dir: []const u8,
    name: []const u8,
    reader: *std.Io.Reader,
    length: u64,
) Allocator.Error!Result([]const u8) {
    if (length > wire.upload_limit) return .{ .err = "payload too large" };
    const tgt = try target(alloc, "/api/fs/upload", .{ .dir = dir, .name = name });
    const out = switch (fetchJson(client, alloc, .{
        .method = .POST,
        .target = tgt,
        .content_type = "application/octet-stream",
        .body = .{ .reader = .{ .reader = reader, .length = length } },
        .timeout_ms = 10 * 60_000,
    })) {
        .ok => |b| b,
        .err => |e| return .{ .err = e },
    };
    const parsed = std.json.parseFromSliceLeaky(struct { name: []const u8 = "" }, alloc, out, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{ .err = "invalid response" };
    return .{ .ok = parsed.name };
}
