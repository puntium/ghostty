//! Command tests: every command, its ordinary case and each edge app.js
//! handles. Expected layouts are derived by hand from app.js (cited per
//! test); `testing.zig` documents the spec strings.

const std = @import("std");
const t = std.testing;
const Layout = @import("Layout.zig");
const testing = @import("testing.zig");
const build = testing.build;
const expectLayout = testing.expectLayout;
const expectSizes = testing.expectSizes;

// ---------------------------------------------------------------------------
// Spec helper sanity
// ---------------------------------------------------------------------------

test "spec: round trip, default active and focus" {
    var l = try build("a,b|!c,d^|e");
    defer l.deinit();
    try expectLayout(&l, "a^*,b|!c,d^|e^");
    var m = try build("a,b^*|c:2,d:0.5");
    defer m.deinit();
    try expectLayout(&m, "a,b^*|c^,d");
    try expectSizes(&m, 1, &.{ 2, 0.5 });
}

test "kindOf: files prefix" {
    try t.expectEqual(Layout.Kind.files, Layout.kindOf("files-abc"));
    try t.expectEqual(Layout.Kind.terminal, Layout.kindOf("files"));
    try t.expectEqual(Layout.Kind.terminal, Layout.kindOf("s1"));
    var l = try build("s1|files-x");
    defer l.deinit();
    try t.expectEqualStrings("s1", l.find("s1").?.sessionId().?);
    try t.expectEqual(@as(?[]const u8, null), l.find("files-x").?.sessionId());
}

// ---------------------------------------------------------------------------
// newTerminal / newFiles (app.js openInNewColumn)
// ---------------------------------------------------------------------------

test "newTerminal: empty layout gets a first column" {
    var l = Layout.init(testing.gpa);
    defer l.deinit();
    try l.newTerminal("s1");
    try expectLayout(&l, "s1^*");
    try expectSizes(&l, 0, &.{1});
    try t.expect(!l.columns.items[0].full);
}

test "newTerminal: opens right of the focused column, not at the end" {
    var l = try build("a|b*|c");
    defer l.deinit();
    try l.newTerminal("x");
    try expectLayout(&l, "a^|b^|x^*|c^");
}

test "newTerminal: focused last column appends" {
    var l = try build("a|b*");
    defer l.deinit();
    try l.newTerminal("x");
    try expectLayout(&l, "a^|b^|x^*");
}

test "newTerminal: from a stacked pane, right of its whole column" {
    var l = try build("a,b^*|c");
    defer l.deinit();
    try l.newTerminal("x");
    try expectLayout(&l, "a,b^|x^*|c^");
}

test "newTerminal: next to a full column, which stays full; the new one is not" {
    var l = try build("!a*|b");
    defer l.deinit();
    try l.newTerminal("x");
    try expectLayout(&l, "!a^|x^*|b^");
}

test "newTerminal: rejects duplicate, files-prefixed and empty ids, unchanged" {
    var l = try build("a|b*");
    defer l.deinit();
    try t.expectError(error.DuplicateId, l.newTerminal("a"));
    try t.expectError(error.InvalidId, l.newTerminal("files-1"));
    try t.expectError(error.InvalidId, l.newTerminal(""));
    try expectLayout(&l, "a^|b^*");
}

test "newFiles: placed like a terminal, keeps its state" {
    var l = try build("a*|b");
    defer l.deinit();
    try l.newFiles("files-1", "{\"type\":\"files\",\"dir\":\"~\",\"cursor\":null}");
    try expectLayout(&l, "a^|files-1^*|b^");
    const p = l.find("files-1").?;
    try t.expectEqual(Layout.Kind.files, p.kind);
    try t.expectEqualStrings("{\"type\":\"files\",\"dir\":\"~\",\"cursor\":null}", p.state.?);
    try l.newFiles("files-2", null);
    try t.expectEqual(@as(?[]const u8, null), l.find("files-2").?.state);
}

