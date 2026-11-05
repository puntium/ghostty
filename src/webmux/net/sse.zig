//! Server-sent events reader (the host's `GET /api/fs/watch`: `ready`,
//! `change` and `gone` events, a `: ping` comment every 25 s).
//!
//! `Parser` is the pure line-level state machine (WHATWG "event stream
//! interpretation"); `Reader` runs it over an HTTP `Stream`. Comments count
//! as activity for the idle timeout but are not returned.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");

pub const Event = struct {
    /// "message" when the event had no `event:` field.
    event: []const u8,
    /// `data:` lines joined with "\n".
    data: []const u8,
    /// Last `id:` seen on the stream (persists across events, per spec).
    id: ?[]const u8,
};

pub const Parser = struct {
    alloc: Allocator,
    event: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    has_data: bool = false,
    last_id: std.ArrayList(u8) = .empty,
    has_id: bool = false,
    /// Reconnection time requested by the server (`retry:`), in ms.
    retry_ms: ?u32 = null,
    /// Data returned by the last dispatched event; kept until the next line.
    out_event: std.ArrayList(u8) = .empty,
    out_data: std.ArrayList(u8) = .empty,

    pub fn init(alloc: Allocator) Parser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Parser) void {
        self.event.deinit(self.alloc);
        self.data.deinit(self.alloc);
        self.last_id.deinit(self.alloc);
        self.out_event.deinit(self.alloc);
        self.out_data.deinit(self.alloc);
    }

    /// Feed one line (without its line terminator). Returns an event when
    /// the line completes one; its slices are valid until the next call.
    pub fn line(self: *Parser, l: []const u8) Allocator.Error!?Event {
        if (l.len == 0) return self.dispatch();
        if (l[0] == ':') return null; // comment
        const colon = std.mem.indexOfScalar(u8, l, ':');
        const field = if (colon) |c| l[0..c] else l;
        var value: []const u8 = if (colon) |c| l[c + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            self.event.clearRetainingCapacity();
            try self.event.appendSlice(self.alloc, value);
        } else if (std.mem.eql(u8, field, "data")) {
            if (self.has_data) try self.data.append(self.alloc, '\n');
            try self.data.appendSlice(self.alloc, value);
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                self.last_id.clearRetainingCapacity();
                try self.last_id.appendSlice(self.alloc, value);
                self.has_id = true;
            }
        } else if (std.mem.eql(u8, field, "retry")) {
            self.retry_ms = std.fmt.parseInt(u32, value, 10) catch self.retry_ms;
        }
        return null;
    }

    fn dispatch(self: *Parser) Allocator.Error!?Event {
        defer {
            self.event.clearRetainingCapacity();
            self.data.clearRetainingCapacity();
            self.has_data = false;
        }
        if (!self.has_data) return null;
        self.out_event.clearRetainingCapacity();
        try self.out_event.appendSlice(self.alloc, if (self.event.items.len > 0) self.event.items else "message");
        self.out_data.clearRetainingCapacity();
        try self.out_data.appendSlice(self.alloc, self.data.items);
        return .{
            .event = self.out_event.items,
            .data = self.out_data.items,
            .id = if (self.has_id) self.last_id.items else null,
        };
    }
};

pub const OpenOptions = struct {
    /// Deadline for connect + response head.
    timeout_ms: ?u32 = 10_000,
    /// Fail with error.Timeout when nothing (not even a comment) arrives
    /// for this long. The host sends a comment every 25 s.
    idle_timeout_ms: ?u32 = 60_000,
    headers: []const http.Header = &.{},
};

pub const Error = http.Error || error{
    /// The server answered with a non-200 status or not text/event-stream.
    BadResponse,
};

