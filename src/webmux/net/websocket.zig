//! RFC 6455 WebSocket client over a unix stream socket.
//!
//! Built for the session socket's usage pattern:
//!   - one thread blocks in `readMessage` (pings are answered there,
//!     fragmented messages reassembled, close frames replied to);
//!   - any thread may call `sendText` / `sendBinary` / `ping` / `close`
//!     (serialized by an internal mutex; a frame is never interleaved);
//!   - any thread may call `interrupt` to make a blocked `readMessage` (and
//!     any blocked send) return `error.Interrupted` promptly, e.g. at
//!     shutdown. `deinit` is called by the owner once everyone is done.
//!
//! No extensions (permessage-deflate is not offered), no subprotocols.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Conn = @import("Conn.zig");
const http = @import("http.zig");

pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// The host's own limit (coder/websocket read limit, ws's maxPayload).
pub const default_max_message = 100 * 1024 * 1024;

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const ConnectOptions = struct {
    /// Deadline for connect + upgrade handshake.
    timeout_ms: ?u32 = 10_000,
    /// Largest message accepted from the server.
    max_message: usize = default_max_message,
    headers: []const http.Header = &.{},
};

pub const HandshakeError = error{
    /// The server answered with something other than 101.
    UpgradeRejected,
    /// 101, but Sec-WebSocket-Accept did not match our key.
    BadAccept,
};

pub const ProtocolError = error{
    /// A frame violated RFC 6455 (masked server frame, reserved bits or
    /// opcodes, fragmented or oversized control frame, bad continuation).
    ProtocolViolation,
    /// A text message was not valid UTF-8.
    InvalidUtf8,
    /// A message exceeded `max_message`.
    MessageTooLarge,
    /// The connection was already closed (a close frame was received or
    /// sent and acknowledged).
    Closed,
};

pub const Error = http.Error || HandshakeError || ProtocolError;

pub const Message = union(enum) {
    /// UTF-8 text. Valid until the next `readMessage`.
    text: []const u8,
    /// Valid until the next `readMessage`.
    binary: []const u8,
    /// The server closed the connection (our reply has been sent). `code`
    /// is null when the close frame carried no status. Further reads fail
    /// with error.Closed.
    close: struct { code: ?u16, reason: []const u8 },
};