test "newFiles: rejects a non-files id, a bare prefix, and states that are not JSON objects" {
    var l = try build("a*");
    defer l.deinit();
    try t.expectError(error.InvalidId, l.newFiles("s2", null));
    try t.expectError(error.InvalidId, l.newFiles("files-", null));
    try t.expectError(error.InvalidState, l.newFiles("files-1", "[1]"));
    try t.expectError(error.InvalidState, l.newFiles("files-1", "{\"a\":"));
    try t.expectError(error.InvalidState, l.newFiles("files-1", "\"x\""));
    try expectLayout(&l, "a^*");
}

test "setPaneState: files panes only, objects only" {
    var l = try build("a*|files-1");
    defer l.deinit();
    try l.setPaneState("files-1", "{\"dir\":\"/tmp\"}");
    try t.expectEqualStrings("{\"dir\":\"/tmp\"}", l.find("files-1").?.state.?);
    try l.setPaneState("files-1", "{\"dir\":\"/\"}");
    try t.expectEqualStrings("{\"dir\":\"/\"}", l.find("files-1").?.state.?);
    try t.expectError(error.InvalidState, l.setPaneState("files-1", "nope"));
    try t.expectEqualStrings("{\"dir\":\"/\"}", l.find("files-1").?.state.?);
    try t.expectError(error.InvalidId, l.setPaneState("a", "{}"));
    try t.expectError(error.InvalidId, l.setPaneState("zz", "{}"));
    try l.setPaneState("files-1", null);
    try t.expectEqual(@as(?[]const u8, null), l.find("files-1").?.state);
}

test "states nested deeper than the cap are rejected" {
    var l = try build("a*");
    defer l.deinit();
    var buf: [2 * 70 + 8]u8 = undefined;
    var n: usize = 0;
    for (0..70) |_| {
        buf[n] = '[';
        n += 1;
    }
    for (0..70) |_| {
        buf[n] = ']';
        n += 1;
    }
    const deep_array = buf[0..n];
    const deep = try std.fmt.allocPrint(testing.gpa, "{{\"a\":{s}}}", .{deep_array});
    defer testing.gpa.free(deep);
    try t.expectError(error.InvalidState, l.newFiles("files-1", deep));
    try t.expect(try Layout.validState(testing.gpa, "{\"a\":[[[]]]}"));
}

// ---------------------------------------------------------------------------
// newTerminalBelow (app.js newSessionBelow + insertIntoColumn)
// ---------------------------------------------------------------------------

test "newTerminalBelow: empty layout is newTerminal" {
    var l = Layout.init(testing.gpa);
    defer l.deinit();
    try l.newTerminalBelow("s1");
    try expectLayout(&l, "s1^*");
}

test "newTerminalBelow: lone pane becomes a stack of two equal panes" {
    var l = try build("a*|b");
    defer l.deinit();
    try l.newTerminalBelow("x");
    try expectLayout(&l, "a,x^*|b^");
    try expectSizes(&l, 0, &.{ 1, 1 });
}

test "newTerminalBelow: directly below the focused pane mid-stack, average weight" {
    var l = try build("a:1,b:2^*,c:3|d");
    defer l.deinit();
    try l.newTerminalBelow("x");
    try expectLayout(&l, "a,b,x^*,c|d^");
    try expectSizes(&l, 0, &.{ 1, 2, 2, 3 }); // (1+2+3)/3
}

test "newTerminalBelow: at the bottom of a stack" {
    var l = try build("a,b:0.5^*");
    defer l.deinit();
    try l.newTerminalBelow("x");
    try expectLayout(&l, "a,b,x^*");
    try expectSizes(&l, 0, &.{ 1, 0.5, 0.75 });
}

test "newTerminalBelow: a full column stays full" {
    var l = try build("!a*");
    defer l.deinit();
    try l.newTerminalBelow("x");
    try expectLayout(&l, "!a,x^*");
}

test "newTerminalBelow: rejects bad ids, unchanged" {
    var l = try build("a*");
    defer l.deinit();
    try t.expectError(error.DuplicateId, l.newTerminalBelow("a"));
    try t.expectError(error.InvalidId, l.newTerminalBelow("files-z"));
    try expectLayout(&l, "a^*");
}