/// An open event stream. Heap-allocated (stable address for `interrupt`).
pub const Reader = struct {
    alloc: Allocator,
    stream: *http.Stream,
    parser: Parser,
    lines: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    eof: bool = false,

    /// GET `target` with `Accept: text/event-stream`. Fails with BadResponse
    /// unless the server answers 200 text/event-stream.
    pub fn open(client: *const http.Client, alloc: Allocator, target: []const u8, opts: OpenOptions) Error!*Reader {
        var hdrs: [8]http.Header = undefined;
        if (opts.headers.len > hdrs.len - 2) return error.OutOfMemory;
        hdrs[0] = .{ .name = "Accept", .value = "text/event-stream" };
        hdrs[1] = .{ .name = "Cache-Control", .value = "no-cache" };
        @memcpy(hdrs[2..][0..opts.headers.len], opts.headers);
        const stream = try client.open(alloc, .{
            .target = target,
            .headers = hdrs[0 .. 2 + opts.headers.len],
            .timeout_ms = opts.timeout_ms,
            .idle_timeout_ms = opts.idle_timeout_ms,
        });
        errdefer stream.close();
        const ct = stream.head.header("content-type") orelse "";
        if (stream.head.status != 200 or !std.mem.startsWith(u8, ct, "text/event-stream"))
            return error.BadResponse;
        const self = try alloc.create(Reader);
        self.* = .{ .alloc = alloc, .stream = stream, .parser = .init(alloc) };
        return self;
    }

    pub fn close(self: *Reader) void {
        self.stream.close();
        self.parser.deinit();
        self.lines.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Make a blocked `next` return error.Interrupted. Thread-safe.
    pub fn interrupt(self: *Reader) void {
        self.stream.interrupt();
    }

    /// The next event, or null when the server ended the stream. Slices
    /// are valid until the next call.
    pub fn next(self: *Reader) Error!?Event {
        while (true) {
            // Process complete lines already buffered.
            while (self.nextLine()) |l| {
                if (try self.parser.line(l)) |ev| return ev;
            }
            if (self.eof) {
                // Unterminated last line, then end of stream (the spec
                // discards an incomplete event at EOF).
                return null;
            }
            // Compact and read more.
            if (self.pos > 0) {
                const rest = self.lines.items.len - self.pos;
                std.mem.copyForwards(u8, self.lines.items[0..rest], self.lines.items[self.pos..]);
                self.lines.shrinkRetainingCapacity(rest);
                self.pos = 0;
            }
            if (self.lines.items.len > 16 * 1024 * 1024) return error.LineTooLong;
            try self.lines.ensureUnusedCapacity(self.alloc, 8192);
            const dest = self.lines.unusedCapacitySlice();
            const n = try self.stream.read(dest);
            if (n == 0) {
                self.eof = true;
            } else {
                self.lines.items.len += n;
            }
        }
    }

    fn nextLine(self: *Reader) ?[]const u8 {
        const buf = self.lines.items[self.pos..];
        // Lines end in "\n", "\r\n" or a lone "\r".
        for (buf, 0..) |c, i| {
            if (c == '\n') {
                self.pos += i + 1;
                return buf[0..i];
            }
            if (c == '\r') {
                if (i + 1 < buf.len) {
                    self.pos += i + 1 + @intFromBool(buf[i + 1] == '\n');
                    return buf[0..i];
                }
                if (self.eof) {
                    self.pos += i + 1;
                    return buf[0..i];
                }
                return null; // need the next byte to know if "\n" follows
            }
        }
        return null;
    }
};

test "Parser: events, comments, multi-line data, id, default event name" {
    const t = std.testing;
    var p: Parser = .init(t.allocator);
    defer p.deinit();
    try t.expect(try p.line(": ping") == null);
    try t.expect(try p.line("event: ready") == null);
    try t.expect(try p.line("data: {\"path\":\"/x\"}") == null);
    const ev = (try p.line("")).?;
    try t.expectEqualStrings("ready", ev.event);
    try t.expectEqualStrings("{\"path\":\"/x\"}", ev.data);
    try t.expect(ev.id == null);

    try t.expect(try p.line("id: 7") == null);
    try t.expect(try p.line("data:a") == null);
    try t.expect(try p.line("data: b") == null);
    const ev2 = (try p.line("")).?;
    try t.expectEqualStrings("message", ev2.event);
    try t.expectEqualStrings("a\nb", ev2.data);
    try t.expectEqualStrings("7", ev2.id.?);

    // An event with no data is not dispatched.
    try t.expect(try p.line("event: nothing") == null);
    try t.expect(try p.line("") == null);
    try t.expect(try p.line("retry: 1500") == null);
    try t.expectEqual(@as(?u32, 1500), p.retry_ms);
}
