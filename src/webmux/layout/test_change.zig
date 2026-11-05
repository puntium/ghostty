//! Change-description tests: each expected origin is what app.js
//! animateStrip computes for the same command (`from` = the old box by
//! pane id; else entryRect: pane above → pane below → column matched to
//! the left → to the right → in place; dividers by index in the matched
//! old column), and each leaving pane what removeTile passes as `leaving`.

const std = @import("std");
const t = std.testing;
const Layout = @import("Layout.zig");
const change = @import("change.zig");
const testing = @import("testing.zig");
const gpa = testing.gpa;
const Origin = change.Origin;

/// Run `cmd` on `l` between two snapshots and return the diff.
fn run(l: *Layout, cmd: anytype) !change.Change {
    var before = try change.snapshot(gpa, l);
    defer before.deinit();
    try cmd.do(l);
    var after = try change.snapshot(gpa, l);
    defer after.deinit();
    return change.diff(gpa, &before, &after);
}

fn Cmd(comptime f: anytype) type {
    return struct {
        arg: []const u8 = "",
        fn do(self: @This(), l: *Layout) !void {
            try f(l, self.arg);
        }
    };
}

fn newTerminal(l: *Layout, id: []const u8) !void {
    try l.newTerminal(id);
}
fn newBelow(l: *Layout, id: []const u8) !void {
    try l.newTerminalBelow(id);
}
fn remove(l: *Layout, id: []const u8) !void {
    try t.expect(l.remove(id));
}
fn command(l: *Layout, name: []const u8) !void {
    _ = try l.run(Layout.Command.fromName(name).?);
}

fn expectMoved(o: Origin, col: usize, row: usize) !void {
    try t.expectEqual(Origin{ .moved = .{ .col = col, .row = row } }, o);
}

fn expectBelow(o: Origin, id: []const u8, col: usize, row: usize) !void {
    try t.expect(o == .below);
    try t.expectEqualStrings(id, o.below.id);
    try t.expectEqual(change.Slot{ .col = col, .row = row }, o.below.old);
}

fn expectAbove(o: Origin, id: []const u8, col: usize, row: usize) !void {
    try t.expect(o == .above);
    try t.expectEqualStrings(id, o.above.id);
    try t.expectEqual(change.Slot{ .col = col, .row = row }, o.above.old);
}

test "snapshot: a deep copy that outlives the layout" {
    var l = try testing.build("a,b:2^|!c*");
    var s = try change.snapshot(gpa, &l);
    defer s.deinit();
    l.deinit();
    try t.expectEqual(@as(usize, 2), s.columns.len);
    try t.expectEqualStrings("b", s.columns[0].ids[1]);
    try t.expectEqualStrings("b", s.columns[0].active);
    try t.expectEqual(@as(f64, 2), s.columns[0].sizes[1]);
    try t.expect(s.columns[1].full);
    try t.expectEqualStrings("c", s.focused.?);
    try t.expectEqual(change.Slot{ .col = 1, .row = 0 }, s.find("c").?);
    try t.expectEqual(@as(?change.Slot, null), s.find("zz"));
}

test "new column: opens out of the right edge of the column to its left" {
    var l = try testing.build("a|b*|c");
    defer l.deinit();
    var c = try run(&l, Cmd(newTerminal){ .arg = "x" });
    defer c.deinit();
    try t.expect(c.structural);
    try t.expectEqual(@as(usize, 4), c.columns.len);
    try t.expectEqual(@as(?usize, 0), c.columns[0].from);
    try t.expectEqual(@as(?usize, 1), c.columns[1].from);
    try t.expectEqual(@as(?usize, null), c.columns[2].from);
    try t.expectEqual(@as(?usize, 2), c.columns[3].from);
    try expectMoved(c.columns[0].panes[0].origin, 0, 0);
    try expectMoved(c.columns[3].panes[0].origin, 2, 0);
    try t.expectEqualStrings("x", c.columns[2].panes[0].id);
    try t.expectEqual(Origin{ .after_column = 1 }, c.columns[2].panes[0].origin);
    try t.expect(c.columns[2].panes[0].origin.isFresh());
    try t.expectEqual(@as(usize, 0), c.leaving.len);
    try t.expectEqualStrings("x", c.focused.?);
}