// ---------------------------------------------------------------------------
// remove (app.js removeTile → removeSessionFromLayout)
// ---------------------------------------------------------------------------

test "remove: focused mid-stack, focus goes down the stack" {
    var l = try build("a,b^*,c|d");
    defer l.deinit();
    try t.expect(l.remove("b"));
    try expectLayout(&l, "a,c^*|d^");
}

test "remove: focused at the bottom of a stack, focus goes up" {
    var l = try build("a,b,c^*|d");
    defer l.deinit();
    try t.expect(l.remove("c"));
    try expectLayout(&l, "a,b^*|d^");
}

test "remove: focused alone, the right neighbour's active pane (not its first)" {
    var l = try build("x|a*|b,c^|d");
    defer l.deinit();
    try t.expect(l.remove("a"));
    try expectLayout(&l, "x^|b,c^*|d^");
}

test "remove: focused alone in the last column, the left neighbour's active pane" {
    var l = try build("x|b,c^|a*");
    defer l.deinit();
    try t.expect(l.remove("a"));
    try expectLayout(&l, "x^|b,c^*");
}

test "remove: the only pane empties the layout" {
    var l = try build("a*");
    defer l.deinit();
    try t.expect(l.remove("a"));
    try expectLayout(&l, "");
    try t.expect(l.isEmpty());
    try t.expectEqual(@as(?[]const u8, null), l.focusedId());
}

test "remove: an unfocused pane leaves focus alone; its column re-picks active" {
    // Active was c (index 1): the pane now at index 1 (d) becomes active.
    var l = try build("a*|b,c^,d");
    defer l.deinit();
    try t.expect(l.remove("c"));
    try expectLayout(&l, "a^*|b,d^");
    // Active at the bottom: the new last becomes active.
    var m = try build("a*|b,c,d^");
    defer m.deinit();
    try t.expect(m.remove("d"));
    try expectLayout(&m, "a^*|b,c^");
    // Not the active one: active stays.
    var k = try build("a*|b^,c");
    defer k.deinit();
    try t.expect(k.remove("c"));
    try expectLayout(&k, "a^*|b^");
}

test "remove: an unfocused lone column disappears" {
    var l = try build("a|b|c*");
    defer l.deinit();
    try t.expect(l.remove("b"));
    try expectLayout(&l, "a^|c^*");
}

test "remove: unknown id" {
    var l = try build("a*");
    defer l.deinit();
    try t.expect(!l.remove("nope"));
    try expectLayout(&l, "a^*");
}

test "remove: weights of the survivors are kept as they are" {
    var l = try build("a:1,b:2*,c:3");
    defer l.deinit();
    try t.expect(l.remove("b"));
    try expectSizes(&l, 0, &.{ 1, 3 });
}

// ---------------------------------------------------------------------------
// toggleFull (app.js toggleFull)
// ---------------------------------------------------------------------------

test "toggleFull: a lone pane flips its column" {
    var l = try build("a|b*|c");
    defer l.deinit();
    try t.expect(try l.toggleFull());
    try expectLayout(&l, "a^|!b^*|c^");
    try t.expect(try l.toggleFull());
    try expectLayout(&l, "a^|b^*|c^");
}

test "toggleFull: a stacked pane splits out right of its stack and goes full" {
    var l = try build("a,b^*,c|d");
    defer l.deinit();
    try t.expect(try l.toggleFull());
    try expectLayout(&l, "a,c^|!b^*|d^");
    try expectSizes(&l, 1, &.{1});
    // Pressed again it is alone: it just leaves full (it does not rejoin).
    try t.expect(try l.toggleFull());
    try expectLayout(&l, "a,c^|b^*|d^");
}

test "toggleFull: a stacked pane of a full column: both columns full" {
    var l = try build("!a*,b");
    defer l.deinit();
    try t.expect(try l.toggleFull());
    try expectLayout(&l, "!b^|!a^*");
}

test "toggleFull: empty layout" {
    var l = Layout.init(testing.gpa);
    defer l.deinit();
    try t.expect(!try l.toggleFull());
}

// ---------------------------------------------------------------------------
// focus (app.js focusColumn / focusInColumn / setFocus)
// ---------------------------------------------------------------------------

