//! The session WebSocket's JSON frames (`/ws?session=<id>`), as the host
//! sends and expects them. Wire reference: host/internal/ptyhost/session.go
//! (snapshot/output/title/exit), ptyhost.go (error), server/ws.go
//! (input/resize/paste-image/clipboard-sync handling), server/paste.go
//! (paste-result, open-url), README.md › Protocol.
//!
//! Server → client:
//!   {"type":"snapshot","data":S,"cols":N,"rows":N,"title":S,"pid":N}
//!   {"type":"output","data":S}
//!   {"type":"title","title":S}
//!   {"type":"session-title","session":S,"title":S}
//!   {"type":"exit","exitCode":N}
//!   {"type":"error","message":S}          (no such session)
//!   {"type":"paste-result","mode":"claude"|"path","path"?:S}
//!   {"type":"open-url","url":S,"id":S}
//! Client → server:
//!   {"type":"input","data":S}
//!   {"type":"resize","cols":N,"rows":N}   (integers; host clamps 2..500 × 2..300)
//!   {"type":"paste-image","mime":S,"data":base64}
//!   {"type":"clipboard-sync","mime":S,"data":base64}
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const Snapshot = struct {
    /// VT stream that recreates the session's screen and scrollback when fed
    /// to a freshly reset terminal of size cols × rows.
    data: []const u8,
    cols: u16,
    rows: u16,
    title: []const u8,
    /// Shell pid on the host (0 or null when unknown).
    pid: ?i64,
};

pub const ServerFrame = union(enum) {
    snapshot: Snapshot,
    output: []const u8,
    title: []const u8,
    session_title: struct { session: []const u8, title: []const u8 },
    exit: struct { code: i64 },
    @"error": struct { message: []const u8 },
    paste_result: struct { mode: []const u8, path: ?[]const u8 },
    open_url: struct { url: []const u8, id: []const u8 },
    /// A frame type this client does not know (ignored by the backend).
    unknown: []const u8,
};

pub const ParseError = error{ InvalidFrame, OutOfMemory };

