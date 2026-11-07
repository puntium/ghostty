//! Request targets and response shapes of the host's file-system routes
//! (host/internal/server/fs.go). Pure: no GTK, no sockets; `api.zig` does
//! the requests.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zip = @import("zip.zig");

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: []const u8,
    };
}

/// Upload limit per file (host: `uploadLimit`, 200 MiB).
pub const upload_limit: u64 = 200 * 1024 * 1024;

pub const Entry = struct {
    name: []const u8,
    dir: bool,
    symlink: bool,
};

pub const Listing = struct {
    /// Absolute path the host resolved the request to.
    path: []const u8,
    entries: []Entry,
    truncated: bool,
};

pub const Kind = enum { other, image, zip, binary, text };

pub const Preview = struct {
    size: f64,
    /// Fractional epoch milliseconds.
    mtime: f64,
    kind: Kind,
    /// zip
    entries: []const zip.Entry = &.{},
    count: f64 = 0,
    /// zip (list capped) or text (content cut at 64 KiB)
    truncated: bool = false,
    /// text: the first 64 KiB, invalid UTF-8 already replaced by the host.
    content: []const u8 = "",
};

pub fn target(alloc: Allocator, comptime route: []const u8, params: anytype) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll(route) catch return error.OutOfMemory;
    inline for (@typeInfo(@TypeOf(params)).@"struct".field_names, 0..) |name, i| {
        w.writeAll(if (i == 0) "?" else "&") catch return error.OutOfMemory;
        w.writeAll(name ++ "=") catch return error.OutOfMemory;
        percentEncode(w, @field(params, name)) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

/// Everything but unreserved characters escaped (as net.http.percentEncode
/// and encodeURIComponent minus its extra unescaped marks; the host
/// decodes either).
pub fn percentEncode(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// The request target for a download (`/api/fs/raw?path=…&download=1`).
pub fn downloadTarget(alloc: Allocator, path: []const u8) Allocator.Error![]u8 {
    return target(alloc, "/api/fs/raw", .{ .path = path, .download = "1" });
}

pub fn watchTarget(alloc: Allocator, dir: []const u8) Allocator.Error![]u8 {
    return target(alloc, "/api/fs/watch", .{ .path = dir });
}

/// The text of a failed response: the host's `error` field, else "HTTP n".
pub fn hostError(alloc: Allocator, status: u16, body: []const u8) []const u8 {
    if (errorField(alloc, body)) |e| return e;
    return std.fmt.allocPrint(alloc, "HTTP {d}", .{status}) catch "HTTP error";
}

pub fn errorField(alloc: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(struct { @"error": ?[]const u8 = null }, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    return parsed.@"error";
}

pub fn parseListing(alloc: Allocator, body: []const u8) Allocator.Error!Result(Listing) {
    const Raw = struct {
        path: []const u8 = "",
        entries: []const struct {
            name: []const u8,
            type: []const u8 = "file",
            symlink: bool = false,
        } = &.{},
        truncated: bool = false,
    };
    const raw = std.json.parseFromSliceLeaky(Raw, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = "invalid listing" },
    };
    const entries = try alloc.alloc(Entry, raw.entries.len);
    for (raw.entries, entries) |r, *e| e.* = .{
        .name = r.name,
        .dir = std.mem.eql(u8, r.type, "dir"),
        .symlink = r.symlink,
    };
    return .{ .ok = .{ .path = raw.path, .entries = entries, .truncated = raw.truncated } };
}

pub fn parsePreview(alloc: Allocator, body: []const u8) Allocator.Error!Result(Preview) {
    const Raw = struct {
        size: f64 = 0,
        mtime: f64 = 0,
        kind: []const u8 = "other",
        entries: []const zip.Entry = &.{},
        count: f64 = 0,
        truncated: bool = false,
        content: []const u8 = "",
    };
    const raw = std.json.parseFromSliceLeaky(Raw, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = "preview failed" },
    };
    return .{ .ok = .{
        .size = raw.size,
        .mtime = raw.mtime,
        .kind = std.meta.stringToEnum(Kind, raw.kind) orelse .other,
        .entries = raw.entries,
        .count = raw.count,
        .truncated = raw.truncated,
        .content = raw.content,
    } };
}

/// The top-level entry of an upload's relative name (`a/b/c` → `a`):
/// where the cursor lands afterwards (files-widget.js uploadTo).
pub fn topLevel(name: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, name, '/') orelse return name;
    return name[0..i];
}

