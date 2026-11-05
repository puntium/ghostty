//! Width rule and geometry tests.
//!
//! Where the numbers come from:
//! - `columnWidths` cases: app.js `columnWidths` run under node with these
//!   inputs (the function verbatim, with PANE_CHROME_PX / STRIP_PAD_PX /
//!   COL_GAP_PX).
//! - `stripGeometry` / `stackGeometry` cases: headless Chrome laying out
//!   index.html's `#layout` / `.column` / `.pane` / `.divider` rules with
//!   `--col-min` / `--col-max` set from that same `columnWidths`, measured
//!   with getBoundingClientRect and scrollWidth. Chrome lays out in 1/64 px
//!   units, hence the 0.02 px tolerance on fractional widths. Where the
//!   strip overflowed, Chrome's classic horizontal scrollbar took 15 px of
//!   height, so those stack cases pass the strip height minus 15.

const std = @import("std");
const t = std.testing;
const width = @import("width.zig");
const Layout = @import("Layout.zig");
const testing = @import("testing.zig");
const gpa = testing.gpa;

const m: width.Metrics = .{};
const tol = 0.02;

fn settings(min: u32, max: u32) width.Settings {
    return .{ .min_cols = min, .max_cols = max };
}

test "columnWidths: app.js values" {
    const Case = struct { w: f64, cell: f64, min: u32, max: u32, fit: usize, cmin: f64, cmax: f64 };
    const cases = [_]Case{
        .{ .w = 1920, .cell = 7.8, .min = 90, .max = 200, .fit = 2, .cmin = 951, .cmax = 1584 },
        .{ .w = 3840, .cell = 8, .min = 90, .max = 200, .fit = 5, .cmin = 760, .cmax = 1624 },
        .{ .w = 500, .cell = 8, .min = 90, .max = 200, .fit = 1, .cmin = 744, .cmax = 1624 },
        .{ .w = 2560, .cell = 7.8125, .min = 90, .max = 200, .fit = 3, .cmin = 845, .cmax = 1587 },
        .{ .w = 1920, .cell = 8, .min = 100, .max = 100, .fit = 2, .cmin = 824, .cmax = 824 },
        .{ .w = 1920, .cell = 7.1, .min = 90, .max = 200, .fit = 2, .cmin = 951, .cmax = 1444 },
        .{ .w = 1920, .cell = 8.4, .min = 90, .max = 200, .fit = 2, .cmin = 951, .cmax = 1704 },
        .{ .w = 2560, .cell = 9.6, .min = 80, .max = 120, .fit = 3, .cmin = 845, .cmax = 1176 },
        .{ .w = 1366, .cell = 7.7, .min = 90, .max = 200, .fit = 1, .cmin = 1354, .cmax = 1564 },
        .{ .w = 1000, .cell = 8, .min = 40, .max = 40, .fit = 2, .cmin = 344, .cmax = 344 },
        .{ .w = 3840, .cell = 7.2, .min = 40, .max = 400, .fit = 12, .cmin = 313, .cmax = 2904 },
        // Narrower than one minimum column, down to nothing.
        .{ .w = 100, .cell = 8, .min = 90, .max = 200, .fit = 1, .cmin = 744, .cmax = 1624 },
        .{ .w = 0, .cell = 8, .min = 90, .max = 200, .fit = 1, .cmin = 744, .cmax = 1624 },
        // The step from one column to two: 2·744 + gap + 2·pad = 1506.
        .{ .w = 1505, .cell = 8, .min = 90, .max = 200, .fit = 1, .cmin = 1493, .cmax = 1624 },
        .{ .w = 1506, .cell = 8, .min = 90, .max = 200, .fit = 2, .cmin = 744, .cmax = 1624 },
    };
    for (cases) |c| {
        const got = width.columnWidths(c.w, c.cell, settings(c.min, c.max), m);
        t.expectEqual(c.fit, got.fit) catch |e| {
            std.debug.print("case {any}\n", .{c});
            return e;
        };
        try t.expectEqual(c.cmin, got.min);
        try t.expectEqual(c.cmax, got.max);
    }
}