test "the very first pane grows in place" {
    var l = Layout.init(gpa);
    defer l.deinit();
    var c = try run(&l, Cmd(newTerminal){ .arg = "a" });
    defer c.deinit();
    try t.expectEqual(Origin.in_place, c.columns[0].panes[0].origin);
    try t.expectEqual(@as(?usize, null), c.columns[0].from);
}

test "a new first column (no left neighbour) opens out of the left edge of the one after it" {
    var l = try testing.build("a*");
    defer l.deinit();
    var before = try change.snapshot(gpa, &l);
    defer before.deinit();
    try l.newTerminal("x");
    _ = l.moveColumn(.left);
    var after = try change.snapshot(gpa, &l);
    defer after.deinit();
    var c = try change.diff(gpa, &before, &after);
    defer c.deinit();
    try t.expectEqual(Origin{ .before_column = 0 }, c.columns[0].panes[0].origin);
    try expectMoved(c.columns[1].panes[0].origin, 0, 0);
}

test "stacked below the focused pane: out of its bottom edge; dividers" {
    var l = try testing.build("a,b*|c");
    defer l.deinit();
    var c = try run(&l, Cmd(newBelow){ .arg = "x" });
    defer c.deinit();
    const col = c.columns[0];
    try t.expectEqual(@as(?usize, 0), col.from);
    try expectMoved(col.panes[0].origin, 0, 0);
    try expectMoved(col.panes[1].origin, 0, 1);
    try expectBelow(col.panes[2].origin, "b", 0, 1);
    try t.expectEqual(@as(usize, 2), col.dividers.len);
    try expectMoved(col.dividers[0].origin, 0, 0); // the old a|b divider
    try expectBelow(col.dividers[1].origin, "b", 0, 1); // new: under b
}

test "stacked mid-stack: the pane above wins; the new lower divider opens over the pane below" {
    var l = try testing.build("a*,b");
    defer l.deinit();
    var c = try run(&l, Cmd(newBelow){ .arg = "x" });
    defer c.deinit();
    const col = c.columns[0];
    try expectBelow(col.panes[1].origin, "a", 0, 0);
    try expectMoved(col.panes[2].origin, 0, 1);
    try expectMoved(col.dividers[0].origin, 0, 0);
    // Divider 1 sits between x (new) and b: x has no old box, so b's top.
    try expectAbove(col.dividers[1].origin, "b", 0, 1);
}

test "a new pane at the top of a stack opens out of the top of the pane below" {
    // movePane after newTerminalBelow puts the fresh pane first.
    var l = try testing.build("a*");
    defer l.deinit();
    var before = try change.snapshot(gpa, &l);
    defer before.deinit();
    try l.newTerminalBelow("x");
    _ = l.movePane(.up);
    var after = try change.snapshot(gpa, &l);
    defer after.deinit();
    var c = try change.diff(gpa, &before, &after);
    defer c.deinit();
    try expectAbove(c.columns[0].panes[0].origin, "a", 0, 0);
    try expectAbove(c.columns[0].dividers[0].origin, "a", 0, 0);
}

test "closing a stacked pane: squeezed between its neighbours" {
    var l = try testing.build("x|a,b*,c");
    defer l.deinit();
    var c = try run(&l, Cmd(remove){ .arg = "b" });
    defer c.deinit();
    try t.expectEqual(@as(usize, 1), c.leaving.len);
    const x = c.leaving[0];
    try t.expectEqualStrings("b", x.id);
    try t.expectEqual(change.Slot{ .col = 1, .row = 1 }, x.old);
    try t.expect(!x.alone);
    try t.expectEqualStrings("a", x.above.?);
    try t.expectEqualStrings("c", x.below.?);
    // The surviving divider is the one that separated a from b.
    try expectMoved(c.columns[1].dividers[0].origin, 1, 0);
    try t.expectEqualStrings("c", c.focused.?);
    try t.expect(c.leavingPane("b") != null);
    try t.expect(c.pane("b") == null);
}