test "focus left/right: the neighbour column's remembered active pane" {
    var l = try build("a,b^|c*|d,e,f^");
    defer l.deinit();
    try t.expect(l.focus(.left));
    try expectLayout(&l, "a,b^*|c^|d,e,f^");
    try t.expect(l.focus(.right));
    try t.expect(l.focus(.right));
    try expectLayout(&l, "a,b^|c^|d,e,f^*");
}

test "focus: nothing past either end, single column, single pane" {
    var l = try build("a*|b");
    defer l.deinit();
    try t.expect(!l.focus(.left));
    try t.expect(!l.focus(.up));
    try t.expect(!l.focus(.down));
    try expectLayout(&l, "a^*|b^");
    var one = try build("a*");
    defer one.deinit();
    for ([_]Layout.Direction{ .left, .right, .up, .down }) |d| try t.expect(!one.focus(d));
    var stack = try build("a,b*");
    defer stack.deinit();
    try t.expect(!stack.focus(.right));
    try t.expect(!stack.focus(.down));
    try t.expect(!stack.focus(.left));
}

test "focus up/down moves within the stack and the column remembers" {
    var l = try build("a*,b,c|d");
    defer l.deinit();
    try t.expect(l.focus(.down));
    try t.expect(l.focus(.down));
    try expectLayout(&l, "a,b,c^*|d^");
    try t.expect(!l.focus(.down));
    try t.expect(l.focus(.up));
    try expectLayout(&l, "a,b^*,c|d^");
    try t.expect(l.focus(.right));
    try expectLayout(&l, "a,b^,c|d^*");
    try t.expect(l.focus(.left)); // back to b, not a
    try expectLayout(&l, "a,b^*,c|d^");
}

test "focus: empty layout" {
    var l = Layout.init(testing.gpa);
    defer l.deinit();
    for ([_]Layout.Direction{ .left, .right, .up, .down }) |d| try t.expect(!l.focus(d));
}

test "focus right from a dangling focus picks column 0 (app.js index -1 + 1)" {
    var l = try build("a|b");
    defer l.deinit();
    l.focused = null;
    try t.expect(!l.focus(.left));
    try t.expect(l.focus(.right));
    try expectLayout(&l, "a^*|b^");
}

test "setFocus: click focuses and activates; reports change" {
    var l = try build("a*|b^,c");
    defer l.deinit();
    try t.expect(l.setFocus("c"));
    try expectLayout(&l, "a^|b,c^*");
    try t.expect(!l.setFocus("c"));
    try t.expect(!l.setFocus("nope"));
    // Focused but not its column's active (a restored layout can do that).
    l.columns.items[1].active = l.find("b").?;
    try t.expect(l.setFocus("c"));
    try expectLayout(&l, "a^|b,c^*");
}

// ---------------------------------------------------------------------------
// moveColumn (app.js moveColumn)
// ---------------------------------------------------------------------------

test "moveColumn: swaps with the neighbour, stack and full flag travel" {
    var l = try build("a|!b*,c|d");
    defer l.deinit();
    try t.expect(l.moveColumn(.right));
    try expectLayout(&l, "a^|d^|!b^*,c");
    try t.expect(!l.moveColumn(.right));
    try t.expect(l.moveColumn(.left));
    try t.expect(l.moveColumn(.left));
    try expectLayout(&l, "!b^*,c|a^|d^");
    try t.expect(!l.moveColumn(.left));
}

test "moveColumn: single column, empty layout" {
    var l = try build("a*,b");
    defer l.deinit();
    try t.expect(!l.moveColumn(.left));
    try t.expect(!l.moveColumn(.right));
    var e = Layout.init(testing.gpa);
    defer e.deinit();
    try t.expect(!e.moveColumn(.right));
}

// ---------------------------------------------------------------------------
// movePane (app.js movePane)
// ---------------------------------------------------------------------------

