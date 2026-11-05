//! The width rule and the strip's geometry, as pure functions of the
//! viewport, the cell width, the per-pane chrome and the min/max terminal
//! width settings. Port of app.js `columnWidths` / `applyColumnWidths`, of
//! the stylesheet that turns its two numbers into boxes (index.html:
//! `#layout` is a flex row with `gap: 6px; padding: 6px;
//! justify-content: safe center`, `.column` is `flex: 1 0 min(--col-min,
//! 100%); max-width: --col-max`, `.column.full` is `flex-basis: 100%;
//! max-width: 100%`), and of `revealFocusedNow` / `scrollStripTo` /
//! `chaseStripEnd`.
//!
//! Coordinates are in "strip space": x from the strip's left edge,
//! unscrolled (what app.js reads as `offsetLeft`); y from its top edge.
//! What the browser rounds (offsetLeft, scrollWidth) is kept fractional
//! here except where app.js rounds explicitly (the scroll target).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The CSS constants the arithmetic depends on (index.html, app.js).
pub const Metrics = struct {
    /// Horizontal pixels a pane spends beyond its cells. app.js
    /// PANE_CHROME_PX: pane border (2) + term-holder padding (8) + xterm's
    /// scrollbar (10) + rounding slack (4). The native pane passes its own.
    pane_chrome_px: f64 = 2 + 8 + 10 + 4,
    /// `#layout` padding, on all four sides (STRIP_PAD_PX).
    strip_pad_px: f64 = 6,
    /// `#layout` gap between columns (COL_GAP_PX).
    col_gap_px: f64 = 6,
    /// `.divider` height.
    divider_px: f64 = 6,
    /// `.divider` margin, above and below.
    divider_margin_px: f64 = 1,
    /// A stacked pane's fixed height that its flex weight does not share:
    /// `.pane`'s 1 px top and bottom border (its basis is 0, so the border
    /// box starts at the border and the free space is shared on top).
    pane_border_px: f64 = 2,

    /// Pane-to-pane distance in a stack (app.js STACK_GAP_PX = 8).
    pub fn stackGap(self: Metrics) f64 {
        return self.divider_px + 2 * self.divider_margin_px;
    }
};

/// settings.js: the two width settings in terminal cells, defaults 90 and
/// 200, each clamped to 40…400 and max never below min.
pub const Settings = struct {
    min_cols: u32 = 90,
    max_cols: u32 = 200,

    pub const lowest: u32 = 40;
    pub const highest: u32 = 400;

    /// settings.js `sanitize` for these two fields (already integers here).
    pub fn sanitized(self: Settings) Settings {
        const min = std.math.clamp(self.min_cols, lowest, highest);
        const max = @max(min, std.math.clamp(self.max_cols, lowest, highest));
        return .{ .min_cols = min, .max_cols = max };
    }
};

pub const ColumnWidths = struct {
    /// How many columns fit side by side at the minimum: the most the
    /// strip ever shows whole at once.
    fit: usize,
    /// `--col-min`: the width of a column when the strip is full (the
    /// strip's width split `fit` ways, at least the cell minimum, at most
    /// `max`). Integer pixels.
    min: f64,
    /// `--col-max`: the widest a column grows when fewer than `fit` share
    /// the strip. Integer pixels when the cell width times max_cols rounds so.
    max: f64,
};

/// app.js `columnWidths(stripWidth, cellPx, minCols, maxCols)`, same float
/// operations in the same order, so the same results bit for bit.
pub fn columnWidths(strip_width: f64, cell_px: f64, settings: Settings, m: Metrics) ColumnWidths {
    const cells = struct {
        fn px(cols: u32, cell: f64, chrome: f64) f64 {
            return @ceil(@as(f64, @floatFromInt(cols)) * cell) + chrome;
        }
    };
    const min = cells.px(settings.min_cols, cell_px, m.pane_chrome_px);
    const max = @max(min, cells.px(settings.max_cols, cell_px, m.pane_chrome_px));
    const inner = strip_width - 2 * m.strip_pad_px;
    const fit_f = @max(1, @floor((inner + m.col_gap_px) / (min + m.col_gap_px)));
    const fit: usize = if (std.math.isFinite(fit_f) and fit_f < 1e9) @intFromFloat(fit_f) else 1;
    const share = @floor((inner - @as(f64, @floatFromInt(fit - 1)) * m.col_gap_px) / @as(f64, @floatFromInt(fit)));
    return .{ .fit = fit, .min = @min(max, @max(min, share)), .max = max };
}

pub const ColumnBox = struct {
    x: f64,
    width: f64,

    pub fn right(self: ColumnBox) f64 {
        return self.x + self.width;
    }
};

