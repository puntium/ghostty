//! Where every pane and divider of a layout goes, in strip space, from the
//! model's width rule and stack geometry (`layout.width`). Pure (no GTK).
//! The widget allocates each pane once at its snapped box and scrolls by
//! moving the allocation's origin.
const std = @import("std");
const Allocator = std.mem.Allocator;
const layout = @import("../../../webmux/layout.zig");
const width = layout.width;
const Box = @import("anim.zig").Box;

/// The native pane's chrome for the width rule, as app.js PANE_CHROME_PX:
/// the frame's border (2) + the terminal pane's own padding (4 each side:
/// 8) + its scrollbar column (10) + rounding slack (4). The padding and the
/// scrollbar live inside the terminal pane's rectangle (pane area), so
/// they are constants here, not measured.
pub const metrics: width.Metrics = .{ .pane_chrome_px = 2 + 8 + 10 + 4 };

/// A JetBrains Mono cell at 13 px is 0.6 em = 7.8 px; Ghostty rounds its
/// cell to whole device pixels, so 8 at scale 1. Used until a terminal
/// reports its own (`Pane.cellWidthPx`).
pub const default_cell_px: f64 = 8;

/// The strip's horizontal scrollbar (index.html `::-webkit-scrollbar
/// { height: 10px }`): a classic scrollbar, so while the strip overflows it
/// takes this much of the strip's height and the columns get the rest.
pub const scrollbar_px: f64 = 10;

pub const PaneSlot = struct {
    col: usize,
    row: usize,
    /// Unsnapped (fractional) box.
    box: Box,
};

pub const DividerSlot = struct {
    col: usize,
    row: usize,
    box: Box,
};

pub const Geometry = struct {
    strip: width.StripGeometry,
    /// One per pane, in layout order (column by column, top to bottom).
    panes: []PaneSlot,
    /// One per divider, in layout order.
    dividers: []DividerSlot,
    /// Per column, its stack geometry (for divider drags).
    stacks: []width.StackGeometry,
    /// The height the columns lay out in: the strip's height less the
    /// scrollbar while there is one.
    viewport_h: f64,
    /// The strip overflows and shows its scrollbar along the bottom.
    scrollbar: bool,

    pub fn deinit(self: *Geometry, gpa: Allocator) void {
        for (self.stacks) |*s| s.deinit(gpa);
        gpa.free(self.stacks);
        gpa.free(self.panes);
        gpa.free(self.dividers);
        self.strip.deinit(gpa);
        self.* = undefined;
    }

    pub fn columnBox(self: *const Geometry, col: usize) Box {
        const c = self.strip.columns[col];
        const pad = self.strip.strip_pad;
        return .{ .x = c.x, .y = pad, .w = c.width, .h = @max(0, self.viewport_h - 2 * pad) };
    }

    pub fn paneBox(self: *const Geometry, col: usize, row: usize) ?Box {
        for (self.panes) |p| if (p.col == col and p.row == row) return p.box;
        return null;
    }

    /// The rounded scroll width (what a browser reports as scrollWidth).
    pub fn extent(self: *const Geometry) f64 {
        return @round(self.strip.scroll_width);
    }
};

pub fn settingsOf(min_cols: u16, max_cols: u16) width.Settings {
    const s: width.Settings = .{ .min_cols = min_cols, .max_cols = max_cols };
    return s.sanitized();
}

/// `cols` is a slice of `*layout.Column` (or anything with `full` and
/// `sizes.items`).
pub fn compute(
    gpa: Allocator,
    cols: []const *layout.Column,
    viewport_w: f64,
    viewport_h: f64,
    cell_px: f64,
    settings: width.Settings,
) Allocator.Error!Geometry {
    var strip = try width.stripGeometry(gpa, cols, viewport_w, cell_px, settings, metrics);
    errdefer strip.deinit(gpa);

    var n_panes: usize = 0;
    var n_div: usize = 0;
    for (cols) |c| {
        n_panes += c.len();
        n_div += c.len() - 1;
    }
    const panes = try gpa.alloc(PaneSlot, n_panes);
    errdefer gpa.free(panes);
    const dividers = try gpa.alloc(DividerSlot, n_div);
    errdefer gpa.free(dividers);
    const stacks = try gpa.alloc(width.StackGeometry, cols.len);
    var made: usize = 0;
    errdefer {
        for (stacks[0..made]) |*s| s.deinit(gpa);
        gpa.free(stacks);
    }

    const scrollbar = strip.max_scroll > 0;
    const strip_h = @max(0, viewport_h - (if (scrollbar) scrollbar_px else 0));
    var pi: usize = 0;
    var di: usize = 0;
    for (cols, 0..) |c, ci| {
        stacks[ci] = try width.stackGeometry(gpa, c.sizes.items, strip_h, metrics);
        made += 1;
        const cb = strip.columns[ci];
        for (stacks[ci].panes, 0..) |span, row| {
            panes[pi] = .{ .col = ci, .row = row, .box = .{ .x = cb.x, .w = cb.width, .y = span.y, .h = span.height } };
            pi += 1;
        }
        for (stacks[ci].dividers, 0..) |span, row| {
            dividers[di] = .{ .col = ci, .row = row, .box = .{ .x = cb.x, .w = cb.width, .y = span.y, .h = span.height } };
            di += 1;
        }
    }
    return .{ .strip = strip, .panes = panes, .dividers = dividers, .stacks = stacks, .viewport_h = strip_h, .scrollbar = scrollbar };
}

