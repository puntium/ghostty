//! The host pill's pane map (`iface.Minimap`): every column and pane of a
//! workspace as a small block diagram, the focused pane marked, and, when
//! the strip scrolls, an outline of the part of the strip on screen, so
//! panes beyond the window are visible at a glance. Pure (no GTK); the
//! port of the macOS client's `MinimapLayout`, so both clients draw the
//! same map for the same layout.
//!
//! Not to scale on purpose: column widths and pane heights keep their
//! proportions, but every column gets at least `min_column` px and the
//! gaps are fixed (hairlines once squeezed), so a narrow column never
//! vanishes. The viewport outline is mapped piecewise through the same
//! columns and gaps.
const std = @import("std");
const Allocator = std.mem.Allocator;
const iface = @import("../iface.zig");
const layout = @import("../../../webmux/layout.zig");
const geometry = @import("geometry.zig");
const Geometry = geometry.Geometry;
const Minimap = iface.Minimap;

pub const default_height: f64 = 18;
pub const default_max_width: f64 = 140;
pub const min_column: f64 = 5;
pub const max_column: f64 = 36;
pub const column_gap: f64 = 2;
pub const row_gap: f64 = 1.5;
/// Room around the boxes for the viewport outline.
pub const inset: f64 = 2;

/// The map of `cols` (focused pane `focused`) laid out as `g`, scrolled
/// to `scroll`, `height` px tall and at most `max_width` wide. Empty when
/// there are no columns or `g` does not describe them.
pub fn compute(
    gpa: Allocator,
    cols: []const *layout.Column,
    focused: ?[]const u8,
    g: *const Geometry,
    scroll: f64,
    height: f64,
    max_width: f64,
) Allocator.Error!Minimap {
    const n = cols.len;
    if (n == 0 or g.strip.columns.len != n or g.stacks.len != n or g.viewport_h <= 0) return .empty;
    const inner = height - 2 * inset;

    // Proportional widths at the strip's own aspect, clamped, then
    // squeezed to fit the max width.
    const widths = try gpa.alloc(f64, n);
    defer gpa.free(widths);
    const xs = try gpa.alloc(f64, n);
    defer gpa.free(xs);
    const sy = inner / g.viewport_h;
    var total: f64 = 0;
    for (g.strip.columns, 0..) |c, i| {
        widths[i] = @min(max_column, @max(min_column, c.width * sy));
        total += widths[i];
    }
    var gap = column_gap;
    const n_gaps: f64 = @floatFromInt(n - 1);
    if (total + n_gaps * gap > max_width - 2 * inset) {
        // Squeezed: hairline gaps, columns shrink to fit (never below 2 px).
        gap = 1;
        const room = max_width - 2 * inset - n_gaps * gap;
        const k = @max(0, room) / total;
        for (widths) |*w| w.* = @max(2, w.* * k);
    }

    var n_cells: usize = 0;
    for (cols) |c| n_cells += c.len();
    var cells: std.ArrayList(Minimap.Cell) = try .initCapacity(gpa, n_cells);
    errdefer {
        for (cells.items) |c| gpa.free(c.id);
        cells.deinit(gpa);
    }
    var x = inset;
    for (cols, 0..) |col, ci| {
        xs[ci] = x;
        const w = widths[ci];
        const spans = g.stacks[ci].panes;
        var sum: f64 = 0;
        for (spans) |s| sum += s.height;
        const count = col.len();
        const rows_h = inner - @as(f64, @floatFromInt(count -| 1)) * row_gap;
        var y = inset;
        for (col.panes.items, 0..) |pane, ri| {
            const frac = if (sum > 0 and ri < spans.len) spans[ri].height / sum else 1 / @as(f64, @floatFromInt(@max(1, count)));
            const h = @max(1, rows_h * frac);
            const is_focused = focused != null and std.mem.eql(u8, focused.?, pane.id);
            cells.appendAssumeCapacity(.{
                .id = try gpa.dupe(u8, pane.id),
                .rect = .{ .x = x, .y = y, .w = w, .h = h },
                .focused = is_focused,
            });
            y += h + row_gap;
        }
        x += w + gap;
    }
    const width = @ceil(x - gap + inset);

    // Strip x → map x: linear inside a column, across a gap, and in the
    // padding before the first / after the last column.
    const mapper: Mapper = .{ .cols = g.strip.columns, .xs = xs, .widths = widths, .gap = gap, .width = width };
    var viewport: ?Minimap.Rect = null;
    const sc = g.strip.columns;
    const left = scroll;
    const right = scroll + g.strip.viewport;
    if (sc[0].x < left - 0.5 or sc[n - 1].right() > right + 0.5) {
        const l = mapper.map(left);
        const r = mapper.map(right);
        viewport = .{ .x = l, .y = 0.5, .w = @max(2, r - l), .h = height - 1 };
    }
    return .{
        .cells = try cells.toOwnedSlice(gpa),
        .viewport = viewport,
        .width = width,
        .height = height,
    };
}