pub const StripGeometry = struct {
    widths: ColumnWidths,
    viewport: f64,
    /// One per column, in order.
    columns: []ColumnBox,
    /// The strip's scrollable width (`scrollWidth`): the last column's right
    /// edge plus the end padding, never less than the viewport.
    scroll_width: f64,
    /// Largest scroll offset (`scrollWidth - clientWidth`), rounded as the
    /// browser's integer scrollWidth is.
    max_scroll: f64,
    /// Whether the columns overflow the viewport (the strip scrolls).
    overflows: bool,
    /// The strip padding the geometry was laid out with (app.js
    /// revealFocusedNow's `pad`, chaseStripEnd's STRIP_PAD_PX).
    strip_pad: f64,

    pub fn deinit(self: *StripGeometry, gpa: Allocator) void {
        gpa.free(self.columns);
        self.* = undefined;
    }
};

/// Where every column goes. `columns` is a slice of anything with a `full`
/// field (`layout.columns.items`, `snapshot.columns`). This is the CSS flex
/// algorithm for the rule above: each column's base size is
/// `min(widths.min, inner)` (a full one: `inner`), with no shrink; when they
/// and their gaps leave free space, it is shared equally (flex-grow 1)
/// with each column capped at `widths.max` (a full one at `inner`), and
/// whatever is still left over centres the columns; when they overflow,
/// they keep their base size and start at the left padding (`safe center`).
pub fn stripGeometry(
    gpa: Allocator,
    columns: anytype,
    viewport: f64,
    cell_px: f64,
    settings: Settings,
    m: Metrics,
) Allocator.Error!StripGeometry {
    const widths = columnWidths(viewport, cell_px, settings, m);
    const n = columns.len;
    const boxes = try gpa.alloc(ColumnBox, n);
    errdefer gpa.free(boxes);
    const frozen = try gpa.alloc(bool, n);
    defer gpa.free(frozen);

    const inner = @max(0, viewport - 2 * m.strip_pad_px);
    const gaps = if (n > 0) @as(f64, @floatFromInt(n - 1)) * m.col_gap_px else 0;

    // Base sizes (= hypothetical sizes: min ≤ max, so the cap never bites).
    var used: f64 = gaps;
    for (columns, boxes) |c, *b| {
        b.width = if (c.full) inner else @min(widths.min, inner);
        used += b.width;
    }

    if (inner - used > 0) {
        // Grow: resolve flexible lengths with max-width violations frozen
        // (CSS Flexbox §9.7, every flex-grow 1, every min-width 0).
        const base = try gpa.alloc(f64, n);
        defer gpa.free(base);
        for (boxes, base) |b, *bs| bs.* = b.width;
        @memset(frozen, false);
        while (true) {
            var unfrozen: usize = 0;
            var space: f64 = inner - gaps;
            for (boxes, base, frozen) |b, bs, fz| {
                if (fz) space -= b.width else {
                    space -= bs;
                    unfrozen += 1;
                }
            }
            if (unfrozen == 0) break;
            const share = space / @as(f64, @floatFromInt(unfrozen));
            var violation: f64 = 0;
            for (columns, boxes, base, frozen) |c, *b, bs, fz| {
                if (fz) continue;
                const cap = if (c.full) inner else widths.max;
                const target = bs + share;
                b.width = @min(target, cap);
                violation += b.width - target;
            }
            if (violation >= 0) break; // no column hit its cap: done
            for (columns, base, frozen) |c, bs, *fz| {
                if (fz.*) continue;
                const cap = if (c.full) inner else widths.max;
                if (bs + share > cap) fz.* = true;
            }
        }
    }

    var total: f64 = gaps;
    for (boxes) |b| total += b.width;
    const leftover = inner - total;
    var x = m.strip_pad_px + @max(0, leftover / 2);
    for (boxes) |*b| {
        b.x = x;
        x += b.width + m.col_gap_px;
    }
    const content_end = if (n > 0) boxes[n - 1].right() + m.strip_pad_px else 0;
    const scroll_width = @max(viewport, content_end);
    return .{
        .widths = widths,
        .viewport = viewport,
        .columns = boxes,
        .scroll_width = scroll_width,
        .max_scroll = @max(0, @round(scroll_width) - viewport),
        .overflows = leftover < 0,
        .strip_pad = m.strip_pad_px,
    };
}

/// app.js `scrollStripTo`'s clamp: round, then keep within 0…max_scroll.
pub fn clampScroll(geom: *const StripGeometry, target: f64) f64 {
    return @max(0, @min(@round(target), geom.max_scroll));
}

/// app.js `revealFocusedNow`: the scroll offset that shows column `col` in
/// full (with the strip padding either side) moving the minimum distance
/// from `current` (the in-flight scroll target if the strip is already
/// animating, else the scroll offset), never re-centring a column already
/// on screen. Clamped like `scrollStripTo`.
pub fn revealTarget(geom: *const StripGeometry, col: usize, current: f64) f64 {
    if (col >= geom.columns.len) return clampScroll(geom, current);
    const box = geom.columns[col];
    const left = box.x - geom.strip_pad;
    const right = box.right() + geom.strip_pad;
    var target = current;
    if (left < target) {
        target = left;
    } else if (right > target + geom.viewport) {
        target = right - geom.viewport;
    }
    return clampScroll(geom, target);
}

