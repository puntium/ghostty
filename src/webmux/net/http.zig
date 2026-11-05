//! HTTP/1.1 client over a unix stream socket (the webmux host's HTTP server,
//! reached directly or through the ssh tunnel's local socket). No TCP, no
//! TLS, no auth, one connection per request (`Connection: close`).
//!
//! Three ways to make a request:
//!   - `Client.fetch`: buffer the whole response body (JSON API calls).
//!   - `Client.download`: stream the body into a `*std.Io.Writer`; the body
//!     is never held in memory whole.
//!   - `Client.open`: read the response head, then pull the body
//!     incrementally with `Stream.read` (SSE, custom streaming). Another
//!     thread can make a blocked `Stream.read` return with `interrupt()`.
//!
//! Request bodies are a byte slice or a `*std.Io.Reader` (streamed; sent
//! with Content-Length when the length is known, chunked otherwise).
//!
//! Timeouts: `timeout_ms` is one deadline covering connect, sending the
//! request and receiving the response head; for `fetch` it also covers the
//! body. Streamed bodies (`download`, `open`) use `idle_timeout_ms`, a limit
//! on each wait for more body bytes (null: wait indefinitely).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Conn = @import("Conn.zig");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Body = union(enum) {
    none,
    bytes: []const u8,
    /// Streamed from a reader until it ends. With `length` set, exactly that
    /// many bytes are sent (Content-Length); otherwise chunked encoding.
    reader: struct {
        reader: *std.Io.Reader,
        length: ?u64 = null,
    },
};

pub const Options = struct {
    method: Method = .GET,
    /// Request target: path plus query, e.g. "/api/fs/list?path=%7E".
    target: []const u8,
    headers: []const Header = &.{},
    /// Sets Content-Type when there is a body.
    content_type: ?[]const u8 = null,
    body: Body = .none,
    /// Deadline for connect + request + response head (and the body, for
    /// `fetch`). Null: no limit.
    timeout_ms: ?u32 = 30_000,
    /// For streamed bodies: limit on each wait for more bytes. Null: none.
    idle_timeout_ms: ?u32 = null,
    /// `fetch` only: refuse bodies larger than this.
    max_body: usize = 64 * 1024 * 1024,
};

pub const Error = Conn.ConnectError || Conn.Error || error{
    /// The response was not valid HTTP/1.x.
    InvalidResponse,
    /// The response head exceeded 64 KiB.
    HeadTooLarge,
    /// `fetch`: the body exceeded `max_body`.
    BodyTooLarge,
    /// The request body reader failed.
    ReadFailed,
    /// The destination writer failed (`download`).
    WriteFailed,
    /// A request body reader produced a different number of bytes than the
    /// declared length.
    BodyLengthMismatch,
};

const max_head = 64 * 1024;

/// A parsed response head. Owns its memory.
pub const Head = struct {
    alloc: Allocator,
    status: u16,
    reason: []const u8,
    headers: []Header,
    raw: []u8,

    pub fn deinit(self: *Head) void {
        self.alloc.free(self.headers);
        self.alloc.free(self.raw);
        self.* = undefined;
    }

    /// First header with this name (case-insensitive).
    pub fn header(self: *const Head, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Whether a comma-separated header contains `token` (case-insensitive).
    pub fn headerHasToken(self: *const Head, name: []const u8, token: []const u8) bool {
        for (self.headers) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, name)) continue;
            var it = std.mem.splitScalar(u8, h.value, ',');
            while (it.next()) |part| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
            }
        }
        return false;
    }
};