test "closing the top / bottom pane of a stack: one neighbour" {
    var l = try testing.build("a*,b");
    defer l.deinit();
    var c = try run(&l, Cmd(remove){ .arg = "a" });
    defer c.deinit();
    try t.expectEqual(@as(?[]const u8, null), c.leaving[0].above);
    try t.expectEqualStrings("b", c.leaving[0].below.?);
    var m = try testing.build("a,b*");
    defer m.deinit();
    var d = try run(&m, Cmd(remove){ .arg = "b" });
    defer d.deinit();
    try t.expectEqualStrings("a", d.leaving[0].above.?);
    try t.expectEqual(@as(?[]const u8, null), d.leaving[0].below);
}

test "closing a lone column: wiped, the columns beyond slide in" {
    var l = try testing.build("a|b*|c");
    defer l.deinit();
    var c = try run(&l, Cmd(remove){ .arg = "b" });
    defer c.deinit();
    try t.expect(c.leaving[0].alone);
    try t.expectEqual(change.Slot{ .col = 1, .row = 0 }, c.leaving[0].old);
    try t.expectEqual(@as(?usize, 0), c.columns[0].from);
    try t.expectEqual(@as(?usize, 2), c.columns[1].from);
    try expectMoved(c.columns[1].panes[0].origin, 2, 0);
}

test "leaving neighbours count only if they are still there (several panes dropped at once)" {
    var l = try testing.build("a,b,c*");
    defer l.deinit();
    var before = try change.snapshot(gpa, &l);
    defer before.deinit();
    _ = l.remove("a");
    _ = l.remove("b");
    var after = try change.snapshot(gpa, &l);
    defer after.deinit();
    var c = try change.diff(gpa, &before, &after);
    defer c.deinit();
    try t.expectEqual(@as(usize, 2), c.leaving.len);
    try t.expectEqual(@as(?[]const u8, null), c.leaving[0].above);
    try t.expectEqual(@as(?[]const u8, null), c.leaving[0].below); // b is gone too
    try t.expectEqual(@as(?[]const u8, null), c.leaving[1].above);
    try t.expectEqualStrings("c", c.leaving[1].below.?);
}

test "merge into the next column: the column that held the others keeps its identity" {
    var l = try testing.build("a,b|c*");
    defer l.deinit();
    var c = try run(&l, Cmd(command){ .arg = "consume-expel-left" });
    defer c.deinit();
    try t.expectEqual(@as(usize, 1), c.columns.len);
    try t.expectEqual(@as(?usize, 0), c.columns[0].from);
    try expectMoved(c.columns[0].panes[2].origin, 1, 0);
    try expectMoved(c.columns[0].dividers[0].origin, 0, 0);
    // A divider the old column did not have: under b, which was there.
    try expectBelow(c.columns[0].dividers[1].origin, "b", 0, 1);
    try t.expectEqual(@as(usize, 0), c.leaving.len);
}

test "merge of two lone columns: a tie goes to the first old column" {
    var l = try testing.build("a|b*");
    defer l.deinit();
    var c = try run(&l, Cmd(command){ .arg = "consume-expel-left" });
    defer c.deinit();
    try t.expectEqual(@as(?usize, 0), c.columns[0].from);
    try expectBelow(c.columns[0].dividers[0].origin, "a", 0, 0);
}

test "expel: the survivors keep the column, the pane moves to a new one" {
    var l = try testing.build("a,b*,c");
    defer l.deinit();
    var c = try run(&l, Cmd(command){ .arg = "consume-expel-right" });
    defer c.deinit();
    try t.expectEqual(@as(?usize, 0), c.columns[0].from);
    try t.expectEqual(@as(?usize, null), c.columns[1].from);
    try expectMoved(c.columns[1].panes[0].origin, 0, 1);
    try expectMoved(c.columns[0].dividers[0].origin, 0, 0);
}