/// A file browser's persisted state (F-02), parsed from untrusted text.
pub const State = struct {
    dir: []const u8 = "~",
    cursor: ?[]const u8 = null,
};

/// `{"type":"files","dir":…,"cursor":…}` from an earlier run. Anything
/// unusable falls back to the defaults: `dir` must be "~", "~/…" or
/// absolute, and `cursor` a plain entry name (no '/', not "." or "..").
pub fn parseState(arena: Allocator, text: ?[]const u8) State {
    const src = text orelse return .{};
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch return .{};
    if (v != .object) return .{};
    var out: State = .{};
    if (v.object.get("dir")) |d| if (d == .string and validDir(d.string)) {
        out.dir = d.string;
    };
    if (v.object.get("cursor")) |c| if (c == .string and validName(c.string)) {
        out.cursor = c.string;
    };
    return out;
}

fn validDir(d: []const u8) bool {
    if (d.len == 0 or std.mem.indexOfScalar(u8, d, 0) != null) return false;
    return std.mem.eql(u8, d, "~") or std.mem.startsWith(u8, d, "~/") or d[0] == '/';
}

fn validName(n: []const u8) bool {
    if (n.len == 0 or std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) return false;
    return std.mem.indexOfAny(u8, n, "/\x00") == null;
}

const t = std.testing;

test "parseState" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = parseState(a, "{\"type\":\"files\",\"dir\":\"/home/u/src\",\"cursor\":\"a b.txt\"}");
    try t.expectEqualStrings("/home/u/src", s1.dir);
    try t.expectEqualStrings("a b.txt", s1.cursor.?);
    const s2 = parseState(a, "{\"dir\":\"~\",\"cursor\":null}");
    try t.expectEqualStrings("~", s2.dir);
    try t.expect(s2.cursor == null);
    const bad = [_][]const u8{ "", "[1]", "{\"dir\":3}", "{\"dir\":\"rel/x\"}", "{\"dir\":\"/x\",\"cursor\":\"../y\"}", "nope" };
    for (bad) |b| {
        const st = parseState(a, b);
        try t.expect(st.cursor == null);
    }
    try t.expectEqualStrings("~", parseState(a, "{\"dir\":\"rel/x\"}").dir);
    try t.expectEqualStrings("/x", parseState(a, "{\"dir\":\"/x\",\"cursor\":\"../y\"}").dir);
    try t.expectEqualStrings("~", parseState(a, null).dir);
}

test "target encoding" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/api/fs/list?path=~", try target(a, "/api/fs/list", .{ .path = "~" }));
    try t.expectEqualStrings(
        "/api/fs/upload?dir=%2Fh%2Fa%20b&name=x%2Fy%20%281%29.txt",
        try target(a, "/api/fs/upload", .{ .dir = "/h/a b", .name = "x/y (1).txt" }),
    );
    try t.expectEqualStrings("/api/fs/raw?path=%2Fa&download=1", try downloadTarget(a, "/a"));
}

test "parseListing and parsePreview" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = (try parseListing(a,
        \\{"path":"/h","entries":[{"name":"d","type":"dir"},{"name":"l","type":"dir","symlink":true},{"name":"f","type":"file"}],"truncated":false}
    )).ok;
    try t.expectEqualStrings("/h", l.path);
    try t.expectEqual(@as(usize, 3), l.entries.len);
    try t.expect(l.entries[0].dir and !l.entries[0].symlink);
    try t.expect(l.entries[1].dir and l.entries[1].symlink);
    try t.expect(!l.entries[2].dir);

    const z = (try parsePreview(a,
        \\{"size":30,"mtime":1.7e12,"kind":"zip","entries":[{"name":"a/","size":0,"dir":true}],"count":1,"truncated":false}
    )).ok;
    try t.expectEqual(Kind.zip, z.kind);
    try t.expectEqual(@as(usize, 1), z.entries.len);
    const x = (try parsePreview(a,
        \\{"size":3,"mtime":5,"kind":"text","content":"hi\n","truncated":true}
    )).ok;
    try t.expectEqualStrings("hi\n", x.content);
    try t.expect(x.truncated);
    try t.expect((try parsePreview(a, "nope")) == .err);
}

test "topLevel" {
    try t.expectEqualStrings("a", topLevel("a/b/c.txt"));
    try t.expectEqualStrings("x.txt", topLevel("x.txt"));
}