test "Settings.sanitized: clamped to 40…400, max never below min" {
    try t.expectEqual(settings(40, 40), settings(30, 20).sanitized());
    try t.expectEqual(settings(400, 400), settings(500, 450).sanitized());
    try t.expectEqual(settings(100, 100), settings(100, 90).sanitized());
    try t.expectEqual(settings(90, 200), (width.Settings{}).sanitized());
}

const Col = struct { full: bool = false };

fn geometry(viewport: f64, cell: f64, s: width.Settings, cols: []const Col) !width.StripGeometry {
    return width.stripGeometry(gpa, cols, viewport, cell, s, m);
}

fn expectBoxes(g: *const width.StripGeometry, xs: []const f64, ws: []const f64) !void {
    try t.expectEqual(xs.len, g.columns.len);
    for (g.columns, xs, ws) |b, x, w| {
        try t.expectApproxEqAbs(x, b.x, tol);
        try t.expectApproxEqAbs(w, b.width, tol);
    }
}

const one = [_]Col{.{}};
const two = [_]Col{ .{}, .{} };
const three = [_]Col{ .{}, .{}, .{} };
const five: [5]Col = @splat(.{});
const six: [6]Col = @splat(.{});

test "stripGeometry 1920 px, 7.8 px cells (two fit)" {
    const s = settings(90, 200);
    {
        // One column grows to the maximum and sits centred.
        var g = try geometry(1920, 7.8, s, &one);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{168}, &.{1584});
        try t.expectEqual(@as(f64, 1920), g.scroll_width);
        try t.expectEqual(@as(f64, 0), g.max_scroll);
        try t.expect(!g.overflows);
    }
    {
        var g = try geometry(1920, 7.8, s, &two);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 963 }, &.{ 951, 951 });
        try t.expectEqual(@as(f64, 0), g.max_scroll);
    }
    {
        // More than fit: minimum width, start-aligned, scrolls.
        var g = try geometry(1920, 7.8, s, &three);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 963, 1920 }, &.{ 951, 951, 951 });
        try t.expectEqual(@as(f64, 2877), g.scroll_width);
        try t.expectEqual(@as(f64, 957), g.max_scroll);
        try t.expect(g.overflows);
    }
    {
        var g = try geometry(1920, 7.8, s, &.{Col{ .full = true }});
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{6}, &.{1908});
        try t.expectEqual(@as(f64, 1920), g.scroll_width);
    }
    {
        var g = try geometry(1920, 7.8, s, &.{ Col{ .full = true }, Col{} });
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 1920 }, &.{ 1908, 951 });
        try t.expectEqual(@as(f64, 2877), g.scroll_width);
    }
    {
        var g = try geometry(1920, 7.8, s, &.{ Col{}, Col{ .full = true }, Col{} });
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 963, 2877 }, &.{ 951, 1908, 951 });
        try t.expectEqual(@as(f64, 3834), g.scroll_width);
        try t.expectEqual(@as(f64, 1914), g.max_scroll);
    }
}

test "stripGeometry 3840 px, 8 px cells (five fit)" {
    const s = settings(90, 200);
    {
        var g = try geometry(3840, 8, s, &one);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{1108}, &.{1624});
    }
    {
        // Two grow to the maximum; the rest centres them.
        var g = try geometry(3840, 8, s, &two);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 293, 1923 }, &.{ 1624, 1624 });
    }
    {
        // Three share the strip below the maximum: no centring offset.
        var g = try geometry(3840, 8, s, &three);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 1284, 2562 }, &.{ 1272, 1272, 1272 });
    }
    {
        // Five: the floor in columnWidths leaves 4 px, shared by flex-grow.
        var g = try geometry(3840, 8, s, &five);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 772.8, 1539.6, 2306.4, 3073.2 }, &.{ 760.8, 760.8, 760.8, 760.8, 760.8 });
        try t.expectEqual(@as(f64, 0), g.max_scroll);
    }
    {
        var g = try geometry(3840, 8, s, &six);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 772, 1538, 2304, 3070, 3836 }, &.{ 760, 760, 760, 760, 760, 760 });
        try t.expectEqual(@as(f64, 4602), g.scroll_width);
        try t.expectEqual(@as(f64, 762), g.max_scroll);
    }
}

