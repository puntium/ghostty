//! Tests against a real, isolated webmux host (see testhost.zig). Skipped
//! when the host binary cannot be found.
const std = @import("std");
const t = std.testing;
const TestHost = @import("testhost.zig");
const http = @import("http.zig");
const api = @import("api.zig");
const websocket = @import("websocket.zig");
const sse = @import("sse.zig");
const protocol = @import("protocol.zig");
const Conn = @import("Conn.zig");

fn startHost() !*TestHost {
    return TestHost.start(t.allocator, t.io, t.environ);
}

test "live: health, create, list, delete" {
    const host = try startHost();
    defer host.deinit();
    var c = try host.client();
    defer c.deinit();
    const a = t.allocator;

    const h = try api.health(&c, a, .{ .timeout_ms = 2000 });
    defer h.deinit();
    try t.expect(h.value.ok);
    try t.expectEqualStrings("webmux", h.value.server);
    try t.expectEqualStrings(host.name, h.value.ptyhost);

    const id = try api.createSession(&c, a, 100, 30, .{});
    defer a.free(id);
    const list = try api.listSessions(&c, a, .{});
    defer list.deinit();
    try t.expectEqual(@as(usize, 1), list.value.len);
    try t.expectEqualStrings(id, list.value[0].id);
    try t.expectEqual(@as(i64, 100), list.value[0].cols);
    try t.expectEqual(@as(i64, 30), list.value[0].rows);

    try api.deleteSession(&c, a, id, .{});
    var diag: api.Diagnostics = .{};
    try t.expectError(error.HttpStatus, api.deleteSession(&c, a, id, .{ .diag = &diag }));
    try t.expectEqual(@as(u16, 404), diag.status);
    try t.expect(diag.message().len > 0);

    // 404 route, buffered
    var r = try c.fetch(a, .{ .target = "/nope" });
    defer r.deinit();
    try t.expectEqual(@as(u16, 404), r.status());
    try t.expectEqualStrings("application/json", r.head.header("Content-Type").?);
}

/// Read frames until an output frame's accumulated text contains `needle`.
fn readUntil(ws: *websocket.WebSocket, acc: *std.ArrayList(u8), needle: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    while (std.mem.indexOf(u8, acc.items, needle) == null) {
        _ = arena.reset(.retain_capacity);
        const m = try ws.readMessage();
        const frame = try protocol.parseServerFrame(arena.allocator(), m.text);
        switch (frame) {
            .output => |d| try acc.appendSlice(t.allocator, d),
            else => {},
        }
    }
}

test "live: websocket attach, input, output, resize, exit" {
    const host = try startHost();
    defer host.deinit();
    var c = try host.client();
    defer c.deinit();
    const a = t.allocator;
    const id = try api.createSession(&c, a, 80, 24, .{});
    defer a.free(id);
    const target = try api.sessionWsTarget(a, id);
    defer a.free(target);

    const ws = try websocket.WebSocket.connect(a, t.io, host.socket_path, target, .{});
    defer ws.deinit();

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const first = try ws.readMessage();
    const snap = try protocol.parseServerFrame(arena.allocator(), first.text);
    try t.expect(snap == .snapshot);
    try t.expectEqual(@as(u16, 80), snap.snapshot.cols);
    try t.expect(snap.snapshot.pid.? > 0);

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(a);
    const f = try protocol.encodeClientFrameAlloc(a, .{ .input = "echo hi-$((6*7)) é\r" });
    defer a.free(f);
    try ws.sendText(f);
    try readUntil(ws, &acc, "hi-42 é");

    const rf = try protocol.encodeClientFrameAlloc(a, .{ .resize = .{ .cols = 132, .rows = 40 } });
    defer a.free(rf);
    try ws.sendText(rf);
    const sz = try protocol.encodeClientFrameAlloc(a, .{ .input = "stty size\r" });
    defer a.free(sz);
    try ws.sendText(sz);
    try readUntil(ws, &acc, "40 132");

    try ws.ping("x");
    const ex = try protocol.encodeClientFrameAlloc(a, .{ .input = "exit 7\r" });
    defer a.free(ex);
    try ws.sendText(ex);
    while (true) {
        _ = arena.reset(.retain_capacity);
        const m = ws.readMessage() catch |err| return err;
        switch (m) {
            .text => |txt| {
                const fr = try protocol.parseServerFrame(arena.allocator(), txt);
                if (fr == .exit) {
                    try t.expectEqual(@as(i64, 7), fr.exit.code);
                    break;
                }
            },
            else => return error.UnexpectedMessage,
        }
    }
    // The host closes the socket after the exit frame.
    const after = ws.readMessage();
    if (after) |m| try t.expect(m == .close) else |err| try t.expect(err == error.EndOfStream or err == error.ConnectionReset);
}

test "live: missing session gets an error frame" {
    const host = try startHost();
    defer host.deinit();
    const ws = try websocket.WebSocket.connect(t.allocator, t.io, host.socket_path, "/ws?session=nope", .{});
    defer ws.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const m = try ws.readMessage();
    const fr = try protocol.parseServerFrame(arena.allocator(), m.text);
    try t.expectEqualStrings("no such session", fr.@"error".message);
}

test "live: upgrade on a wrong path is rejected" {
    const host = try startHost();
    defer host.deinit();
    try t.expectError(error.UpgradeRejected, websocket.WebSocket.connect(t.allocator, t.io, host.socket_path, "/nope", .{}));
}

