//! Pure path and formatting helpers for the file browser (no GTK). Ports
//! of the small functions at the top of electron/ui/files-widget.js.
//! Paths are the host's: absolute, '/'-separated, never ending in '/'
//! except the root itself.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// `dir/name` (`/name` under the root). files-widget.js `fsJoin`.
pub fn join(alloc: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(alloc, "/{s}", .{name});
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
}

/// The parent directory; "/" for top-level entries and for "/" itself.
/// files-widget.js `fsParent`.
pub fn parent(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return "/";
    return if (i == 0) "/" else p[0..i];
}

/// The last segment; "/" for the root. files-widget.js `fsBase`.
pub fn base(p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "/")) return "/";
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
    return p[i + 1 ..];
}

/// '/a/b' → ['/', '/a', '/a/b']: slices of `dir` (the root is the
/// literal "/"). Caller frees the outer slice. files-widget.js `fsChain`.
pub fn chain(alloc: Allocator, dir: []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, "/");
    var i: usize = 0;
    while (i < dir.len) {
        if (dir[i] == '/') {
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, dir, i, '/') orelse dir.len;
        try out.append(alloc, dir[0..end]);
        i = end;
    }
    return out.toOwnedSlice(alloc);
}

/// `.md .markdown .mdown .mkd`, any case. files-widget.js `isMarkdownName`.
pub fn isMarkdownName(name: []const u8) bool {
    const exts = [_][]const u8{ ".md", ".markdown", ".mdown", ".mkd" };
    for (exts) |e| {
        if (name.len >= e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) return true;
    }
    return false;
}

/// `~` + rest when `p` is the home directory or inside it, else `p`.
/// `home` null (unknown, or "/") disables the abbreviation.
/// files-widget.js `tildePath`.
pub fn tilde(alloc: Allocator, home: ?[]const u8, p: []const u8) Allocator.Error![]u8 {
    if (home) |h| {
        if (h.len > 0 and std.mem.startsWith(u8, p, h) and
            (p.len == h.len or p[h.len] == '/'))
        {
            return std.fmt.allocPrint(alloc, "~{s}", .{p[h.len..]});
        }
    }
    return alloc.dupe(u8, p);
}

/// Measures the display width of a string (in whatever unit `max` is in).
pub const Measure = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, text: []const u8) f64,

    fn of(self: Measure, text: []const u8) f64 {
        return self.func(self.ctx, text);
    }
};

/// Shorten a display path to `max_width` while keeping its last segment
/// whole for as long as possible: interior directories collapse into one
/// '…' starting next to the anchor ('~' or the root), then the anchor
/// goes, then only the name is left (the label ellipsises it from there).
///   ~/src/webmux/electron/ui/app.js → ~/…/electron/ui/app.js
///   → ~/…/ui/app.js → ~/…/app.js → …/app.js → app.js
/// files-widget.js `fitPath`. Returns a new string.
pub fn fitPath(alloc: Allocator, display: []const u8, max_width: f64, measure: Measure) Allocator.Error![]u8 {
    if (measure.of(display) <= max_width) return alloc.dupe(u8, display);
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(alloc);
    var it = std.mem.splitScalar(u8, display, '/');
    while (it.next()) |seg| try dirs.append(alloc, seg);
    const name = dirs.pop().?;
    if (name.len == 0) return alloc.dupe(u8, display); // '/' itself
    const n = dirs.items.len;
    var tail: isize = @as(isize, @intCast(n)) - 2;
    while (tail >= 0) : (tail -= 1) {
        const keep: usize = @intCast(tail);
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll(dirs.items[0]) catch return error.OutOfMemory;
        w.writeAll("/…") catch return error.OutOfMemory;
        for (dirs.items[n - keep ..]) |d| w.print("/{s}", .{d}) catch return error.OutOfMemory;
        w.print("/{s}", .{name}) catch return error.OutOfMemory;
        if (measure.of(aw.written()) <= max_width) return aw.toOwnedSlice();
    }
    const s = try std.fmt.allocPrint(alloc, "…/{s}", .{name});
    if (measure.of(s) <= max_width) return s;
    alloc.free(s);
    return alloc.dupe(u8, name);
}