/// Parse one server message. Strings are allocated in (or borrowed from)
/// `arena`'s lifetime and `text`; use an arena that is reset per message.
pub fn parseServerFrame(arena: Allocator, text: []const u8) ParseError!ServerFrame {
    const v = json.parseFromSliceLeaky(json.Value, arena, text, .{
        .allocate = .alloc_if_needed,
        .max_value_len = std.math.maxInt(usize),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFrame,
    };
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidFrame,
    };
    const typ = str(obj, "type") orelse return error.InvalidFrame;

    if (eql(typ, "output")) return .{ .output = str(obj, "data") orelse "" };
    if (eql(typ, "snapshot")) return .{ .snapshot = .{
        .data = str(obj, "data") orelse "",
        .cols = dim(obj, "cols"),
        .rows = dim(obj, "rows"),
        .title = str(obj, "title") orelse "",
        .pid = int(obj, "pid"),
    } };
    if (eql(typ, "title")) return .{ .title = str(obj, "title") orelse "" };
    if (eql(typ, "session-title")) return .{ .session_title = .{
        .session = str(obj, "session") orelse "",
        .title = str(obj, "title") orelse "",
    } };
    if (eql(typ, "exit")) return .{ .exit = .{ .code = int(obj, "exitCode") orelse 0 } };
    if (eql(typ, "error")) return .{
        .@"error" = .{
            // The Electron client reads `msg.error || msg.message`.
            .message = str(obj, "error") orelse str(obj, "message") orelse "",
        },
    };
    if (eql(typ, "paste-result")) return .{ .paste_result = .{
        .mode = str(obj, "mode") orelse "",
        .path = str(obj, "path"),
    } };
    if (eql(typ, "open-url")) return .{ .open_url = .{
        .url = str(obj, "url") orelse "",
        .id = str(obj, "id") orelse "",
    } };
    return .{ .unknown = typ };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn str(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn int(obj: json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(std.math.clamp(@trunc(f), -9e15, 9e15)) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// A grid dimension: 0 when missing or out of range.
fn dim(obj: json.ObjectMap, key: []const u8) u16 {
    const v = int(obj, key) orelse return 0;
    return if (v > 0 and v <= std.math.maxInt(u16)) @intCast(v) else 0;
}

pub const ClientFrame = union(enum) {
    /// Bytes for the pty. Encoded as a JSON string; bytes that are not
    /// valid UTF-8 become U+FFFD (see `writeJsonString`).
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    /// `data` is base64.
    paste_image: struct { mime: []const u8, data: []const u8 },
    /// `data` is base64.
    clipboard_sync: struct { mime: []const u8, data: []const u8 },
};

/// Encode a client frame as compact JSON.
pub fn writeClientFrame(w: *std.Io.Writer, frame: ClientFrame) std.Io.Writer.Error!void {
    switch (frame) {
        .input => |data| {
            try w.writeAll("{\"type\":\"input\",\"data\":");
            try writeJsonString(w, data);
            try w.writeAll("}");
        },
        .resize => |r| try w.print("{{\"type\":\"resize\",\"cols\":{d},\"rows\":{d}}}", .{ r.cols, r.rows }),
        .paste_image => |p| try writeImageFrame(w, "paste-image", p.mime, p.data),
        .clipboard_sync => |p| try writeImageFrame(w, "clipboard-sync", p.mime, p.data),
    }
}

fn writeImageFrame(w: *std.Io.Writer, typ: []const u8, mime: []const u8, data: []const u8) std.Io.Writer.Error!void {
    try w.print("{{\"type\":\"{s}\",\"mime\":", .{typ});
    try writeJsonString(w, mime);
    try w.writeAll(",\"data\":");
    try writeJsonString(w, data);
    try w.writeAll("}");
}

pub fn encodeClientFrameAlloc(alloc: Allocator, frame: ClientFrame) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    writeClientFrame(&aw.writer, frame) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Write `bytes` as a JSON string literal. Valid UTF-8 passes through
/// (with the mandatory escapes); each maximal invalid subsequence becomes
/// U+FFFD, the same substitution the host's decodeUTF8 makes, so the host
/// receives exactly what it would have produced itself.
pub fn writeJsonString(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    var run: usize = 0; // start of the pending run of plain bytes
    while (i < bytes.len) {
        const c = bytes[i];
        if (c >= 0x20 and c < 0x80 and c != '"' and c != '\\') {
            i += 1;
            continue;
        }
        if (c < 0x80) {
            try w.writeAll(bytes[run..i]);
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                else => try w.print("\\u{x:0>4}", .{c}),
            }
            i += 1;
            run = i;
            continue;
        }
        const n = validSequenceLen(bytes[i..]);
        if (n > 0) {
            i += n;
            continue;
        }
        try w.writeAll(bytes[run..i]);
        try w.writeAll("\u{FFFD}");
        i += invalidSkip(bytes[i..]);
        run = i;
    }
    try w.writeAll(bytes[run..]);
    try w.writeByte('"');
}

/// Lead byte → (continuation count, bounds of the first continuation byte).
fn leadInfo(c: u8) ?struct { need: u8, lo: u8, hi: u8 } {
    return switch (c) {
        0xC2...0xDF => .{ .need = 1, .lo = 0x80, .hi = 0xBF },
        0xE0 => .{ .need = 2, .lo = 0xA0, .hi = 0xBF },
        0xE1...0xEC, 0xEE...0xEF => .{ .need = 2, .lo = 0x80, .hi = 0xBF },
        0xED => .{ .need = 2, .lo = 0x80, .hi = 0x9F },
        0xF0 => .{ .need = 3, .lo = 0x90, .hi = 0xBF },
        0xF1...0xF3 => .{ .need = 3, .lo = 0x80, .hi = 0xBF },
        0xF4 => .{ .need = 3, .lo = 0x80, .hi = 0x8F },
        else => null,
    };
}

/// Length of the valid multi-byte sequence at the start of `b`, or 0.
fn validSequenceLen(b: []const u8) usize {
    const info = leadInfo(b[0]) orelse return 0;
    if (b.len < 1 + info.need) return 0;
    if (b[1] < info.lo or b[1] > info.hi) return 0;
    for (b[2 .. 1 + info.need]) |x| if (x < 0x80 or x > 0xBF) return 0;
    return 1 + info.need;
}

/// Bytes covered by one U+FFFD (the maximal subpart), at least 1.
fn invalidSkip(b: []const u8) usize {
    const info = leadInfo(b[0]) orelse return 1;
    var j: usize = 1;
    var lo = info.lo;
    var hi = info.hi;
    var k: u8 = 0;
    while (k < info.need) : (k += 1) {
        if (j >= b.len or b[j] < lo or b[j] > hi) break;
        lo = 0x80;
        hi = 0xBF;
        j += 1;
    }
    return j;
}

test "writeJsonString: escapes and invalid UTF-8" {
    const t = std.testing;
    const cases = [_][2][]const u8{
        .{ "abc", "\"abc\"" },
        .{ "\x1b[A\r", "\"\\u001b[A\\r\"" },
        .{ "q\"\\", "\"q\\\"\\\\\"" },
        .{ "é€😀", "\"é€😀\"" },
        .{ "a\xffb", "\"a\u{FFFD}b\"" },
        // Truncated 3-byte sequence then ASCII: one U+FFFD (maximal subpart).
        .{ "\xe2\x82x", "\"\u{FFFD}x\"" },
        // Surrogate (ED A0 80): ED is a valid lead but A0 is out of its range.
        .{ "\xed\xa0\x80", "\"\u{FFFD}\u{FFFD}\u{FFFD}\"" },
        .{ "\xc3", "\"\u{FFFD}\"" },
        .{ "\x7f", "\"\x7f\"" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeJsonString(&w, c[0]);
        try t.expectEqualStrings(c[1], w.buffered());
        // Always valid JSON that decodes to valid UTF-8.
        const s = try json.parseFromSlice([]const u8, t.allocator, w.buffered(), .{});
        defer s.deinit();
        try t.expect(std.unicode.utf8ValidateSlice(s.value));
    }
}

test "client frames encode as the host expects" {
    const t = std.testing;
    const a = t.allocator;
    const cases = [_]struct { ClientFrame, []const u8 }{
        .{ .{ .input = "ls\r" }, "{\"type\":\"input\",\"data\":\"ls\\r\"}" },
        .{ .{ .resize = .{ .cols = 120, .rows = 40 } }, "{\"type\":\"resize\",\"cols\":120,\"rows\":40}" },
        .{ .{ .paste_image = .{ .mime = "image/png", .data = "AAA=" } }, "{\"type\":\"paste-image\",\"mime\":\"image/png\",\"data\":\"AAA=\"}" },
        .{ .{ .clipboard_sync = .{ .mime = "image/png", .data = "AAA=" } }, "{\"type\":\"clipboard-sync\",\"mime\":\"image/png\",\"data\":\"AAA=\"}" },
    };
    for (cases) |c| {
        const s = try encodeClientFrameAlloc(a, c[0]);
        defer a.free(s);
        try t.expectEqualStrings(c[1], s);
    }
}

test "server frames parse (byte-exact host output)" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const snap = try parseServerFrame(a, "{\"type\":\"snapshot\",\"data\":\"\\u001b[?25h$ \",\"cols\":100,\"rows\":30,\"title\":\"t\",\"pid\":4242}");
    try t.expectEqualStrings("\x1b[?25h$ ", snap.snapshot.data);
    try t.expectEqual(@as(u16, 100), snap.snapshot.cols);
    try t.expectEqual(@as(u16, 30), snap.snapshot.rows);
    try t.expectEqual(@as(?i64, 4242), snap.snapshot.pid);

    try t.expectEqualStrings("hi\r\n", (try parseServerFrame(a, "{\"type\":\"output\",\"data\":\"hi\\r\\n\"}")).output);
    try t.expectEqualStrings("vim", (try parseServerFrame(a, "{\"type\":\"title\",\"title\":\"vim\"}")).title);
    const st = try parseServerFrame(a, "{\"type\":\"session-title\",\"session\":\"abc\",\"title\":\"x\"}");
    try t.expectEqualStrings("abc", st.session_title.session);
    try t.expectEqual(@as(i64, 7), (try parseServerFrame(a, "{\"type\":\"exit\",\"exitCode\":7}")).exit.code);
    try t.expectEqualStrings("no such session", (try parseServerFrame(a, "{\"type\":\"error\",\"message\":\"no such session\"}")).@"error".message);
    const pr = try parseServerFrame(a, "{\"mode\":\"path\",\"path\":\"/tmp/p.png\",\"type\":\"paste-result\"}");
    try t.expectEqualStrings("path", pr.paste_result.mode);
    try t.expectEqualStrings("/tmp/p.png", pr.paste_result.path.?);
    const ou = try parseServerFrame(a, "{\"id\":\"open-1-0\",\"type\":\"open-url\",\"url\":\"https://x.y/\"}");
    try t.expectEqualStrings("https://x.y/", ou.open_url.url);
    try t.expectEqualStrings("wat", (try parseServerFrame(a, "{\"type\":\"wat\"}")).unknown);
    try t.expectError(error.InvalidFrame, parseServerFrame(a, "[1]"));
    try t.expectError(error.InvalidFrame, parseServerFrame(a, "{\"data\":1}"));
}