test "live: interrupt wakes a blocked reader promptly" {
    const host = try startHost();
    defer host.deinit();
    var c = try host.client();
    defer c.deinit();
    const a = t.allocator;
    const id = try api.createSession(&c, a, 80, 24, .{});
    defer a.free(id);
    const target = try api.sessionWsTarget(a, id);
    defer a.free(target);

    var round: usize = 0;
    while (round < 5) : (round += 1) {
        const ws = try websocket.WebSocket.connect(a, t.io, host.socket_path, target, .{});
        defer ws.deinit();
        _ = try ws.readMessage(); // snapshot
        const Reader = struct {
            fn run(w: *websocket.WebSocket, out: *?anyerror) void {
                while (true) {
                    _ = w.readMessage() catch |err| {
                        out.* = err;
                        return;
                    };
                }
            }
        };
        var result: ?anyerror = null;
        const th = try std.Thread.spawn(.{}, Reader.run, .{ ws, &result });
        try std.Io.sleep(t.io, .fromMilliseconds(50), .awake);
        const t0 = Conn.now();
        ws.interrupt();
        th.join();
        const ms = @divFloor(Conn.now() - t0, std.time.ns_per_ms);
        try t.expectEqual(@as(?anyerror, error.Interrupted), result);
        try t.expect(ms < 500);
        // Sends after interrupt fail cleanly.
        try t.expectError(error.Interrupted, ws.sendText("{}"));
    }
}

test "live: http timeout, streamed download and uploads" {
    const host = try startHost();
    defer host.deinit();
    var c = try host.client();
    defer c.deinit();
    const a = t.allocator;
    const home = try std.fs.path.join(a, &.{ host.dir, "home" });
    defer a.free(home);

    // 3 MiB of patterned bytes, uploaded with Content-Length (reader) and chunked.
    const big = try a.alloc(u8, 3 * 1024 * 1024 + 17);
    defer a.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 13));

    inline for (.{ true, false }) |with_len| {
        var rd: std.Io.Reader = .fixed(big);
        const henc = try http.percentEncodeAlloc(a, home);
        defer a.free(henc);
        const name = if (with_len) "up-len.bin" else "up-chunked.bin";
        const target = try std.fmt.allocPrint(a, "/api/fs/upload?dir={s}&name={s}", .{ henc, name });
        defer a.free(target);
        var r = try c.fetch(a, .{
            .method = .POST,
            .target = target,
            .content_type = "application/octet-stream",
            .body = .{ .reader = .{ .reader = &rd, .length = if (with_len) big.len else null } },
        });
        defer r.deinit();
        try t.expect(r.ok());

        // Stream it back down.
        const path = try std.fs.path.join(a, &.{ home, name });
        defer a.free(path);
        const penc = try http.percentEncodeAlloc(a, path);
        defer a.free(penc);
        const raw = try std.fmt.allocPrint(a, "/api/fs/raw?path={s}", .{penc});
        defer a.free(raw);
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        var head = try c.download(a, .{ .target = raw }, &aw.writer);
        defer head.deinit();
        try t.expectEqual(@as(u16, 200), head.status);
        try t.expect(std.mem.eql(u8, big, aw.written()));
    }

    // SSE: ready, change on a new file, gone when the directory vanishes,
    // and the idle timeout fires while nothing happens.
    const wdir = try std.fs.path.join(a, &.{ home, "w" });
    defer a.free(wdir);
    try std.Io.Dir.cwd().createDirPath(t.io, wdir);
    const wenc = try http.percentEncodeAlloc(a, wdir);
    defer a.free(wenc);
    const wt = try std.fmt.allocPrint(a, "/api/fs/watch?path={s}", .{wenc});
    defer a.free(wt);
    const rd = try sse.Reader.open(&c, a, wt, .{ .idle_timeout_ms = 300 });
    defer rd.close();
    const ready = (try rd.next()).?;
    try t.expectEqualStrings("ready", ready.event);
    try t.expectError(error.Timeout, rd.next());
    // A timed-out reader is still usable with a longer deadline.
    rd.stream.idle_timeout_ms = 5000;
    const f = try std.fs.path.join(a, &.{ wdir, "x" });
    defer a.free(f);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = f, .data = "x" });
    const ch = (try rd.next()).?;
    try t.expectEqualStrings("change", ch.event);
    try std.Io.Dir.cwd().deleteTree(t.io, wdir);
    while (true) {
        const ev = (try rd.next()) orelse return error.NoGoneEvent;
        if (std.mem.eql(u8, ev.event, "gone")) break;
    }
    try t.expect((try rd.next()) == null);

    // A request timeout: the watch stream never ends, so a buffered fetch of
    // it must time out at its deadline.
    const t0 = Conn.now();
    try t.expectError(error.Timeout, c.fetch(a, .{ .target = "/api/fs/watch?path=%7E", .timeout_ms = 300 }));
    const ms = @divFloor(Conn.now() - t0, std.time.ns_per_ms);
    try t.expect(ms >= 290 and ms < 1500);

    // A socket that does not exist.
    var bad = try http.Client.init(a, t.io, "/tmp/wm-does-not-exist/h.sock");
    defer bad.deinit();
    try t.expectError(error.FileNotFound, api.health(&bad, a, .{ .timeout_ms = 2000 }));
}