/// A fully buffered response.
pub const Response = struct {
    head: Head,
    body: []u8,

    pub fn deinit(self: *Response) void {
        const alloc = self.head.alloc;
        alloc.free(self.body);
        self.head.deinit();
        self.* = undefined;
    }

    pub fn status(self: *const Response) u16 {
        return self.head.status;
    }

    pub fn ok(self: *const Response) bool {
        return self.head.status >= 200 and self.head.status < 300;
    }

    /// Parse the body as JSON into T. Free with `parsed.deinit()`.
    pub fn json(self: *const Response, comptime T: type, alloc: Allocator) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, alloc, self.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

/// A response whose body is read incrementally. Heap-allocated so its
/// address is stable for `interrupt` from another thread.
pub const Stream = struct {
    alloc: Allocator,
    conn: Conn,
    head: Head,
    body: BodyReader,
    idle_timeout_ms: ?u32,

    /// Read up to `out.len` body bytes; 0 at the end of the body.
    pub fn read(self: *Stream, out: []u8) Error!usize {
        return self.body.read(&self.conn, out, Conn.deadlineIn(self.idle_timeout_ms));
    }

    /// Read the rest of the body into `w`. Returns the byte count.
    pub fn streamTo(self: *Stream, w: *std.Io.Writer) Error!u64 {
        var buf: [32 * 1024]u8 = undefined;
        var total: u64 = 0;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) break;
            w.writeAll(buf[0..n]) catch return error.WriteFailed;
            total += n;
        }
        w.flush() catch return error.WriteFailed;
        return total;
    }

    /// Make a blocked `read` (on another thread) return error.Interrupted.
    pub fn interrupt(self: *Stream) void {
        self.conn.interrupt();
    }

    /// Close the connection and free everything. Call once, from the
    /// thread that owns the stream, after other threads are done with it.
    pub fn close(self: *Stream) void {
        self.conn.close();
        self.head.deinit();
        self.alloc.destroy(self);
    }
};

/// Body framing state.
pub const BodyReader = struct {
    mode: union(enum) {
        none,
        length: u64,
        /// `crlf_pending`: the CRLF after a chunk's data is still unread. Each
        /// step consumes whole lines, so a timeout never loses framing state.
        chunked: struct { left: u64 = 0, done: bool = false, crlf_pending: bool = false },
        eof,
    },

    pub fn read(self: *BodyReader, conn: *Conn, out: []u8, deadline: Conn.Deadline) Error!usize {
        if (out.len == 0) return 0;
        switch (self.mode) {
            .none => return 0,
            .length => |*left| {
                if (left.* == 0) return 0;
                const want: usize = @intCast(@min(left.*, out.len));
                const n = try conn.readSome(out[0..want], deadline);
                if (n == 0) return error.EndOfStream;
                left.* -= n;
                return n;
            },
            .eof => return conn.readSome(out, deadline),
            .chunked => |*c| {
                while (c.left == 0) {
                    if (c.done) return 0;
                    // CRLF after the previous chunk's data.
                    if (c.crlf_pending) {
                        const crlf = try conn.readLine(16, deadline) orelse return error.EndOfStream;
                        if (crlf.len != 0) return error.InvalidResponse;
                        c.crlf_pending = false;
                    }
                    const line = try conn.readLine(1024, deadline) orelse return error.EndOfStream;
                    const size_str = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len], " \t");
                    const size = std.fmt.parseInt(u64, size_str, 16) catch return error.InvalidResponse;
                    if (size == 0) {
                        // Trailers, up to the empty line.
                        while (true) {
                            const t = try conn.readLine(8192, deadline) orelse break;
                            if (t.len == 0) break;
                        }
                        c.done = true;
                        return 0;
                    }
                    c.left = size;
                }
                const want: usize = @intCast(@min(c.left, out.len));
                const n = try conn.readSome(out[0..want], deadline);
                if (n == 0) return error.EndOfStream;
                c.left -= n;
                if (c.left == 0) c.crlf_pending = true;
                return n;
            },
        }
    }
};