test "movePane: swaps with its stack neighbour, weights travel" {
    var l = try build("a:1,b:2^*,c:3");
    defer l.deinit();
    try t.expect(l.movePane(.down));
    try expectLayout(&l, "a,c,b^*");
    try expectSizes(&l, 0, &.{ 1, 3, 2 });
    try t.expect(!l.movePane(.down));
    try t.expect(l.movePane(.up));
    try t.expect(l.movePane(.up));
    try expectLayout(&l, "b^*,a,c");
    try expectSizes(&l, 0, &.{ 2, 1, 3 });
    try t.expect(!l.movePane(.up));
}

test "movePane: single pane; the column's active memory is unaffected" {
    var l = try build("a*|b");
    defer l.deinit();
    try t.expect(!l.movePane(.up));
    try t.expect(!l.movePane(.down));
    var m = try build("a^,b*|c");
    defer m.deinit();
    // Focused b is not active (restored layout); moving keeps active = a.
    try t.expect(m.movePane(.up));
    try expectLayout(&m, "b*,a^|c^");
}

// ---------------------------------------------------------------------------
// consumeOrExpel (app.js consumeOrExpel / expel)
// ---------------------------------------------------------------------------

test "consumeOrExpel: a stacked pane is expelled right into a column of its own" {
    var l = try build("x|a:1,b:2^*,c:3|y");
    defer l.deinit();
    try t.expect(try l.consumeOrExpel(.right));
    try expectLayout(&l, "x^|a,c^|b^*|y^");
    try expectSizes(&l, 1, &.{ 1, 3 });
    try expectSizes(&l, 2, &.{1});
}

test "consumeOrExpel: expelled left goes before its old column" {
    var l = try build("x|a,b^*,c|y");
    defer l.deinit();
    try t.expect(try l.consumeOrExpel(.left));
    try expectLayout(&l, "x^|b^*|a,c^|y^");
}

test "consumeOrExpel: expel from the first and last columns" {
    var l = try build("a*,b");
    defer l.deinit();
    try t.expect(try l.consumeOrExpel(.left));
    try expectLayout(&l, "a^*|b^");
    var m = try build("a,b*");
    defer m.deinit();
    try t.expect(try m.consumeOrExpel(.right));
    try expectLayout(&m, "a^|b^*");
}

test "consumeOrExpel: a lone pane merges at the bottom of the neighbour, average weight" {
    var l = try build("a:1,b:3^|c*|d");
    defer l.deinit();
    try t.expect(try l.consumeOrExpel(.left));
    try expectLayout(&l, "a,b,c^*|d^");
    try expectSizes(&l, 0, &.{ 1, 3, 2 });
    var m = try build("a|c*|d,e^");
    defer m.deinit();
    try t.expect(try m.consumeOrExpel(.right));
    try expectLayout(&m, "a^|d,e,c^*");
}

test "consumeOrExpel: a lone pane with no column on that side stays put" {
    var l = try build("a*|b");
    defer l.deinit();
    try t.expect(!try l.consumeOrExpel(.left));
    try expectLayout(&l, "a^*|b^");
    var one = try build("a*");
    defer one.deinit();
    try t.expect(!try one.consumeOrExpel(.left));
    try t.expect(!try one.consumeOrExpel(.right));
    try expectLayout(&one, "a^*");
}

test "consumeOrExpel: two taps carry a stacked pane into the next column" {
    var l = try build("a,b^*|c");
    defer l.deinit();
    try t.expect(try l.consumeOrExpel(.right));
    try expectLayout(&l, "a^|b^*|c^");
    try t.expect(try l.consumeOrExpel(.right));
    try expectLayout(&l, "a^|c,b^*");
}

test "consumeOrExpel: full flags: the merged pane's own column (and flag) go, the target keeps its own" {
    var l = try build("!a*|!b");
    defer l.deinit();
    try t.expect(try l.consumeOrExpel(.right));
    try expectLayout(&l, "!b,a^*");
    var m = try build("a*|!b");
    defer m.deinit();
    try t.expect(try m.consumeOrExpel(.right));
    try expectLayout(&m, "!b,a^*");
}

test "consumeOrExpel: expelling from a full column, the old column stays full, the new one is not" {
    var l = try build("!a,b*");
    defer l.deinit();
    try t.expect(try l.consumeOrExpel(.right));
    try expectLayout(&l, "!a^|b^*");
}