test "stripGeometry: a window narrower than one minimum column" {
    const s = settings(90, 200);
    {
        var g = try geometry(500, 8, s, &one);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{6}, &.{488});
        try t.expect(!g.overflows);
    }
    {
        var g = try geometry(500, 8, s, &two);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 500 }, &.{ 488, 488 });
        try t.expectEqual(@as(f64, 994), g.scroll_width);
    }
    {
        // Degenerate viewport: nothing negative.
        var g = try geometry(4, 8, s, &two);
        defer g.deinit(gpa);
        for (g.columns) |b| try t.expect(b.width >= 0);
    }
}

test "stripGeometry 2560 px, 7.8125 px cells (fractional share)" {
    const s = settings(90, 200);
    {
        var g = try geometry(2560, 7.8125, s, &one);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{486.5}, &.{1587});
    }
    {
        var g = try geometry(2560, 7.8125, s, &two);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 1283 }, &.{ 1271, 1271 });
    }
    {
        var g = try geometry(2560, 7.8125, s, &three);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 6, 857.333, 1708.667 }, &.{ 845.333, 845.333, 845.333 });
    }
}

test "stripGeometry: min = max, columns stay at it and centre" {
    const s = settings(100, 100);
    {
        var g = try geometry(1920, 8, s, &two);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{ 133, 963 }, &.{ 824, 824 });
    }
    {
        var g = try geometry(1920, 8, s, &one);
        defer g.deinit(gpa);
        try expectBoxes(&g, &.{548}, &.{824});
    }
}

test "stripGeometry: empty strip, and a layout's own columns" {
    var g = try geometry(1920, 8, .{}, &.{});
    defer g.deinit(gpa);
    try t.expectEqual(@as(usize, 0), g.columns.len);
    try t.expectEqual(@as(f64, 0), g.max_scroll);

    var l = try testing.build("a|!b*|c");
    defer l.deinit();
    var h = try width.stripGeometry(gpa, l.columns.items, 1920, 7.8, .{}, m);
    defer h.deinit(gpa);
    try expectBoxes(&h, &.{ 6, 963, 2877 }, &.{ 951, 1908, 951 });
}

test "stripGeometry: other metrics (a native pane's chrome)" {
    const mm: width.Metrics = .{ .pane_chrome_px = 16, .strip_pad_px = 4, .col_gap_px = 8 };
    // min = ceil(90·8)+16 = 736, max = 1616, inner = 1912;
    // fit = floor(1920/744) = 2; share = floor((1912−8)/2) = 952.
    var g = try width.stripGeometry(gpa, &two, 1920, 8, .{}, mm);
    defer g.deinit(gpa);
    try t.expectEqual(@as(usize, 2), g.widths.fit);
    try t.expectEqual(@as(f64, 952), g.widths.min);
    try t.expectEqual(@as(f64, 1616), g.widths.max);
    try expectBoxes(&g, &.{ 4, 964 }, &.{ 952, 952 });
}

// ---------------------------------------------------------------------------
// Scroll targets (app.js revealFocusedNow / scrollStripTo / chaseStripEnd)
// ---------------------------------------------------------------------------

test "revealTarget: minimum movement, never re-centring a visible column" {
    // Six 760 px columns in 3840 px: x = 6 + 766·i, max scroll 762.
    var g = try geometry(3840, 8, .{}, &six);
    defer g.deinit(gpa);
    // Last column from the start: its right edge + pad (4602) to the right edge.
    try t.expectEqual(@as(f64, 762), width.revealTarget(&g, 5, 0));
    // First column from the end: its left edge − pad (0).
    try t.expectEqual(@as(f64, 0), width.revealTarget(&g, 0, 762));
    // Already fully visible: stays.
    try t.expectEqual(@as(f64, 762), width.revealTarget(&g, 2, 762));
    try t.expectEqual(@as(f64, 0), width.revealTarget(&g, 4, 0));
    // Partly visible on the right: just enough.
    try t.expectEqual(@as(f64, 762), width.revealTarget(&g, 5, 100));
    // Partly visible on the left: just enough. Four 951 px columns in
    // 1920 px (x = 6 + 957·i, max scroll 1914): column 1 from 1000 → 957.
    const four: [4]Col = @splat(.{});
    var h = try geometry(1920, 7.8, .{}, &four);
    defer h.deinit(gpa);
    try t.expectEqual(@as(f64, 1914), h.max_scroll);
    try t.expectEqual(@as(f64, 957), width.revealTarget(&h, 1, 1000));
    try t.expectEqual(@as(f64, 1000), width.revealTarget(&h, 2, 1000)); // 1914…2877 within 1000…2920
    // Fractional current: scrollStripTo rounds.
    try t.expectEqual(@as(f64, 300), width.revealTarget(&g, 2, 300.4));
    // Out-of-range column: just the clamp.
    try t.expectEqual(@as(f64, 762), width.revealTarget(&g, 9, 5000));
}

