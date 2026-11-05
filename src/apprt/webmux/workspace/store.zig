//! The layout file on disk (`layout.persist` decides its shape and path):
//! read once at startup, written atomically (temp file + rename) whenever
//! the workspace's debounced save fires. Pure (no GTK).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const layout = @import("../../../webmux/layout.zig");
const util = @import("../../../webmux/conn/util.zig");

/// Larger files are not ours (a layout is a few KiB).
pub const max_bytes = 4 * 1024 * 1024;

/// `$XDG_STATE_HOME/webmux-gtk/layout/<slug>.json`.
pub fn pathFor(gpa: Allocator, slug: []const u8) layout.persist.PathError![]u8 {
    const state = if (std.c.getenv("XDG_STATE_HOME")) |p| std.mem.span(p) else null;
    const home = if (std.c.getenv("HOME")) |p| std.mem.span(p) else null;
    return layout.persist.statePath(gpa, state, home, slug);
}

/// The file's text, or null if there is none (or it cannot be read).
pub fn read(io: Io, gpa: Allocator, path: []const u8) ?[]u8 {
    return util.readFileAlloc(io, gpa, path, max_bytes) catch null;
}

/// Write `bytes` to `path` atomically, creating the directory (0700).
pub fn write(io: Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try util.makePath(io, dir, 0o700);
    try util.atomicWrite(io, path, bytes, 0o600);
}

/// app.js createFilesWidget: `files-<ms in base 36><0…9999>`.
pub fn newFilesId(buf: []u8, now_ms: u64, rand: u32) []const u8 {
    var tmp: [32]u8 = undefined;
    var n: usize = 0;
    var v = now_ms;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v > 0) : (v /= 36) {
        const d: u8 = @intCast(v % 36);
        tmp[n] = if (d < 10) '0' + d else 'a' + d - 10;
        n += 1;
    }
    std.mem.reverse(u8, tmp[0..n]);
    return std.fmt.bufPrint(buf, "files-{s}{d}", .{ tmp[0..n], rand % 10000 }) catch unreachable;
}

/// app.js: a new file browser starts in the home directory.
pub const initial_files_state = "{\"type\":\"files\",\"dir\":\"~\",\"cursor\":null}";

test "write then read back, atomically" {
    const t = std.testing;
    var dir_buf: [64]u8 = undefined;
    var rnd: [4]u8 = undefined;
    t.io.random(&rnd);
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/wm-ws-test-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    defer Io.Dir.cwd().deleteTree(t.io, dir) catch {};
    const path = try std.fmt.allocPrint(t.allocator, "{s}/webmux-gtk/layout/dev.json", .{dir});
    defer t.allocator.free(path);
    try t.expect(read(t.io, t.allocator, path) == null);
    try write(t.io, path, "{\"version\":1}");
    try write(t.io, path, "{\"version\":1,\"columns\":[]}");
    const back = read(t.io, t.allocator, path).?;
    defer t.allocator.free(back);
    try t.expectEqualStrings("{\"version\":1,\"columns\":[]}", back);
}

test "files ids look like app.js's" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const id = newFilesId(&buf, 1730000000000, 1234);
    try t.expect(std.mem.startsWith(u8, id, "files-"));
    try t.expectEqualStrings("files-m2r1bz7k1234", id);
    try t.expect(layout.Layout.kindOf(id) == .files);
}
