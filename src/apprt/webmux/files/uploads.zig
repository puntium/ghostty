//! What a drop or paste of local files uploads (std only, no GTK): each
//! dropped file under its own name, each dropped folder walked recursively
//! with its files named by their path relative to the folder's parent
//! (`photos/2024/a.jpg`), empty folders skipped. files-widget.js
//! `dropFiles` / `entryFiles`. Symlinks are followed, as a browser's file
//! entries do; a link back up the tree is cut off at `max_depth`. Files
//! that cannot be opened for reading are skipped, as the Electron client's
//! file entries skip them, instead of failing the whole upload later.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const LocalFile = struct {
    /// Absolute local path.
    path: []const u8,
    /// Upload name: the basename, or `folder/…/basename` inside a folder.
    name: []const u8,
    size: u64,
};

pub const max_depth = 32;

/// Collect the files to upload for `roots` (absolute local paths, in drop
/// order). Unreadable entries are skipped. Allocates from `arena`.
pub fn collect(arena: Allocator, io: Io, roots: []const []const u8) Allocator.Error![]LocalFile {
    var out: std.ArrayList(LocalFile) = .empty;
    for (roots) |root| {
        const st = Io.Dir.cwd().statFile(io, root, .{}) catch continue;
        const name = std.fs.path.basename(root);
        if (st.kind == .directory) {
            try walk(arena, io, root, name, 0, &out);
        } else if (st.kind == .file and readable(io, root)) {
            try out.append(arena, .{ .path = try arena.dupe(u8, root), .name = try arena.dupe(u8, name), .size = st.size });
        }
    }
    return out.toOwnedSlice(arena);
}

fn readable(io: Io, path: []const u8) bool {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn walk(arena: Allocator, io: Io, dir_path: []const u8, rel: []const u8, depth: usize, out: *std.ArrayList(LocalFile)) Allocator.Error!void {
    if (depth >= max_depth) return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    // Read the names first, then sort them so uploads go in a stable order.
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| try names.append(arena, try arena.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items) |n| {
        const child = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, n });
        const child_rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, n });
        const st = Io.Dir.cwd().statFile(io, child, .{}) catch continue;
        switch (st.kind) {
            .directory => try walk(arena, io, child, child_rel, depth + 1, out),
            .file => if (readable(io, child)) try out.append(arena, .{ .path = child, .name = child_rel, .size = st.size }),
            else => {},
        }
    }
}

test "collect: files, folders recursively, empty folders skipped" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "drop/sub/empty");
    try d.createDirPath(io, "drop/sub/deep");
    try d.writeFile(io, .{ .sub_path = "drop/b.txt", .data = "bb" });
    try d.writeFile(io, .{ .sub_path = "drop/sub/deep/c.bin", .data = "ccc" });
    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try d.writeFile(io, .{ .sub_path = "drop/sub/unreadable.txt", .data = "no" });
    {
        const f = try d.openFile(io, "drop/sub/unreadable.txt", .{});
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0));
    }

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try d.realPathFileAlloc(io, ".", a);
    const roots = [_][]const u8{
        try std.fmt.allocPrint(a, "{s}/a.txt", .{base}),
        try std.fmt.allocPrint(a, "{s}/drop", .{base}),
        try std.fmt.allocPrint(a, "{s}/missing", .{base}),
    };
    const files = try collect(a, io, &roots);
    try t.expectEqual(@as(usize, 3), files.len);
    try t.expectEqualStrings("a.txt", files[0].name);
    try t.expectEqual(@as(u64, 1), files[0].size);
    try t.expectEqualStrings("drop/b.txt", files[1].name);
    try t.expectEqualStrings("drop/sub/deep/c.bin", files[2].name);
    try t.expectEqual(@as(u64, 3), files[2].size);
    try t.expect(std.mem.endsWith(u8, files[2].path, "/drop/sub/deep/c.bin"));
}
