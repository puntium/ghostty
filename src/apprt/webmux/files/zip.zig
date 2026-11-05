//! A zip's table of contents as a `tree`-style listing (pure, no GTK).
//! files-widget.js `zipTree` + the walk in `previewContent`: members are
//! nested under their parents with ├──/└── connectors and │ indents,
//! folders first then names (case-insensitive), folders with a trailing
//! '/', files with their uncompressed size.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    name: []const u8,
    size: f64 = 0,
    dir: bool = false,
};

pub const Row = struct {
    /// Connector prefix: indents + "├── " or "└── ".
    prefix: []const u8,
    /// Member name, with '/' appended for folders.
    name: []const u8,
    dir: bool,
    /// Uncompressed size (files only).
    size: f64,
};

const Node = struct {
    name: []const u8,
    dir: bool = true,
    size: f64 = 0,
    children: std.ArrayList(*Node) = .empty,

    fn isDir(n: *const Node) bool {
        return n.dir or n.children.items.len > 0;
    }

    fn child(n: *Node, arena: Allocator, seg: []const u8) !*Node {
        for (n.children.items) |c| {
            if (std.mem.eql(u8, c.name, seg)) return c;
        }
        const c = try arena.create(Node);
        c.* = .{ .name = seg };
        try n.children.append(arena, c);
        return c;
    }
};

/// Flatten `entries` into display rows. Everything is allocated in
/// `arena` (free it as a whole). Directories with no entry of their own
/// are implied by their children's paths; a member that has children is a
/// directory whatever its own entry said.
pub fn rows(arena: Allocator, entries: []const Entry) Allocator.Error![]Row {
    var root: Node = .{ .name = "" };
    for (entries) |e| {
        var node = &root;
        var it = std.mem.tokenizeScalar(u8, e.name, '/');
        while (it.next()) |seg| node = try node.child(arena, seg);
        if (node != &root and !e.dir) {
            node.dir = false;
            node.size = e.size;
        }
    }
    var out: std.ArrayList(Row) = .empty;
    try walk(arena, &root, "", &out);
    return out.toOwnedSlice(arena);
}

fn lessThan(_: void, a: *Node, b: *Node) bool {
    const ad = a.isDir();
    const bd = b.isDir();
    if (ad != bd) return ad;
    return compareNames(a.name, b.name) == .lt;
}

/// Case-insensitive name order (localeCompare with sensitivity 'base' on
/// ASCII; other bytes compare as they are).
pub fn compareNames(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return std.math.order(lx, ly);
    }
    return std.math.order(a.len, b.len);
}

fn walk(arena: Allocator, node: *Node, indent: []const u8, out: *std.ArrayList(Row)) Allocator.Error!void {
    const kids = node.children.items;
    std.mem.sort(*Node, kids, {}, lessThan);
    for (kids, 0..) |kid, i| {
        const last = i == kids.len - 1;
        const dir = kid.isDir();
        try out.append(arena, .{
            .prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ indent, if (last) "└── " else "├── " }),
            .name = if (dir) try std.fmt.allocPrint(arena, "{s}/", .{kid.name}) else kid.name,
            .dir = dir,
            .size = if (dir) 0 else kid.size,
        });
        const next = try std.fmt.allocPrint(arena, "{s}{s}", .{ indent, if (last) "    " else "│   " });
        try walk(arena, kid, next, out);
    }
}

test "rows: tree connectors, folders first, implied folders, sizes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rows(a, &.{
        .{ .name = "README.md", .size = 10 },
        .{ .name = "src/", .dir = true },
        .{ .name = "src/b.zig", .size = 2 },
        .{ .name = "src/A.zig", .size = 1 },
        .{ .name = "docs/img/x.png", .size = 3 },
        .{ .name = "z.txt", .size = 4 },
        .{ .name = "src/sub/", .dir = true },
    });
    var aw: std.Io.Writer.Allocating = .init(a);
    for (r) |row| try aw.writer.print("{s}{s}|{d}\n", .{ row.prefix, row.name, row.size });
    try std.testing.expectEqualStrings(
        \\├── docs/|0
        \\│   └── img/|0
        \\│       └── x.png|3
        \\├── src/|0
        \\│   ├── sub/|0
        \\│   ├── A.zig|1
        \\│   └── b.zig|2
        \\├── README.md|10
        \\└── z.txt|4
        \\
    , aw.written());
}

test "rows: a member with children is a folder; empty archive" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try rows(arena.allocator(), &.{
        .{ .name = "a", .size = 5 },
        .{ .name = "a/b", .size = 1 },
    });
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expect(r[0].dir);
    try std.testing.expectEqualStrings("a/", r[0].name);
    try std.testing.expectEqualStrings("    └── ", r[1].prefix);
    const e = try rows(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), e.len);
}
