//! Terminal-pane helpers for links, Alt+click and the sticky-bottom band
//! (gtk/PARITY.md T-20, T-24, T-25, T-30). Pure functions over the core's
//! terminal state; the pane calls them with the renderer lock held where
//! noted.
const std = @import("std");
const Allocator = std.mem.Allocator;

const terminal = @import("../../../terminal/main.zig");
const renderer = @import("../../../renderer.zig");

/// Only http(s) links activate (T-25); `mailto:`, `file:` etc. are inert.
pub fn isHttp(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "https://");
}

pub const Cell = struct { col: u32, row: u32 };

/// The grid cell under a point in device pixels, or null outside the grid.
pub fn cellAt(size: renderer.Size, x: f64, y: f64) ?Cell {
    const cw: f64 = @floatFromInt(size.cell.width);
    const ch: f64 = @floatFromInt(size.cell.height);
    if (cw <= 0 or ch <= 0) return null;
    const fx = (x - @as(f64, @floatFromInt(size.padding.left))) / cw;
    const fy = (y - @as(f64, @floatFromInt(size.padding.top))) / ch;
    if (fx < 0 or fy < 0) return null;
    const grid = size.grid();
    const col: u32 = @intFromFloat(@floor(fx));
    const row: u32 = @intFromFloat(@floor(fy));
    if (col >= grid.columns or row >= grid.rows) return null;
    return .{ .col = col, .row = row };
}

/// The OSC 8 hyperlink URI at a viewport cell, copied with `alloc`.
/// Caller holds the renderer state mutex.
pub fn osc8At(alloc: Allocator, t: *terminal.Terminal, cell: Cell) ?[:0]u8 {
    const screen = t.screens.active;
    const pin = screen.pages.pin(.{ .viewport = .{
        .x = @intCast(cell.col),
        .y = @intCast(cell.row),
    } }) orelse return null;
    const c = pin.rowAndCell().cell;
    if (!c.hyperlink) return null;
    const page = pin.node.page();
    const id = page.lookupHyperlink(c) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, id);
    return alloc.dupeSentinel(u8, entry.uri.slice(page.memory), 0) catch null;
}

/// T-30: lines from the bottom within which a downward scroll snaps back
/// to the bottom: `max(3, round(rows * 0.15))`.
pub fn stickyBand(rows: usize) usize {
    const r: f64 = @floatFromInt(rows);
    return @max(3, @as(usize, @intFromFloat(@round(r * 0.15))));
}

/// T-20: the arrow keys xterm.js sends for Alt+click
/// (`moveToCellSequence`, browser/input/MoveToCell.ts), simplified for
/// wrapped rows in the alternate screen. `start` is the cursor, `target`
/// the clicked cell (both 0-based, viewport at the bottom). Appends to
/// `out`.
pub fn moveToCell(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    start: Cell,
    target: Cell,
    cols: u32,
    has_scrollback: bool,
    app_cursor: bool,
) Allocator.Error!void {
    const S = struct {
        fn arrows(o: *std.ArrayList(u8), a: Allocator, n: usize, dir: u8, app: bool) Allocator.Error!void {
            for (0..n) |_| try o.appendSlice(a, &.{ 0x1b, if (app) 'O' else '[', dir });
        }
    };
    const sx: i64 = start.col;
    const sy: i64 = start.row;
    const tx: i64 = target.col;
    const ty: i64 = target.row;
    const c: i64 = cols;

    if (!has_scrollback) {
        // Alternate screen: rows first, then columns.
        try S.arrows(out, alloc, @intCast(@abs(sy - ty)), if (sy > ty) 'A' else 'B', app_cursor);
        try S.arrows(out, alloc, @intCast(@abs(sx - tx)), if (sx > tx) 'D' else 'C', app_cursor);
        return;
    }
    // Normal screen: only horizontal moves, wrapping across rows.
    if (sy == ty) {
        return S.arrows(out, alloc, @intCast(@abs(sx - tx)), if (sx > tx) 'D' else 'C', app_cursor);
    }
    const up = sy > ty;
    const row_diff = @abs(sy - ty);
    // colsFromRowEnd(x) = cols - x; colsFromRowBeginning(x) = x - 1.
    const from_end = c - (if (up) tx else sx);
    const from_begin = (if (up) sx else tx) - 1;
    const cells = from_end + (@as(i64, @intCast(row_diff)) - 1) * c + 1 + from_begin;
    if (cells <= 0) return;
    try S.arrows(out, alloc, @intCast(cells), if (up) 'D' else 'C', app_cursor);
}

test "isHttp" {
    try std.testing.expect(isHttp("https://example.com"));
    try std.testing.expect(isHttp("HTTP://x"));
    try std.testing.expect(!isHttp("mailto:a@b"));
    try std.testing.expect(!isHttp("file:///etc"));
}

test "stickyBand" {
    try std.testing.expectEqual(@as(usize, 3), stickyBand(10));
    try std.testing.expectEqual(@as(usize, 8), stickyBand(52));
}

test "moveToCell same row and across rows" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try moveToCell(&out, a, .{ .col = 5, .row = 2 }, .{ .col = 2, .row = 2 }, 80, true, false);
    try std.testing.expectEqualStrings("\x1b[D\x1b[D\x1b[D", out.items);
    out.clearRetainingCapacity();
    // Down one row from col 78 to col 1 on an 80-column line: (80-78) + 0 + 1 + 0 = 3 rights.
    try moveToCell(&out, a, .{ .col = 78, .row = 2 }, .{ .col = 1, .row = 3 }, 80, true, true);
    try std.testing.expectEqualStrings("\x1bOC\x1bOC\x1bOC", out.items);
}
