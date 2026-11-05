//! The strip's animation arithmetic, pure (no GTK): port of the
//! layout-animation half of electron/ui/app.js (`moveEase`, `stripRect`'s
//! mid-flight box, `animateStrip`'s `entryRect` and exit cuts). The widget
//! (workspace.zig) measures boxes and feeds them here; everything it draws
//! per frame is a translation, a clip and an opacity computed from these.
//!
//! Boxes are in strip space: x from the strip's left edge, unscrolled; y
//! from its top edge (`layout.width` coordinates).
const std = @import("std");
const layout = @import("../../../webmux/layout.zig");

/// app.js MOVE_MS: every structural move.
pub const move_ms: f64 = 200;
/// app.js: the timeout that ends an animation whose end event never came.
pub const settle_ms: f64 = move_ms + 50;
/// CSS `transition: opacity 0.12s` on the unfocused fade.
pub const fade_ms: f64 = 120;
/// app.js STACK_GAP_PX: divider + its margins, pane to pane in a stack.
pub const stack_gap: f64 = 8;
/// app.js COL_GAP_PX.
pub const col_gap: f64 = 6;
/// `.pane` / `.divider` border radius.
pub const pane_radius: f64 = 8;
pub const divider_radius: f64 = 3;

pub const Box = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn right(self: Box) f64 {
        return self.x + self.w;
    }
    pub fn bottom(self: Box) f64 {
        return self.y + self.h;
    }
    pub fn contains(self: Box, px: f64, py: f64) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }
    pub fn eql(a: Box, b: Box) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
    pub fn lerp(a: Box, b: Box, p: f64) Box {
        return .{
            .x = a.x + (b.x - a.x) * p,
            .y = a.y + (b.y - a.y) * p,
            .w = a.w + (b.w - a.w) * p,
            .h = a.h + (b.h - a.h) * p,
        };
    }
    /// Snap to whole pixels by rounding each edge (so neighbours that
    /// touch in fractional space still touch).
    pub fn snapped(self: Box) Box {
        const x0 = @round(self.x);
        const y0 = @round(self.y);
        return .{ .x = x0, .y = y0, .w = @max(0, @round(self.x + self.w) - x0), .h = @max(0, @round(self.y + self.h) - y0) };
    }
};

/// y of a CSS cubic-bezier(x1, y1, x2, y2) at time fraction x, by
/// bisection on the curve's x (app.js moveEase: 20 steps, a pixel's
/// accuracy over a 200 ms move).
pub fn bezier(x: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    const S = struct {
        fn coord(t: f64, a: f64, b: f64) f64 {
            const u = 1 - t;
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
        }
    };
    var lo: f64 = 0;
    var hi: f64 = 1;
    for (0..20) |_| {
        const mid = (lo + hi) / 2;
        if (S.coord(mid, x1, x2) < x) lo = mid else hi = mid;
    }
    return S.coord((lo + hi) / 2, y1, y2);
}

/// app.js MOVE_EASE, cubic-bezier(0.4, 0, 0.2, 1).
pub fn moveEase(x: f64) f64 {
    return bezier(x, 0.4, 0, 0.2, 1);
}

/// CSS `ease` (the default transition timing function), for the fade.
pub fn cssEase(x: f64) f64 {
    return bezier(x, 0.25, 0.1, 0.25, 1);
}