pub const Client = struct {
    alloc: Allocator,
    io: std.Io,
    socket_path: []u8,

    pub fn init(alloc: Allocator, io: std.Io, socket_path: []const u8) Allocator.Error!Client {
        return .{ .alloc = alloc, .io = io, .socket_path = try alloc.dupe(u8, socket_path) };
    }

    pub fn deinit(self: *Client) void {
        self.alloc.free(self.socket_path);
        self.* = undefined;
    }

    /// Make a request and buffer the whole response body. `alloc` owns the
    /// returned response.
    pub fn fetch(self: *const Client, alloc: Allocator, opts: Options) Error!Response {
        const deadline = Conn.deadlineIn(opts.timeout_ms);
        var conn = try Conn.connect(alloc, self.io, self.socket_path);
        defer conn.close();
        try sendRequest(&conn, opts, deadline);
        var head = try readHead(alloc, &conn, deadline);
        errdefer head.deinit();
        var body_reader = bodyFraming(opts.method, &head);

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(alloc);
        if (body_reader.mode == .length) {
            if (body_reader.mode.length > opts.max_body) return error.BodyTooLarge;
            try body.ensureTotalCapacity(alloc, @intCast(body_reader.mode.length));
        }
        var buf: [32 * 1024]u8 = undefined;
        while (true) {
            const n = try body_reader.read(&conn, &buf, deadline);
            if (n == 0) break;
            if (body.items.len + n > opts.max_body) return error.BodyTooLarge;
            try body.appendSlice(alloc, buf[0..n]);
        }
        return .{ .head = head, .body = try body.toOwnedSlice(alloc) };
    }

    /// Make a request and stream the response body into `w` (whatever the
    /// status; check `head.status`). Returns the head; free it with deinit.
    pub fn download(self: *const Client, alloc: Allocator, opts: Options, w: *std.Io.Writer) Error!Head {
        const s = try self.open(alloc, opts);
        _ = s.streamTo(w) catch |err| {
            s.close();
            return err;
        };
        const head = s.head;
        s.conn.close();
        alloc.destroy(s);
        return head;
    }

    /// Make a request, read the response head, and return a stream for the
    /// body. Close it with `Stream.close`.
    pub fn open(self: *const Client, alloc: Allocator, opts: Options) Error!*Stream {
        const deadline = Conn.deadlineIn(opts.timeout_ms);
        const s = try alloc.create(Stream);
        errdefer alloc.destroy(s);
        s.alloc = alloc;
        s.idle_timeout_ms = opts.idle_timeout_ms;
        s.conn = try Conn.connect(alloc, self.io, self.socket_path);
        errdefer s.conn.close();
        try sendRequest(&s.conn, opts, deadline);
        s.head = try readHead(alloc, &s.conn, deadline);
        s.body = bodyFraming(opts.method, &s.head);
        return s;
    }
};

fn bodyFraming(method: Method, head: *const Head) BodyReader {
    if (method == .HEAD or head.status == 204 or head.status == 304 or
        (head.status >= 100 and head.status < 200))
        return .{ .mode = .none };
    if (head.headerHasToken("transfer-encoding", "chunked")) return .{ .mode = .{ .chunked = .{} } };
    if (head.header("content-length")) |v| {
        const n = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch return .{ .mode = .eof };
        return .{ .mode = .{ .length = n } };
    }
    return .{ .mode = .eof };
}

/// Write the request line, headers and body.
pub fn sendRequest(conn: *Conn, opts: Options, deadline: Conn.Deadline) Error!void {
    var hbuf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hbuf);
    var extra: ?[]u8 = null;
    defer if (extra) |e| conn.alloc.free(e);
    writeHead(&w, opts) catch {
        // Unusually large headers: build them on the heap instead.
        var aw: std.Io.Writer.Allocating = .init(conn.alloc);
        defer aw.deinit();
        writeHead(&aw.writer, opts) catch return error.OutOfMemory;
        extra = aw.toOwnedSlice() catch return error.OutOfMemory;
    };
    try conn.writeAll(extra orelse w.buffered(), deadline);

    switch (opts.body) {
        .none => {},
        .bytes => |b| try conn.writeAll(b, deadline),
        .reader => |r| {
            var buf: [64 * 1024]u8 = undefined;
            var sent: u64 = 0;
            while (true) {
                var want: usize = buf.len;
                if (r.length) |len| want = @intCast(@min(@as(u64, buf.len), len - sent));
                if (want == 0) break;
                const n = r.reader.readSliceShort(buf[0..want]) catch return error.ReadFailed;
                if (n == 0) break;
                if (r.length == null) {
                    var cbuf: [32]u8 = undefined;
                    const pre = std.fmt.bufPrint(&cbuf, "{x}\r\n", .{n}) catch unreachable;
                    try conn.writeAll(pre, deadline);
                    try conn.writeAll(buf[0..n], deadline);
                    try conn.writeAll("\r\n", deadline);
                } else {
                    try conn.writeAll(buf[0..n], deadline);
                }
                sent += n;
            }
            if (r.length) |len| {
                if (sent != len) return error.BodyLengthMismatch;
            } else try conn.writeAll("0\r\n\r\n", deadline);
        },
    }
}