/// app.js `chaseStripEnd`: after a structural change, a strip scrolled past
/// its new end eases back to it. Returns the new target, or null when
/// `scroll` is within range.
pub fn endChaseTarget(geom: *const StripGeometry, scroll: f64) ?f64 {
    if (geom.columns.len == 0) return null;
    const last = geom.columns[geom.columns.len - 1];
    const max = @max(0, last.right() + geom.strip_pad - geom.viewport);
    return if (scroll > max) clampScroll(geom, max) else null;
}

/// app.js SCROLL_TAU_MS: the strip's scroll chase time constant.
pub const scroll_tau_ms: f64 = 60;

pub const ChaseStep = struct {
    /// The new (fractional) scroll position; the strip shows it rounded.
    pos: f64,
    /// Arrived: `pos` is the target and the chase is over.
    done: bool,
};

/// One frame of app.js `chaseStep`: an exponential approach to `target`
/// (each frame covers 1 − e^(−dt/τ) of what is left, at least 1 px), `dt`
/// capped at 100 ms so a stalled frame does not teleport; within 0.5 px it
/// lands on the target and is done. A new target mid-flight just goes into
/// the next call.
pub fn chaseStep(pos: f64, target: f64, dt_ms: f64) ChaseStep {
    const dt = @min(dt_ms, 100);
    const diff = target - pos;
    if (@abs(diff) < 0.5) return .{ .pos = target, .done = true };
    const k = 1 - @exp(-dt / scroll_tau_ms);
    const sign: f64 = if (diff > 0) 1 else -1;
    return .{ .pos = pos + sign * @max(@abs(diff) * k, @min(1, @abs(diff))), .done = false };
}

// ---------------------------------------------------------------------------
// Stacks
// ---------------------------------------------------------------------------

pub const Span = struct {
    y: f64,
    height: f64,

    pub fn bottom(self: Span) f64 {
        return self.y + self.height;
    }
};

pub const StackGeometry = struct {
    /// One per pane, top to bottom.
    panes: []Span,
    /// One per divider: divider i sits between panes i and i+1.
    dividers: []Span,

    pub fn deinit(self: *StackGeometry, gpa: Allocator) void {
        gpa.free(self.panes);
        gpa.free(self.dividers);
        self.* = undefined;
    }

    /// `span_px` for `Layout.dragDivider`: from the top of pane i to the
    /// bottom of pane i+1.
    pub fn dividerSpan(self: *const StackGeometry, i: usize) f64 {
        return self.panes[i + 1].bottom() - self.panes[i].y;
    }

    /// `offset_px` for `Layout.dragDivider` from a pointer y in strip space.
    pub fn dividerOffset(self: *const StackGeometry, i: usize, pointer_y: f64) f64 {
        return pointer_y - self.panes[i].y;
    }
};

/// Heights within a column: the column fills the strip's height minus its
/// padding; dividers take `stackGap` each; every pane has its border, and
/// the panes share what is left by their weights, normalised (app.js
/// paneFlex: `flex: w/sum 1 0`). A column too short for that leaves each
/// pane at its border (no shrink below it; the overflow is clipped).
/// `strip_height` is the strip's height less any horizontal scrollbar that
/// takes room (Chromium's classic scrollbar takes 15 px when the strip
/// overflows; an overlay scrollbar takes none).
pub fn stackGeometry(gpa: Allocator, sizes: []const f64, strip_height: f64, m: Metrics) Allocator.Error!StackGeometry {
    const n = sizes.len;
    const panes = try gpa.alloc(Span, n);
    errdefer gpa.free(panes);
    const dividers = try gpa.alloc(Span, if (n > 0) n - 1 else 0);
    errdefer gpa.free(dividers);

    var sum: f64 = 0;
    for (sizes) |w| sum += w;
    if (sum == 0) sum = 1;
    const col_height = @max(0, strip_height - 2 * m.strip_pad_px);
    const fixed = @as(f64, @floatFromInt(dividers.len)) * m.stackGap() + @as(f64, @floatFromInt(n)) * m.pane_border_px;
    const free = @max(0, col_height - fixed);
    var y = m.strip_pad_px;
    for (sizes, panes, 0..) |w, *p, i| {
        p.* = .{ .y = y, .height = m.pane_border_px + free * (w / sum) };
        y = p.bottom();
        if (i + 1 < n) {
            dividers[i] = .{ .y = y + m.divider_margin_px, .height = m.divider_px };
            y += m.stackGap();
        }
    }
    return .{ .panes = panes, .dividers = dividers };
}