/// `N B` under 1024, else KB/MB/GB/TB with one decimal below 10 and
/// none above. files-widget.js `formatSize` (JS toFixed rounding).
pub fn formatSize(buf: []u8, bytes: f64) []const u8 {
    if (bytes < 1024) {
        // NaN and negatives (a hostile listing) show as 0 B.
        const b: u64 = if (bytes > 0) @intFromFloat(bytes) else 0;
        return std.fmt.bufPrint(buf, "{d} B", .{b}) catch "?";
    }
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v = bytes;
    var u: usize = 0;
    v /= 1024;
    while (v >= 1024 and u < units.len - 1) {
        v /= 1024;
        u += 1;
    }
    if (v < 10) {
        return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ jsToFixed(v, 1), units[u] }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ jsToFixed(v, 0), units[u] }) catch "?";
}

/// Round half away from zero at `digits` decimals, as Number#toFixed
/// does for the values formatSize sees (Zig's {d:.N} rounds half to even).
fn jsToFixed(v: f64, digits: u8) f64 {
    const m = std.math.pow(f64, 10, @floatFromInt(digits));
    return @floor(v * m + 0.5) / m;
}

/// Resolve a link from a markdown file against that file's directory.
/// Null for anything with a scheme (http:, mailto:, …). The result is
/// absolute and normalised ('.' and '..' applied, no empty segments).
/// files-widget.js `resolveRelative`.
pub fn resolveRelative(alloc: Allocator, base_dir: []const u8, href: []const u8) Allocator.Error!?[]u8 {
    if (hasScheme(href)) return null;
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(alloc);
    if (!std.mem.startsWith(u8, href, "/")) {
        var it = std.mem.tokenizeScalar(u8, base_dir, '/');
        while (it.next()) |s| try segs.append(alloc, s);
    }
    var it = std.mem.splitScalar(u8, href, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            _ = segs.pop();
        } else try segs.append(alloc, seg);
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    if (segs.items.len == 0) aw.writer.writeByte('/') catch return error.OutOfMemory;
    for (segs.items) |s| aw.writer.print("/{s}", .{s}) catch return error.OutOfMemory;
    return try aw.toOwnedSlice();
}

/// `^[a-z][a-z0-9+.-]*:` (case-insensitive).
pub fn hasScheme(href: []const u8) bool {
    if (href.len == 0 or !std.ascii.isAlphabetic(href[0])) return false;
    for (href[1..]) |c| {
        if (c == ':') return true;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-')) return false;
    }
    return false;
}

pub fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Decode %XX escapes (a relative markdown link to "my%20file.md" names
/// "my file.md"; the browser's URL resolution does the same before the
/// widget compares names). Invalid escapes are kept as they are.
pub fn percentDecode(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                try out.append(alloc, hi.? * 16 + lo.?);
                i += 2;
                continue;
            }
        }
        try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

/// Byte length of the rename preselection: everything before the last
/// '.', or the whole name for dot-files and names without an extension.
/// files-widget.js startRename (`setSelectionRange(0, dot > 0 ? dot : len)`).
pub fn renameStemLen(name: []const u8) usize {
    if (std.mem.startsWith(u8, name, ".")) return name.len;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name.len;
    return if (dot > 0) dot else name.len;
}

/// Number of UTF-8 code points in `s` (GTK editables count characters).
pub fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

// --- tests ---------------------------------------------------------------

const t = std.testing;

test "join, parent, base" {
    const a = try join(t.allocator, "/", "etc");
    defer t.allocator.free(a);
    try t.expectEqualStrings("/etc", a);
    const b = try join(t.allocator, "/home/u", "x y");
    defer t.allocator.free(b);
    try t.expectEqualStrings("/home/u/x y", b);
    try t.expectEqualStrings("/", parent("/"));
    try t.expectEqualStrings("/", parent("/etc"));
    try t.expectEqualStrings("/home", parent("/home/u"));
    try t.expectEqualStrings("/", base("/"));
    try t.expectEqualStrings("u", base("/home/u"));
}

test "chain" {
    const c = try chain(t.allocator, "/a/b");
    defer t.allocator.free(c);
    try t.expectEqual(@as(usize, 3), c.len);
    try t.expectEqualStrings("/", c[0]);
    try t.expectEqualStrings("/a", c[1]);
    try t.expectEqualStrings("/a/b", c[2]);
    const r = try chain(t.allocator, "/");
    defer t.allocator.free(r);
    try t.expectEqual(@as(usize, 1), r.len);
}

test "isMarkdownName" {
    try t.expect(isMarkdownName("README.md"));
    try t.expect(isMarkdownName("x.MarkDown"));
    try t.expect(isMarkdownName("a.mkd"));
    try t.expect(!isMarkdownName("md"));
    try t.expect(!isMarkdownName("a.mdx"));
}