fn writeHead(w: *std.Io.Writer, opts: Options) std.Io.Writer.Error!void {
    try w.print("{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n", .{ @tagName(opts.method), opts.target });
    for (opts.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    switch (opts.body) {
        .none => if (opts.method == .POST or opts.method == .PUT or opts.method == .PATCH)
            try w.writeAll("Content-Length: 0\r\n"),
        .bytes => |b| try w.print("Content-Length: {d}\r\n", .{b.len}),
        .reader => |r| if (r.length) |len|
            try w.print("Content-Length: {d}\r\n", .{len})
        else
            try w.writeAll("Transfer-Encoding: chunked\r\n"),
    }
    if (opts.body != .none) {
        if (opts.content_type) |ct| try w.print("Content-Type: {s}\r\n", .{ct});
    }
    try w.writeAll("\r\n");
}

/// Read and parse a response head ("HTTP/1.1 200 OK" + headers + blank
/// line). Leaves any following bytes buffered in `conn`.
pub fn readHead(alloc: Allocator, conn: *Conn, deadline: Conn.Deadline) Error!Head {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(alloc);
    // Line starts within `raw`, so header slices can be made afterwards.
    var lines: std.ArrayList([2]usize) = .empty;
    defer lines.deinit(alloc);

    while (true) {
        const line = conn.readLine(max_head, deadline) catch |err| switch (err) {
            error.LineTooLong => return error.HeadTooLarge,
            else => |e| return e,
        } orelse return error.EndOfStream;
        if (line.len == 0) {
            if (lines.items.len == 0) continue; // tolerate a leading blank line
            break;
        }
        if (raw.items.len + line.len > max_head) return error.HeadTooLarge;
        try lines.append(alloc, .{ raw.items.len, line.len });
        try raw.appendSlice(alloc, line);
    }

    const owned = try raw.toOwnedSlice(alloc);
    errdefer alloc.free(owned);

    const status_line = owned[lines.items[0][0]..][0..lines.items[0][1]];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.InvalidResponse;
    var it = std.mem.splitScalar(u8, status_line, ' ');
    _ = it.next();
    const code_str = it.next() orelse return error.InvalidResponse;
    const status = std.fmt.parseInt(u16, code_str, 10) catch return error.InvalidResponse;
    const reason = it.rest();

    const headers = try alloc.alloc(Header, lines.items.len - 1);
    errdefer alloc.free(headers);
    for (lines.items[1..], headers) |l, *h| {
        const text = owned[l[0]..][0..l[1]];
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidResponse;
        h.* = .{
            .name = std.mem.trim(u8, text[0..colon], " \t"),
            .value = std.mem.trim(u8, text[colon + 1 ..], " \t"),
        };
    }
    return .{ .alloc = alloc, .status = status, .reason = reason, .headers = headers, .raw = owned };
}

/// Percent-encode `s` for use as one path segment or query value
/// (everything but unreserved characters is escaped).
pub fn percentEncode(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

pub fn percentEncodeAlloc(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    percentEncode(&aw.writer, s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

test "percentEncode" {
    const s = try percentEncodeAlloc(std.testing.allocator, "a b/~é?");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a%20b%2F~%C3%A9%3F", s);
}