/// One element's move: from its old box to its final one. `at(p)` is the
/// box the eye sees at eased progress p (app.js stripRect mid-flight: the
/// transform moves the origin, the clip sets the size).
pub const Flight = struct {
    from: Box,
    to: Box,
    /// It had no old box (a new pane): it also fades in.
    fresh: bool = false,

    pub fn at(self: Flight, p: f64) Box {
        return Box.lerp(self.from, self.to, p);
    }
    /// The element is larger than where it starts in some dimension: it is
    /// revealed by a clip from its old size up.
    pub fn grows(self: Flight) bool {
        return self.from.w < self.to.w or self.from.h < self.to.h;
    }
    /// It is smaller than where it starts in some dimension: a ghost of its
    /// shell, under it, covers the part of the old box it no longer has.
    pub fn shrinks(self: Flight) bool {
        return self.from.w > self.to.w or self.from.h > self.to.h;
    }
    /// The ghost's box: at the final top-left, the larger of both sizes.
    pub fn ghostBox(self: Flight) Box {
        return .{ .x = self.to.x, .y = self.to.y, .w = @max(self.from.w, self.to.w), .h = @max(self.from.h, self.to.h) };
    }
};

/// What a new element opens out of (app.js entryRect), from the change's
/// origin. `old_pane` gives an old pane's mid-flight box by its old slot,
/// `old_column` an old column's box. `kind` decides the gap: a pane opens
/// a stack gap below the pane above it, a divider its 1 px margin.
pub fn entryBox(
    origin: layout.change.Origin,
    is_pane: bool,
    to: Box,
    ctx: anytype,
) Box {
    const gap: f64 = if (is_pane) stack_gap else 1;
    switch (origin) {
        .moved => unreachable,
        .below => |n| if (ctx.oldPane(n.old)) |a| return .{ .x = a.x, .w = a.w, .y = a.bottom() + gap, .h = 0 },
        .above => |n| if (ctx.oldPane(n.old)) |b| return .{ .x = b.x, .w = b.w, .y = b.y - gap, .h = 0 },
        .after_column => |o| if (ctx.oldColumn(o)) |c| return .{ .x = c.right() + col_gap, .w = 0, .y = to.y, .h = to.h },
        .before_column => |o| if (ctx.oldColumn(o)) |c| return .{ .x = c.x - col_gap, .w = 0, .y = to.y, .h = to.h },
        .in_place => {},
    }
    return .{ .x = to.x, .y = to.y, .w = 0, .h = to.h };
}

/// The clip a leaving pane closes to, as insets from its old box (app.js
/// `cut`: top, right, bottom, left).
pub const Cut = struct {
    top: f64 = 0,
    right: f64 = 0,
    bottom: f64 = 0,
    left: f64 = 0,

    pub fn scaled(self: Cut, p: f64) Cut {
        return .{ .top = self.top * p, .right = self.right * p, .bottom = self.bottom * p, .left = self.left * p };
    }
};

/// A pane alone in its column is wiped from the right; a stacked one is
/// squeezed to the line where its neighbours meet: half a gap below the
/// final bottom of the pane above, else half a gap above the final top of
/// the pane below, else its own middle, clamped to its old box.
pub fn exitCut(from: Box, alone: bool, above_new: ?Box, below_new: ?Box) Cut {
    if (alone) return .{ .right = from.w };
    var meet = if (above_new) |a|
        a.bottom() + stack_gap / 2
    else if (below_new) |b|
        b.y - stack_gap / 2
    else
        from.y + from.h / 2;
    meet = @min(@max(meet, from.y), from.bottom());
    return .{ .top = meet - from.y, .bottom = from.bottom() - meet };
}

/// The visible part of a leaving pane at eased progress p, in strip space.
pub fn exitClip(from: Box, cut: Cut, p: f64) Box {
    const c = cut.scaled(p);
    return .{
        .x = from.x + c.left,
        .y = from.y + c.top,
        .w = @max(0, from.w - c.left - c.right),
        .h = @max(0, from.h - c.top - c.bottom),
    };
}

// ---------------------------------------------------------------------------

test "moveEase matches the CSS curve's ends and middle" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 0), moveEase(0));
    try t.expectEqual(@as(f64, 1), moveEase(1));
    // cubic-bezier(0.4,0,0.2,1) at x=0.5 is ~0.774 (Material standard).
    try t.expectApproxEqAbs(@as(f64, 0.7743), moveEase(0.5), 0.002);
    var prev: f64 = 0;
    var x: f64 = 0;
    while (x <= 1) : (x += 0.05) {
        const y = moveEase(x);
        try t.expect(y >= prev - 1e-9);
        prev = y;
    }
}