pub const WebSocket = struct {
    alloc: Allocator,
    io: std.Io,
    conn: Conn,
    max_message: usize,

    /// Reader-owned message assembly buffer.
    msg: std.ArrayList(u8) = .empty,
    /// Reader-owned control frame payload.
    ctrl: [125]u8 = undefined,
    recv_closed: bool = false,

    /// Serializes frame writes; guards `send_buf` and `sent_close`.
    send_mutex: std.Io.Mutex = .init,
    send_buf: []u8,
    sent_close: bool = false,

    /// Connect to `socket_path` and upgrade `target` (e.g.
    /// "/ws?session=<id>"). The result is heap-allocated so its address is
    /// stable for other threads; free it with `deinit`.
    pub fn connect(
        alloc: Allocator,
        io: std.Io,
        socket_path: []const u8,
        target: []const u8,
        opts: ConnectOptions,
    ) Error!*WebSocket {
        const deadline = Conn.deadlineIn(opts.timeout_ms);
        var conn = try Conn.connect(alloc, io, socket_path);
        errdefer conn.close();

        var key_raw: [16]u8 = undefined;
        io.random(&key_raw);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &key_raw);

        var headers_buf: [16]http.Header = undefined;
        if (opts.headers.len > headers_buf.len - 4) return error.OutOfMemory;
        headers_buf[0] = .{ .name = "Upgrade", .value = "websocket" };
        headers_buf[1] = .{ .name = "Sec-WebSocket-Version", .value = "13" };
        headers_buf[2] = .{ .name = "Sec-WebSocket-Key", .value = key };
        @memcpy(headers_buf[3..][0..opts.headers.len], opts.headers);
        const headers = headers_buf[0 .. 3 + opts.headers.len];

        // `Connection: Upgrade` replaces http's default "close".
        try writeUpgradeRequest(&conn, target, headers, deadline);
        var head = try http.readHead(alloc, &conn, deadline);
        defer head.deinit();
        if (head.status != 101 or
            !head.headerHasToken("upgrade", "websocket") or
            !head.headerHasToken("connection", "upgrade"))
            return error.UpgradeRejected;
        var expect_buf: [28]u8 = undefined;
        const expect = acceptKey(&expect_buf, key);
        const got = head.header("sec-websocket-accept") orelse return error.BadAccept;
        if (!std.mem.eql(u8, got, expect)) return error.BadAccept;

        const send_buf = try alloc.alloc(u8, 64 * 1024);
        errdefer alloc.free(send_buf);
        const self = try alloc.create(WebSocket);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .conn = conn,
            .max_message = opts.max_message,
            .send_buf = send_buf,
        };
        return self;
    }

    /// Close the socket (without a close handshake; call `close` first for
    /// a clean one) and free everything. Owner only, once no other thread
    /// uses the socket.
    pub fn deinit(self: *WebSocket) void {
        const alloc = self.alloc;
        self.conn.close();
        self.msg.deinit(alloc);
        alloc.free(self.send_buf);
        alloc.destroy(self);
    }

    /// Make a blocked `readMessage` or send return error.Interrupted.
    /// Thread-safe, idempotent, sends nothing.
    pub fn interrupt(self: *WebSocket) void {
        self.conn.interrupt();
    }

    /// Block until the next text/binary message or a close frame. Pings are
    /// answered and pongs ignored on the way.
    pub fn readMessage(self: *WebSocket) Error!Message {
        if (self.recv_closed) return error.Closed;
        self.msg.clearRetainingCapacity();
        var msg_op: ?Opcode = null;
        while (true) {
            var hdr: [2]u8 = undefined;
            try self.conn.readExact(&hdr, null);
            const fin = hdr[0] & 0x80 != 0;
            if (hdr[0] & 0x70 != 0) return error.ProtocolViolation; // RSV bits, no extensions
            const op: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(hdr[0]))));
            if (hdr[1] & 0x80 != 0) return error.ProtocolViolation; // server frames are unmasked
            var len: u64 = hdr[1] & 0x7f;
            if (len == 126) {
                var ext: [2]u8 = undefined;
                try self.conn.readExact(&ext, null);
                len = std.mem.readInt(u16, &ext, .big);
            } else if (len == 127) {
                var ext: [8]u8 = undefined;
                try self.conn.readExact(&ext, null);
                len = std.mem.readInt(u64, &ext, .big);
                if (len >> 63 != 0) return error.ProtocolViolation;
            }

            switch (op) {
                .ping, .pong, .close => {
                    if (!fin or len > 125) return error.ProtocolViolation;
                    const payload = self.ctrl[0..@intCast(len)];
                    try self.conn.readExact(payload, null);
                    switch (op) {
                        .ping => self.writeFrame(.pong, payload) catch |err| switch (err) {
                            error.Closed => {},
                            else => |e| return e,
                        },
                        .pong => {},
                        .close => {
                            self.recv_closed = true;
                            var code: ?u16 = null;
                            var reason: []const u8 = "";
                            if (payload.len >= 2) {
                                code = std.mem.readInt(u16, payload[0..2], .big);
                                reason = payload[2..];
                            } else if (payload.len == 1) return error.ProtocolViolation;
                            // Echo the status back, as RFC 6455 §5.5.1 asks.
                            self.writeFrame(.close, payload[0..@min(payload.len, 2)]) catch {};
                            return .{ .close = .{ .code = code, .reason = reason } };
                        },
                        else => unreachable,
                    }
                },
                .text, .binary, .continuation => {
                    if (op == .continuation) {
                        if (msg_op == null) return error.ProtocolViolation;
                    } else {
                        if (msg_op != null) return error.ProtocolViolation;
                        msg_op = op;
                    }
                    if (self.msg.items.len + len > self.max_message) return error.MessageTooLarge;
                    const start = self.msg.items.len;
                    try self.msg.resize(self.alloc, start + @as(usize, @intCast(len)));
                    try self.conn.readExact(self.msg.items[start..], null);
                    if (fin) {
                        const data = self.msg.items;
                        if (msg_op.? == .text) {
                            if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
                            return .{ .text = data };
                        }
                        return .{ .binary = data };
                    }
                },
                else => return error.ProtocolViolation,
            }
        }
    }

    /// Send one text message (must be UTF-8). Thread-safe.
    pub fn sendText(self: *WebSocket, data: []const u8) Error!void {
        return self.writeFrame(.text, data);
    }

    /// Send one binary message. Thread-safe.
    pub fn sendBinary(self: *WebSocket, data: []const u8) Error!void {
        return self.writeFrame(.binary, data);
    }

    /// Send a ping (payload at most 125 bytes). Thread-safe.
    pub fn ping(self: *WebSocket, payload: []const u8) Error!void {
        if (payload.len > 125) return error.ProtocolViolation;
        return self.writeFrame(.ping, payload);
    }

    /// Start the close handshake (status `code`, optional short reason).
    /// The reader sees the server's reply as `.close`. Thread-safe.
    pub fn close(self: *WebSocket, code: u16, reason: []const u8) Error!void {
        var buf: [125]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        const r = reason[0..@min(reason.len, buf.len - 2)];
        @memcpy(buf[2..][0..r.len], r);
        return self.writeFrame(.close, buf[0 .. 2 + r.len]);
    }

    /// Write one complete (unfragmented) masked frame.
    fn writeFrame(self: *WebSocket, op: Opcode, payload: []const u8) Error!void {
        self.send_mutex.lockUncancelable(self.io);
        defer self.send_mutex.unlock(self.io);
        if (self.sent_close) return error.Closed;
        if (op == .close) self.sent_close = true;

        var hdr: [14]u8 = undefined;
        hdr[0] = 0x80 | @as(u8, @backingInt(op));
        var n: usize = 2;
        if (payload.len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            hdr[1] = 0x80 | 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            n = 4;
        } else {
            hdr[1] = 0x80 | 127;
            std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
            n = 10;
        }
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        @memcpy(hdr[n..][0..4], &mask);
        n += 4;

        // The header goes out with the first payload chunk.
        const buf = self.send_buf;
        @memcpy(buf[0..n], hdr[0..n]);
        var fill: usize = n;
        var off: usize = 0;
        while (true) {
            const take = @min(payload.len - off, buf.len - fill);
            for (payload[off..][0..take], buf[fill..][0..take], off..) |p, *d, i| d.* = p ^ mask[i & 3];
            off += take;
            fill += take;
            try self.conn.writeAll(buf[0..fill], null);
            fill = 0;
            if (off == payload.len) break;
        }
    }
};

fn writeUpgradeRequest(conn: *Conn, target: []const u8, headers: []const http.Header, deadline: Conn.Deadline) Error!void {
    var aw: std.Io.Writer.Allocating = .init(conn.alloc);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n", .{target}) catch return error.OutOfMemory;
    for (headers) |h| w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.OutOfMemory;
    w.writeAll("\r\n") catch return error.OutOfMemory;
    try conn.writeAll(aw.written(), deadline);
}

/// Sec-WebSocket-Accept for a key: base64(sha1(key ++ guid)).
pub fn acceptKey(out: *[28]u8, key: []const u8) []const u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

test "acceptKey matches RFC 6455 example" {
    var buf: [28]u8 = undefined;
    try std.testing.expectEqualStrings(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        acceptKey(&buf, "dGhlIHNhbXBsZSBub25jZQ=="),
    );
}