/// app.js scrollStripTo's clamp, against an extent that a running layout
/// animation may hold open (`keeper`, the old scroll width).
pub fn clampScroll(geom: *const Geometry, keeper: ?f64, target: f64) f64 {
    var max = geom.strip.max_scroll;
    if (keeper) |k| max = @max(max, @round(k) - geom.strip.viewport);
    return @max(0, @min(@round(target), max));
}

/// The largest scroll offset the strip allows right now.
pub fn maxScroll(geom: *const Geometry, keeper: ?f64) f64 {
    var max = geom.strip.max_scroll;
    if (keeper) |k| max = @max(max, @round(k) - geom.strip.viewport);
    return @max(0, max);
}

// ---------------------------------------------------------------------------

test "geometry of a stack and a lone column" {
    const t = std.testing;
    var l: layout.Layout = .init(t.allocator);
    defer l.deinit();
    try l.newTerminal("a");
    try l.newTerminalBelow("b");
    try l.newTerminal("c");
    var g = try compute(t.allocator, l.columns.items, 1920, 1200, 8, .{});
    defer g.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), g.panes.len);
    try t.expectEqual(@as(usize, 1), g.dividers.len);
    // px(90) = 720 + 24 = 744; inner 1908 → fit 2, share 951; max px(200)=1624.
    try t.expectEqual(@as(usize, 2), g.strip.widths.fit);
    try t.expectEqual(@as(f64, 951), g.strip.widths.min);
    // Two columns grow to share the strip: (1908 - 6) / 2 = 951 each.
    try t.expectEqual(@as(f64, 951), g.panes[0].box.w);
    try t.expectEqual(@as(f64, 6), g.panes[0].box.x);
    try t.expectEqual(@as(f64, 963), g.panes[2].box.x);
    // Stack: column height 1188, one gap 8 → panes 590 each.
    try t.expectEqual(@as(f64, 6), g.panes[0].box.y);
    try t.expectEqual(@as(f64, 590), g.panes[0].box.h);
    try t.expectEqual(@as(f64, 597), g.dividers[0].box.y);
    try t.expectEqual(@as(f64, 604), g.panes[1].box.y);
    try t.expectEqual(@as(f64, 1194), g.panes[1].box.bottom());
    try t.expect(!g.scrollbar);
}

test "overflow scrolls and the clamp honours a keeper" {
    const t = std.testing;
    var l: layout.Layout = .init(t.allocator);
    defer l.deinit();
    for ([_][]const u8{ "a", "b", "c", "d" }) |id| try l.newTerminal(id);
    var g = try compute(t.allocator, l.columns.items, 1000, 800, 8, .{});
    defer g.deinit(t.allocator);
    try t.expect(g.strip.overflows);
    // fit 1 at 988 inner: each column 988 wide; 4 columns + 3 gaps + pads.
    try t.expectEqual(@as(f64, 988 * 4 + 18 + 12), g.strip.scroll_width);
    try t.expectEqual(@as(f64, 2982), clampScroll(&g, null, 1e9));
    // The scrollbar takes 10 px of the height: 800 - 10 - 2 * 6.
    try t.expect(g.scrollbar);
    try t.expectEqual(@as(f64, 778), g.panes[0].box.h);
    try t.expectEqual(@as(f64, 4000), clampScroll(&g, 5000, 1e9));
    try t.expectEqual(@as(f64, 0), clampScroll(&g, null, -5));
}
