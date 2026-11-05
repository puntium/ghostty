//! Mouse selection rules where Ghostty's core differs from xterm.js 5.5
//! (`SelectionService.ts`), applied by the pane after the core has handled
//! the click (D-06).
//!
//! Double-click (`_getWordAt`, wordSeparator ` ()[]{}',"`` ` ``):
//!   - on a space (or an empty cell): the run of spaces/empty cells around
//!     it, nothing else;
//!   - on any other character, separators included: grow left and right
//!     while the neighbouring cell is not a separator (so `(` between
//!     spaces selects only `(`, and `(` in `foo(bar)` selects `foo(bar`).
//!   Rows are crossed only where the line soft-wraps.
//!
//! Plain click, then Shift+click (`_handleSingleClick`,
//! `_handleIncrementalClick`): the click sets an anchor at the nearest cell
//! boundary; Shift+click with no selection selects from the anchor to the
//! boundary nearest the second click (cells in between, end exclusive).

const std = @import("std");
const terminal = @import("../../../terminal/main.zig");

const Screen = terminal.Screen;
const Pin = terminal.Pin;
const Selection = terminal.Selection;

/// xterm.js's default `wordSeparator`.
pub const separators = " ()[]{}',\"`";

/// The codepoint a cell shows for word purposes; 0 for an empty cell.
/// A wide character's spacer stands for the character.
fn codepointAt(p: Pin) u21 {
    const rac = p.rowAndCell();
    const cell = switch (rac.cell.wide) {
        .narrow, .wide => rac.cell,
        .spacer_tail => (p.left(1)).rowAndCell().cell,
        .spacer_head => return 0,
    };
    return if (cell.hasText()) cell.content.codepoint.data else 0;
}

fn isSpace(c: u21) bool {
    return c == ' ' or c == 0;
}

fn isSeparator(c: u21) bool {
    if (c == 0) return true;
    return c < 128 and std.mem.indexOfScalar(u8, separators, @intCast(c)) != null;
}

/// The double-click word at `pin`, by xterm's rules.
pub fn wordAt(pin: Pin) Selection {
    const start_space = isSpace(codepointAt(pin));
    const keep = struct {
        fn f(space_mode: bool, c: u21) bool {
            return if (space_mode) isSpace(c) else !isSeparator(c);
        }
    }.f;

    const end: Pin = end: {
        var it = pin.cellIterator(.right_down, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            if (prev.x == prev.node.cols() - 1 and !prev.rowAndCell().row.wrap) break :end prev;
            if (!keep(start_space, codepointAt(p))) break :end prev;
            prev = p;
        }
        break :end prev;
    };
    const start: Pin = start: {
        var it = pin.cellIterator(.left_up, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            if (p.x == p.node.cols() - 1 and !p.rowAndCell().row.wrap) break :start prev;
            if (!keep(start_space, codepointAt(p))) break :start prev;
            prev = p;
        }
        break :start prev;
    };
    return .init(start, end, false);
}

/// A cell boundary in screen coordinates: `x` in 0...cols.
pub const Boundary = struct { x: u32, y: u32 };

/// The selection between two cell boundaries (end exclusive, in reading
/// order), or null if they are the same boundary.
pub fn between(screen: *Screen, a: Boundary, b: Boundary) ?Selection {
    const lo, const hi = if (a.y < b.y or (a.y == b.y and a.x <= b.x)) .{ a, b } else .{ b, a };
    if (lo.y == hi.y and lo.x == hi.x) return null;
    const cols: u32 = @intCast(screen.pages.cols);
    // First cell: the one right of `lo`; last: the one left of `hi`.
    const first: Boundary = if (lo.x >= cols) .{ .x = 0, .y = lo.y + 1 } else lo;
    const last: Boundary = if (hi.x == 0) .{ .x = cols - 1, .y = hi.y -| 1 } else .{ .x = hi.x - 1, .y = hi.y };
    if (first.y > last.y or (first.y == last.y and first.x > last.x)) return null;
    const p1 = screen.pages.pin(.{ .screen = .{ .x = @intCast(first.x), .y = first.y } }) orelse return null;
    const p2 = screen.pages.pin(.{ .screen = .{ .x = @intCast(last.x), .y = last.y } }) orelse return null;
    return .init(p1, p2, false);
}

test "xterm word rules" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 30, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo ` bar (  ) baz foo(bar)");
    const Case = struct { x: u16, want: []const u8 };
    const cases = [_]Case{
        .{ .x = 0, .want = "foo" },
        .{ .x = 3, .want = " " }, // the space before the backtick
        .{ .x = 4, .want = "`" },
        .{ .x = 11, .want = "  " }, // the spaces inside the parentheses
        .{ .x = 10, .want = "(" },
        .{ .x = 13, .want = ")" },
        .{ .x = 22, .want = "foo(bar" }, // xterm grows from `(` into letters
        .{ .x = 26, .want = "bar)" },
    };
    for (cases) |c| {
        const pin = s.pages.pin(.{ .active = .{ .x = c.x, .y = 0 } }).?;
        const sel = wordAt(pin);
        const text = try s.selectionString(testing.allocator, .{ .sel = sel, .trim = false });
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(c.want, text);
    }
}

test "shift-click range between boundaries" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("0123456789abcdefghij");
    {
        const sel = between(&s, .{ .x = 2, .y = 0 }, .{ .x = 5, .y = 0 }).?;
        const text = try s.selectionString(testing.allocator, .{ .sel = sel, .trim = false });
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("234", text);
    }
    {
        // Backwards, across the wrap.
        const sel = between(&s, .{ .x = 3, .y = 1 }, .{ .x = 8, .y = 0 }).?;
        const text = try s.selectionString(testing.allocator, .{ .sel = sel, .trim = false });
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("89abc", text);
    }
    try testing.expect(between(&s, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 0 }) == null);
}