test "revealTarget: 1920 px, three 951 px columns, and a full one" {
    var g = try geometry(1920, 7.8, .{}, &three);
    defer g.deinit(gpa);
    try t.expectEqual(@as(f64, 957), width.revealTarget(&g, 2, 0));
    try t.expectEqual(@as(f64, 957), width.revealTarget(&g, 1, 957));
    try t.expectEqual(@as(f64, 0), width.revealTarget(&g, 1, 0));
    try t.expectEqual(@as(f64, 0), width.revealTarget(&g, 0, 957));
    var f = try geometry(1920, 7.8, .{}, &.{ Col{}, Col{ .full = true }, Col{} });
    defer f.deinit(gpa);
    // The full column fills the viewport exactly once revealed.
    try t.expectEqual(@as(f64, 957), width.revealTarget(&f, 1, 0));
    try t.expectEqual(@as(f64, 957), width.revealTarget(&f, 1, 1914));
    try t.expectEqual(@as(f64, 1914), width.revealTarget(&f, 2, 957));
}

test "revealTarget: columns that fit never scroll" {
    var g = try geometry(1920, 7.8, .{}, &two);
    defer g.deinit(gpa);
    try t.expectEqual(@as(f64, 0), width.revealTarget(&g, 1, 0));
    try t.expectEqual(@as(f64, 0), width.revealTarget(&g, 0, 500)); // stale offset clamps
}

test "endChaseTarget: a strip scrolled past its new end eases back" {
    var g = try geometry(1920, 7.8, .{}, &two);
    defer g.deinit(gpa);
    try t.expectEqual(@as(?f64, 0), width.endChaseTarget(&g, 957));
    var h = try geometry(1920, 7.8, .{}, &three);
    defer h.deinit(gpa);
    try t.expectEqual(@as(?f64, null), width.endChaseTarget(&h, 900));
    try t.expectEqual(@as(?f64, 957), width.endChaseTarget(&h, 1200));
    var e = try geometry(1920, 7.8, .{}, &.{});
    defer e.deinit(gpa);
    try t.expectEqual(@as(?f64, null), width.endChaseTarget(&e, 50));
}

test "chaseStep: app.js values (node)" {
    const Case = struct { pos: f64, target: f64, dt: f64, want: f64, done: bool };
    const cases = [_]Case{
        .{ .pos = 0, .target = 957, .dt = 16, .want = 224.0065801850312, .done = false },
        .{ .pos = 0, .target = 957, .dt = 1000, .want = 776.2460480844534, .done = false }, // dt capped at 100
        .{ .pos = 957, .target = 0, .dt = 16, .want = 732.9934198149688, .done = false },
        .{ .pos = 100, .target = 100.4, .dt = 16, .want = 100.4, .done = true },
        .{ .pos = 100, .target = 100.6, .dt = 0, .want = 100.6, .done = false }, // the 1 px floor, capped at the distance
        .{ .pos = 100, .target = 99, .dt = 0, .want = 99, .done = false },
        .{ .pos = 0, .target = 1000, .dt = 16.6667, .want = 242.53529241687687, .done = false },
    };
    for (cases) |c| {
        const r = width.chaseStep(c.pos, c.target, c.dt);
        try t.expectApproxEqAbs(c.want, r.pos, 1e-9);
        try t.expectEqual(c.done, r.done);
    }
    // 0 → 957 at 16 ms frames: done on the 26th call (node).
    var pos: f64 = 0;
    var frames: usize = 0;
    while (true) {
        const r = width.chaseStep(pos, 957, 16);
        frames += 1;
        pos = r.pos;
        if (r.done) break;
    }
    try t.expectEqual(@as(usize, 26), frames);
    try t.expectEqual(@as(f64, 957), pos);
}