test "consumeOrExpel: empty layout" {
    var l = Layout.init(testing.gpa);
    defer l.deinit();
    try t.expect(!try l.consumeOrExpel(.right));
}

// ---------------------------------------------------------------------------
// dragDivider (app.js makeDivider)
// ---------------------------------------------------------------------------

test "dividerRatio: pointer share of the span, clamped to keep 110 px each side" {
    // span 600: min = 110/600; pointer at 300 → 0.5.
    try t.expectApproxEqAbs(@as(f64, 0.5), Layout.dividerRatio(300, 600, 110), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 110.0 / 600.0), Layout.dividerRatio(20, 600, 110), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 1 - 110.0 / 600.0), Layout.dividerRatio(590, 600, 110), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 110.0 / 600.0), Layout.dividerRatio(-50, 600, 110), 1e-12);
    // span 200: 110/200 = 0.55 > 0.45 → clamped to 0.45…0.55.
    try t.expectApproxEqAbs(@as(f64, 0.45), Layout.dividerRatio(0, 200, 110), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.55), Layout.dividerRatio(200, 200, 110), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.5), Layout.dividerRatio(100, 200, 110), 1e-12);
}

test "dragDivider: reassigns the pair's combined weight, others untouched" {
    var l = try build("x|a:1,b:3,c:2*");
    defer l.deinit();
    // Divider 0 of column 1: pair weight 4, pointer at 1/4 of a 800 px span.
    try t.expect(l.dragDivider(1, 0, 200, 800, Layout.min_pane_px));
    try expectSizes(&l, 1, &.{ 1, 3, 2 });
    try t.expect(l.dragDivider(1, 0, 400, 800, Layout.min_pane_px));
    try expectSizes(&l, 1, &.{ 2, 2, 2 });
    // Divider 1, dragged far down: clamped at 1 - 110/600.
    try t.expect(l.dragDivider(1, 1, 10000, 600, Layout.min_pane_px));
    try expectSizes(&l, 1, &.{ 2, 4 * (1 - 110.0 / 600.0), 4 * (110.0 / 600.0) });
    try expectLayout(&l, "x^|a,b,c^*");
}

test "dragDivider: out of range and degenerate spans change nothing" {
    var l = try build("a*|b,c");
    defer l.deinit();
    try t.expect(!l.dragDivider(0, 0, 10, 100, 110)); // single pane: no divider
    try t.expect(!l.dragDivider(1, 1, 10, 100, 110)); // only divider 0
    try t.expect(!l.dragDivider(2, 0, 10, 100, 110)); // no column 2
    try t.expect(!l.dragDivider(1, 0, 10, 0, 110));
    try t.expect(!l.dragDivider(1, 0, 10, -5, 110));
    try t.expect(!l.dragDivider(1, 0, std.math.nan(f64), 100, 110));
    try t.expect(!l.dragDivider(1, 0, 10, std.math.inf(f64), 110));
    try expectSizes(&l, 1, &.{ 1, 1 });
}

// ---------------------------------------------------------------------------
// Commands by name
// ---------------------------------------------------------------------------

test "Command: app.js names round-trip" {
    const names = [_][]const u8{
        "new-terminal",   "new-files",          "new-terminal-below",  "close-pane",
        "toggle-full",    "focus-left",         "focus-right",         "focus-up",
        "focus-down",     "move-column-left",   "move-column-right",   "move-pane-up",
        "move-pane-down", "consume-expel-left", "consume-expel-right",
    };
    try t.expectEqual(names.len, std.enums.values(Layout.Command).len);
    for (names) |n| {
        const c = Layout.Command.fromName(n) orelse return error.TestUnexpectedResult;
        try t.expectEqualStrings(n, c.name());
    }
    try t.expectEqual(@as(?Layout.Command, null), Layout.Command.fromName("focus_left"));
    try t.expect(Layout.Command.close_pane.needsShell());
    try t.expect(!Layout.Command.toggle_full.needsShell());
}

