//! Test helpers: layouts written as compact strings.
//!
//! Spec: columns separated by `|`, panes within a column by `,`. A column
//! starting with `!` is full. A pane is its id, optionally `:weight`, then
//! `^` if it is its column's active pane (default: the focused pane if it
//! is in that column, else the first) and `*` if it is focused (default:
//! the first column's active pane).
//! Example: `a,b^*|!c|files-x:2,d^`.
//!
//! `render` writes the canonical form: every column's active pane marked
//! `^`, the focused pane `*`, no weights.

const std = @import("std");
const Layout = @import("Layout.zig");

pub const gpa = std.testing.allocator;

pub fn build(spec: []const u8) !Layout {
    var l: Layout = .init(gpa);
    errdefer l.deinit();
    var focused: ?[]const u8 = null;
    if (spec.len == 0) return l;
    var cols = std.mem.splitScalar(u8, spec, '|');
    while (cols.next()) |col_spec_raw| {
        var col_spec = col_spec_raw;
        var full = false;
        if (col_spec.len > 0 and col_spec[0] == '!') {
            full = true;
            col_spec = col_spec[1..];
        }
        var ids: [16][]const u8 = undefined;
        var sizes: [16]f64 = undefined;
        var n: usize = 0;
        var active: ?usize = null;
        var focus_row: ?usize = null;
        var panes = std.mem.splitScalar(u8, col_spec, ',');
        while (panes.next()) |tok_raw| {
            var tok = tok_raw;
            var is_focus = false;
            while (tok.len > 0 and (tok[tok.len - 1] == '^' or tok[tok.len - 1] == '*')) {
                if (tok[tok.len - 1] == '^') active = n else is_focus = true;
                tok = tok[0 .. tok.len - 1];
            }
            var w: f64 = 1;
            if (std.mem.indexOfScalar(u8, tok, ':')) |c| {
                w = try std.fmt.parseFloat(f64, tok[c + 1 ..]);
                tok = tok[0..c];
            }
            if (is_focus) {
                focused = tok;
                focus_row = n;
            }
            ids[n] = tok;
            sizes[n] = w;
            n += 1;
        }
        try l.appendColumn(ids[0..n], sizes[0..n], active orelse focus_row orelse 0, full);
    }
    if (focused) |f| l.focused = l.find(f).?;
    l.normalizeFocus();
    try l.check();
    return l;
}

pub fn render(l: *const Layout) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (l.columns.items, 0..) |col, ci| {
        if (ci > 0) try out.append(gpa, '|');
        if (col.full) try out.append(gpa, '!');
        for (col.panes.items, 0..) |p, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.appendSlice(gpa, p.id);
            if (col.active == p) try out.append(gpa, '^');
            if (l.focused == p) try out.append(gpa, '*');
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn expectLayout(l: *const Layout, expected: []const u8) !void {
    try l.check();
    const got = try render(l);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

pub fn expectSizes(l: *const Layout, col: usize, expected: []const f64) !void {
    const got = l.columns.items[col].sizes.items;
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectApproxEqAbs(e, g, 1e-9);
}