test "flight grows, shrinks, ghost box" {
    const t = std.testing;
    const f: Flight = .{ .from = .{ .x = 0, .y = 0, .w = 100, .h = 50 }, .to = .{ .x = 10, .y = 0, .w = 50, .h = 100 } };
    try t.expect(f.grows() and f.shrinks());
    try t.expect(Box.eql(f.ghostBox(), .{ .x = 10, .y = 0, .w = 100, .h = 100 }));
    try t.expect(Box.eql(f.at(0.5), .{ .x = 5, .y = 0, .w = 75, .h = 75 }));
}

test "entry boxes" {
    const t = std.testing;
    const Ctx = struct {
        fn oldPane(_: @This(), s: layout.change.Slot) ?Box {
            return if (s.col == 0) Box{ .x = 6, .y = 6, .w = 300, .h = 400 } else null;
        }
        fn oldColumn(_: @This(), i: usize) ?Box {
            return if (i == 0) Box{ .x = 6, .y = 6, .w = 300, .h = 800 } else null;
        }
    };
    const to: Box = .{ .x = 312, .y = 6, .w = 300, .h = 800 };
    const n: layout.change.Neighbour = .{ .id = "a", .old = .{ .col = 0, .row = 0 } };
    try t.expect(Box.eql(entryBox(.{ .below = n }, true, to, Ctx{}), .{ .x = 6, .y = 414, .w = 300, .h = 0 }));
    try t.expect(Box.eql(entryBox(.{ .below = n }, false, to, Ctx{}), .{ .x = 6, .y = 407, .w = 300, .h = 0 }));
    try t.expect(Box.eql(entryBox(.{ .above = n }, true, to, Ctx{}), .{ .x = 6, .y = -2, .w = 300, .h = 0 }));
    try t.expect(Box.eql(entryBox(.{ .after_column = 0 }, true, to, Ctx{}), .{ .x = 312, .y = 6, .w = 0, .h = 800 }));
    try t.expect(Box.eql(entryBox(.{ .before_column = 0 }, true, to, Ctx{}), .{ .x = 0, .y = 6, .w = 0, .h = 800 }));
    try t.expect(Box.eql(entryBox(.in_place, true, to, Ctx{}), .{ .x = 312, .y = 6, .w = 0, .h = 800 }));
}

test "exit cuts" {
    const t = std.testing;
    const from: Box = .{ .x = 6, .y = 200, .w = 300, .h = 100 };
    const alone = exitCut(from, true, null, null);
    try t.expectEqual(@as(f64, 300), alone.right);
    try t.expect(Box.eql(exitClip(from, alone, 1), .{ .x = 6, .y = 200, .w = 0, .h = 100 }));
    // Above survivor grew to bottom 250: meet at 254.
    const st = exitCut(from, false, .{ .x = 6, .y = 6, .w = 300, .h = 244 }, null);
    try t.expectEqual(@as(f64, 54), st.top);
    try t.expectEqual(@as(f64, 46), st.bottom);
    // No neighbours: the middle.
    const mid = exitCut(from, false, null, null);
    try t.expectEqual(@as(f64, 50), mid.top);
    // Clamped to the old box.
    const cl = exitCut(from, false, .{ .x = 6, .y = 6, .w = 300, .h = 900 }, null);
    try t.expectEqual(@as(f64, 100), cl.top);
    try t.expectEqual(@as(f64, 0), cl.bottom);
}

test "snapped keeps touching edges touching" {
    const t = std.testing;
    const a: Box = .{ .x = 6.4, .y = 0, .w = 100.3, .h = 10 };
    const b: Box = .{ .x = a.right(), .y = 0, .w = 50.6, .h = 10 };
    try t.expectEqual(a.snapped().right(), b.snapped().x);
}