test "tilde" {
    const cases = .{
        .{ "/home/u", "/home/u", "~" },
        .{ "/home/u", "/home/u/src/x", "~/src/x" },
        .{ "/home/u", "/home/user", "/home/user" },
        .{ "/home/u", "/etc", "/etc" },
    };
    inline for (cases) |c| {
        const s = try tilde(t.allocator, c[0], c[1]);
        defer t.allocator.free(s);
        try t.expectEqualStrings(c[2], s);
    }
    const n = try tilde(t.allocator, null, "/home/u");
    defer t.allocator.free(n);
    try t.expectEqualStrings("/home/u", n);
}

fn byteMeasure(_: *anyopaque, text: []const u8) f64 {
    // Count code points so '…' is one unit wide.
    return @floatFromInt(charCount(text));
}

test "fitPath: the documented sequence" {
    var dummy: u8 = 0;
    const m: Measure = .{ .ctx = &dummy, .func = byteMeasure };
    const full = "~/src/webmux/electron/ui/app.js";
    const expect = [_]struct { w: f64, s: []const u8 }{
        .{ .w = 100, .s = full },
        .{ .w = 31, .s = full },
        .{ .w = 30, .s = "~/…/webmux/electron/ui/app.js" },
        .{ .w = 22, .s = "~/…/electron/ui/app.js" },
        .{ .w = 21, .s = "~/…/ui/app.js" },
        .{ .w = 12, .s = "~/…/app.js" },
        .{ .w = 9, .s = "…/app.js" },
        .{ .w = 7, .s = "app.js" },
        .{ .w = 2, .s = "app.js" },
    };
    for (expect) |e| {
        const s = try fitPath(t.allocator, full, e.w, m);
        defer t.allocator.free(s);
        try t.expectEqualStrings(e.s, s);
    }
    const root = try fitPath(t.allocator, "/", 0, m);
    defer t.allocator.free(root);
    try t.expectEqualStrings("/", root);
    const abs = try fitPath(t.allocator, "/usr/share/doc/x", 13, m);
    defer t.allocator.free(abs);
    try t.expectEqualStrings("/…/doc/x", abs);
}

test "formatSize" {
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("0 B", formatSize(&buf, 0));
    try t.expectEqualStrings("1023 B", formatSize(&buf, 1023));
    try t.expectEqualStrings("1.0 KB", formatSize(&buf, 1024));
    try t.expectEqualStrings("1.5 KB", formatSize(&buf, 1536));
    try t.expectEqualStrings("12 MB", formatSize(&buf, 12 * 1024 * 1024));
    try t.expectEqualStrings("10.0 KB", formatSize(&buf, 10 * 1024 - 1));
    try t.expectEqualStrings("2.3 KB", formatSize(&buf, 2.25 * 1024));
    try t.expectEqualStrings("2048 TB", formatSize(&buf, 2048.0 * 1024 * 1024 * 1024 * 1024));
}

test "resolveRelative" {
    const cases = .{
        .{ "/home/u/docs", "img/a.png", "/home/u/docs/img/a.png" },
        .{ "/home/u/docs", "../b.md", "/home/u/b.md" },
        .{ "/home/u/docs", "./c", "/home/u/docs/c" },
        .{ "/home/u/docs", "/etc/x", "/etc/x" },
        .{ "/", "../../x", "/x" },
        .{ "/a", "..", "/" },
    };
    inline for (cases) |c| {
        const s = (try resolveRelative(t.allocator, c[0], c[1])).?;
        defer t.allocator.free(s);
        try t.expectEqualStrings(c[2], s);
    }
    try t.expect(try resolveRelative(t.allocator, "/", "https://x") == null);
    try t.expect(try resolveRelative(t.allocator, "/", "mailto:a@b") == null);
    try t.expect(hasScheme("a+b.c-d:x"));
    try t.expect(!hasScheme("1http:x"));
    try t.expect(!hasScheme("dir/x:y"));
}

test "percentDecode" {
    const s = try percentDecode(t.allocator, "my%20file%2Emd%zz%4");
    defer t.allocator.free(s);
    try t.expectEqualStrings("my file.md%zz%4", s);
}

test "renameStemLen" {
    try t.expectEqual(@as(usize, 6), renameStemLen("report.pdf"));
    try t.expectEqual(@as(usize, 5), renameStemLen("a.tar.gz"));
    try t.expectEqual(@as(usize, 7), renameStemLen(".bashrc"));
    try t.expectEqual(@as(usize, 8), renameStemLen("Makefile"));
    try t.expectEqual(@as(usize, 7), renameStemLen("archive."));
}