test "run: dispatches the pure commands, refuses the shell ones" {
    var l = try build("a,b*|c");
    defer l.deinit();
    try t.expect(!try l.run(.new_terminal));
    try t.expect(!try l.run(.close_pane));
    try expectLayout(&l, "a,b^*|c^");
    try t.expect(try l.run(.focus_up));
    try t.expect(try l.run(.move_pane_down));
    try expectLayout(&l, "b,a^*|c^");
    try t.expect(try l.run(.consume_expel_right));
    try expectLayout(&l, "b^|a^*|c^");
    try t.expect(try l.run(.move_column_right));
    try expectLayout(&l, "b^|c^|a^*");
    try t.expect(try l.run(.focus_left));
    try t.expect(try l.run(.toggle_full));
    try expectLayout(&l, "b^|!c^*|a^");
    try t.expect(try l.run(.consume_expel_left));
    try expectLayout(&l, "b,c^*|a^");
    try t.expect(try l.run(.focus_right));
    try t.expect(try l.run(.move_column_left));
    try t.expect(try l.run(.focus_down) == false);
    try expectLayout(&l, "a^*|b,c^");
}

// ---------------------------------------------------------------------------
// A long random walk: invariants hold after every command, and nothing leaks
// (std.testing.allocator checks the latter).
// ---------------------------------------------------------------------------

test "random command sequences keep the invariants" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    var l = Layout.init(testing.gpa);
    defer l.deinit();
    var next: usize = 0;
    var buf: [32]u8 = undefined;
    for (0..5000) |_| {
        switch (r.uintLessThan(u8, 20)) {
            0, 1 => {
                const id = try std.fmt.bufPrint(&buf, "s{d}", .{next});
                next += 1;
                try l.newTerminal(id);
            },
            2, 3 => {
                const id = try std.fmt.bufPrint(&buf, "s{d}", .{next});
                next += 1;
                try l.newTerminalBelow(id);
            },
            4 => {
                const id = try std.fmt.bufPrint(&buf, "files-{d}", .{next});
                next += 1;
                try l.newFiles(id, "{}");
            },
            5, 6 => if (l.focusedId()) |f| {
                const copy = try testing.gpa.dupe(u8, f);
                defer testing.gpa.free(copy);
                try t.expect(l.remove(copy));
            },
            7 => if (l.paneCount() > 0) {
                // remove some pane at random
                const ci = r.uintLessThan(usize, l.columns.items.len);
                const col = l.columns.items[ci];
                const p = col.panes.items[r.uintLessThan(usize, col.len())];
                const copy = try testing.gpa.dupe(u8, p.id);
                defer testing.gpa.free(copy);
                try t.expect(l.remove(copy));
            },
            8 => if (l.columns.items.len > 0) {
                const ci = r.uintLessThan(usize, l.columns.items.len);
                const col = l.columns.items[ci];
                _ = l.dragDivider(ci, r.uintLessThan(usize, col.len()), r.float(f64) * 900 - 100, r.float(f64) * 800, 110);
            },
            else => {
                const cmds = [_]Layout.Command{
                    .toggle_full,    .focus_left,         .focus_right,         .focus_up,
                    .focus_down,     .move_column_left,   .move_column_right,   .move_pane_up,
                    .move_pane_down, .consume_expel_left, .consume_expel_right,
                };
                _ = try l.run(cmds[r.uintLessThan(usize, cmds.len)]);
            },
        }
        try l.check();
    }
}

test "commands are OOM-safe: every allocation failure leaves a layout that frees cleanly" {
    const Case = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var l: Layout = .init(alloc);
            defer l.deinit();
            try l.newTerminal("a");
            try l.newTerminalBelow("b");
            try l.newTerminal("c");
            try l.newFiles("files-1", "{\"dir\":\"~\"}");
            _ = l.focus(.left);
            _ = l.focus(.left);
            _ = try l.consumeOrExpel(.right);
            _ = try l.toggleFull();
            _ = try l.consumeOrExpel(.left);
            try l.setPaneState("files-1", "{}");
            try l.check();
        }
    };
    try t.checkAllAllocationFailures(testing.gpa, Case.run, .{});
}