test "matchColumns: greedy by overlap, each old column once" {
    var a = try testing.build("a,b,c|d*");
    defer a.deinit();
    var b = try testing.build("a|b,c,d*");
    defer b.deinit();
    var sa = try change.snapshot(gpa, &a);
    defer sa.deinit();
    var sb = try change.snapshot(gpa, &b);
    defer sb.deinit();
    const match = try change.matchColumns(gpa, &sa, &sb);
    defer gpa.free(match);
    // pairs: (n0,o0,1) (n1,o0,2) (n1,o1,1) → n1 takes o0 first; n0 gets none.
    try t.expectEqualSlices(?usize, &.{ null, 0 }, match);
}

test "focus-only and no-op commands are not structural" {
    var l = try testing.build("a,b*|c");
    defer l.deinit();
    var c = try run(&l, Cmd(command){ .arg = "focus-right" });
    defer c.deinit();
    try t.expect(!c.structural);
    try t.expectEqualStrings("c", c.focused.?);
    var d = try run(&l, Cmd(command){ .arg = "move-column-right" });
    defer d.deinit();
    try t.expect(!d.structural); // nothing past the end
    var e = try run(&l, Cmd(command){ .arg = "toggle-full" });
    defer e.deinit();
    try t.expect(e.structural);
    var f = try run(&l, Cmd(command){ .arg = "move-column-left" });
    defer f.deinit();
    try t.expect(f.structural);
    try expectMoved(f.columns[0].panes[0].origin, 1, 0);
    try t.expectEqual(@as(?usize, 1), f.columns[0].from);
}

test "a divider drag is structural (weights changed) with everything in place" {
    var l = try testing.build("a,b*");
    defer l.deinit();
    var before = try change.snapshot(gpa, &l);
    defer before.deinit();
    try t.expect(l.dragDivider(0, 0, 100, 400, 110));
    var after = try change.snapshot(gpa, &l);
    defer after.deinit();
    var c = try change.diff(gpa, &before, &after);
    defer c.deinit();
    try t.expect(c.structural);
    try expectMoved(c.columns[0].panes[1].origin, 0, 1);
}

test "a new two-pane column with nothing old in it opens beside its neighbour" {
    var l = try testing.build("a*");
    defer l.deinit();
    var before = try change.snapshot(gpa, &l);
    defer before.deinit();
    try l.newTerminal("x");
    try l.newTerminalBelow("y");
    var after = try change.snapshot(gpa, &l);
    defer after.deinit();
    var c = try change.diff(gpa, &before, &after);
    defer c.deinit();
    try t.expectEqual(Origin{ .after_column = 0 }, c.columns[1].panes[0].origin);
    // y: the pane above (x) is new too, so the column rule applies.
    try t.expectEqual(Origin{ .after_column = 0 }, c.columns[1].panes[1].origin);
    try t.expectEqual(Origin{ .after_column = 0 }, c.columns[1].dividers[0].origin);
}

test "toggleFull of a stacked pane: it moves to a new column right of its stack" {
    var l = try testing.build("a,b*|c");
    defer l.deinit();
    var c = try run(&l, Cmd(command){ .arg = "toggle-full" });
    defer c.deinit();
    try t.expectEqual(@as(usize, 3), c.columns.len);
    try expectMoved(c.columns[1].panes[0].origin, 0, 1);
    try t.expectEqual(@as(?usize, 0), c.columns[0].from);
    try t.expectEqual(@as(?usize, null), c.columns[1].from);
    try t.expectEqual(@as(?usize, 1), c.columns[2].from);
}

test "diff is OOM-safe" {
    const Case = struct {
        fn run_(alloc: std.mem.Allocator) !void {
            var l: Layout = .init(alloc);
            defer l.deinit();
            try l.newTerminal("a");
            try l.newTerminalBelow("b");
            try l.newTerminal("c");
            var before = try change.snapshot(alloc, &l);
            defer before.deinit();
            _ = l.remove("b");
            _ = try l.consumeOrExpel(.left);
            try l.newTerminal("d");
            var after = try change.snapshot(alloc, &l);
            defer after.deinit();
            var c = try change.diff(alloc, &before, &after);
            c.deinit();
        }
    };
    try t.checkAllAllocationFailures(gpa, Case.run_, .{});
}