const Mapper = struct {
    cols: []const layout.width.ColumnBox,
    xs: []const f64,
    widths: []const f64,
    gap: f64,
    width: f64,

    fn map(m: Mapper, sx: f64) f64 {
        const cols = m.cols;
        if (sx <= cols[0].x) return m.xs[0] - (if (sx < cols[0].x) inset else 0);
        for (cols, 0..) |c, i| {
            if (sx <= c.right()) return m.xs[i] + m.widths[i] * ((sx - c.x) / @max(1, c.width));
            if (i + 1 < cols.len and sx < cols[i + 1].x) {
                return m.xs[i] + m.widths[i] + m.gap * ((sx - c.right()) / @max(1, cols[i + 1].x - c.right()));
            }
        }
        return m.width - inset + (if (sx > cols[cols.len - 1].right()) inset else 0);
    }
};

// ---------------------------------------------------------------------------

const t = std.testing;

fn geom(l: *const layout.Layout, width: f64) !Geometry {
    return geometry.compute(t.allocator, l.columns.items, width, 900, 8, .{});
}

fn mapOf(l: *const layout.Layout, g: *const Geometry, scroll: f64) !Minimap {
    return compute(t.allocator, l.columns.items, l.focusedId(), g, scroll, default_height, default_max_width);
}

test "minimap: an empty layout is the empty map" {
    var l: layout.Layout = .init(t.allocator);
    defer l.deinit();
    var g = try geom(&l, 1400);
    defer g.deinit(t.allocator);
    var m = try mapOf(&l, &g, 0);
    defer m.deinit(t.allocator);
    try t.expect(m.isEmpty());
    try t.expectEqual(@as(?[]const u8, null), m.paneAt(3, 3));
}

test "minimap: cells follow columns and stacks and mark the focus" {
    var l: layout.Layout = .init(t.allocator);
    defer l.deinit();
    try l.newTerminal("a");
    try l.newTerminalBelow("b");
    try l.newTerminal("c");
    var g = try geom(&l, 3000);
    defer g.deinit(t.allocator);
    var m = try mapOf(&l, &g, 0);
    defer m.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), m.cells.len);
    try t.expectEqualStrings("a", m.cells[0].id);
    try t.expectEqualStrings("b", m.cells[1].id);
    try t.expectEqualStrings("c", m.cells[2].id);
    try t.expect(!m.cells[0].focused and !m.cells[1].focused and m.cells[2].focused);
    const a = m.cells[0].rect;
    const b = m.cells[1].rect;
    const c = m.cells[2].rect;
    try t.expectEqual(a.x, b.x);
    try t.expect(a.y + a.h < b.y);
    try t.expect(c.x > a.x + a.w);
    try t.expect(m.viewport == null); // everything fits: no outline
    try t.expect(m.width <= default_max_width + 1);
    try t.expectEqual(default_height, m.height);
    try t.expectEqualStrings("c", m.paneAt(c.x + c.w / 2, c.y + c.h / 2).?);
}

test "minimap: overflow shows the viewport and it moves with the scroll" {
    var l: layout.Layout = .init(t.allocator);
    defer l.deinit();
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |id| try l.newTerminal(id);
    var g = try geom(&l, 1000);
    defer g.deinit(t.allocator);
    try t.expect(g.strip.overflows);
    var start = try mapOf(&l, &g, 0);
    defer start.deinit(t.allocator);
    var end = try mapOf(&l, &g, g.strip.max_scroll);
    defer end.deinit(t.allocator);
    const v0 = start.viewport.?;
    const v1 = end.viewport.?;
    try t.expect(v0.x < v1.x);
    const last0 = start.cells[start.cells.len - 1].rect;
    const last1 = end.cells[end.cells.len - 1].rect;
    try t.expect(v0.x + v0.w < last0.x + last0.w); // the last column is off screen at scroll 0
    try t.expect(v1.x + v1.w >= last1.x + last1.w);
}

test "minimap: many columns fit the max width" {
    var l: layout.Layout = .init(t.allocator);
    defer l.deinit();
    var names: [40][4]u8 = undefined;
    for (&names, 0..) |*nm, i| {
        const s = try std.fmt.bufPrint(nm, "t{d}", .{i});
        try l.newTerminal(s);
    }
    var g = try geom(&l, 1400);
    defer g.deinit(t.allocator);
    var m = try mapOf(&l, &g, 0);
    defer m.deinit(t.allocator);
    try t.expectEqual(@as(usize, 40), m.cells.len);
    try t.expect(m.width <= default_max_width + 1);
}