test "clampScroll" {
    var g = try geometry(1920, 7.8, .{}, &three);
    defer g.deinit(gpa);
    try t.expectEqual(@as(f64, 0), width.clampScroll(&g, -40));
    try t.expectEqual(@as(f64, 957), width.clampScroll(&g, 4000));
    try t.expectEqual(@as(f64, 13), width.clampScroll(&g, 12.5));
}

// ---------------------------------------------------------------------------
// Stacks
// ---------------------------------------------------------------------------

fn expectSpans(got: []const width.Span, want: []const [2]f64) !void {
    try t.expectEqual(want.len, got.len);
    for (got, want) |g, w| {
        try t.expectApproxEqAbs(w[0], g.y, tol);
        try t.expectApproxEqAbs(w[1], g.height, tol);
    }
}

test "stackGeometry: Chrome's pane and divider boxes" {
    // 600 px strip that overflowed (15 px scrollbar): column 573 px.
    {
        var s = try width.stackGeometry(gpa, &.{ 1, 1 }, 585, m);
        defer s.deinit(gpa);
        try expectSpans(s.panes, &.{ .{ 6, 282.5 }, .{ 296.5, 282.5 } });
        try expectSpans(s.dividers, &.{.{ 289.5, 6 }});
    }
    {
        var s = try width.stackGeometry(gpa, &.{ 1, 2, 3 }, 585, m);
        defer s.deinit(gpa);
        try expectSpans(s.panes, &.{ .{ 6, 93.828 }, .{ 107.828, 185.672 }, .{ 301.5, 277.5 } });
        try expectSpans(s.dividers, &.{ .{ 100.828, 6 }, .{ 294.5, 6 } });
    }
    {
        // A lone survivor of a resized stack fills its column (normalised).
        var s = try width.stackGeometry(gpa, &.{0.3}, 585, m);
        defer s.deinit(gpa);
        try expectSpans(s.panes, &.{.{ 6, 573 }});
        try t.expectEqual(@as(usize, 0), s.dividers.len);
    }
    {
        var s = try width.stackGeometry(gpa, &.{ 0.25, 0.5, 1, 0.25 }, 900, m);
        defer s.deinit(gpa);
        try expectSpans(s.panes, &.{ .{ 6, 109 }, .{ 123, 216 }, .{ 347, 430 }, .{ 785, 109 } });
        try expectSpans(s.dividers, &.{ .{ 116, 6 }, .{ 340, 6 }, .{ 778, 6 } });
        // dragDivider inputs: span of divider 1 = pane 1 top → pane 2 bottom.
        try t.expectApproxEqAbs(@as(f64, 777 - 123), s.dividerSpan(1), tol);
        try t.expectApproxEqAbs(@as(f64, 200), s.dividerOffset(1, 323), tol);
    }
    {
        // Too short for its dividers: panes keep their borders, no more.
        var s = try width.stackGeometry(gpa, &.{ 1, 1, 1 }, 30, m);
        defer s.deinit(gpa);
        try expectSpans(s.panes, &.{ .{ 6, 2 }, .{ 16, 2 }, .{ 26, 2 } });
        try expectSpans(s.dividers, &.{ .{ 9, 6 }, .{ 19, 6 } });
    }
}

test "stackGeometry drives dragDivider like app.js makeDivider" {
    var l = try testing.build("a,b*");
    defer l.deinit();
    var s = try width.stackGeometry(gpa, l.columns.items[0].sizes.items, 600, m);
    defer s.deinit(gpa);
    // Column 588: panes (588 − 8 − 4)/2 + 2 = 290 each; span = 588.
    try t.expectApproxEqAbs(@as(f64, 588), s.dividerSpan(0), tol);
    // Pointer at y = 6 + 147 → ratio 0.25 of the pair's weight 2.
    try t.expect(l.dragDivider(0, 0, s.dividerOffset(0, 153), s.dividerSpan(0), Layout.min_pane_px));
    try testing.expectSizes(&l, 0, &.{ 0.5, 1.5 });
}
