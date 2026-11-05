//! What a command changed, in the terms app.js's layout animation uses
//! (`snapshotStrip`, `matchColumns`, `animateStrip`'s `entryRect` and its
//! leaving panes), but in slots rather than pixels: the view takes a
//! `Snapshot` before a command and another after, and `diff` tells it, for
//! every pane and divider of the new layout, where it was (an old slot,
//! whose old box the view measured or can compute from the old snapshot
//! with the width rule) or, if it is new, which old box it opens out of;
//! and for every pane that went away, how it should close.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Layout = @import("Layout.zig");

/// A deep, immutable copy of a layout's structure (no file-browser state).
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    columns: []const Column,
    focused: ?[]const u8,

    pub const Column = struct {
        ids: []const []const u8,
        sizes: []const f64,
        active: []const u8,
        full: bool,
    };

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Snapshot, id: []const u8) ?Slot {
        for (self.columns, 0..) |c, ci| {
            for (c.ids, 0..) |x, i| if (std.mem.eql(u8, x, id)) return .{ .col = ci, .row = i };
        }
        return null;
    }
};

pub fn snapshot(gpa: Allocator, layout: *const Layout) Allocator.Error!Snapshot {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const cols = try a.alloc(Snapshot.Column, layout.columns.items.len);
    for (layout.columns.items, cols) |src, *dst| {
        const ids = try a.alloc([]const u8, src.len());
        for (src.panes.items, ids) |p, *id| id.* = try a.dupe(u8, p.id);
        dst.* = .{
            .ids = ids,
            .sizes = try a.dupe(f64, src.sizes.items),
            .active = ids[src.indexOf(src.active).?],
            .full = src.full,
        };
    }
    const focused = if (layout.focused) |f| try a.dupe(u8, f.id) else null;
    return .{ .arena = arena, .columns = cols, .focused = focused };
}

/// A place in a snapshot: column index, and row (pane index) within it. For
/// a divider, `row` is the divider's index (divider i sits under pane i).
pub const Slot = struct { col: usize, row: usize };

/// A pane of the old layout that a new element opens out of.
pub const Neighbour = struct { id: []const u8, old: Slot };

/// Where an element of the new layout starts its move (app.js animateStrip
/// `from`, or `entryRect` for one that has no old box).
pub const Origin = union(enum) {
    /// It was on screen: it travels from its old box. For a pane, `old` is
    /// its old slot; for a divider, the matched old column and the
    /// divider's index in it.
    moved: Slot,
    /// New, opening out of the bottom edge of this old pane (the one above
    /// it now): zero height at that pane's old bottom plus the stack gap
    /// (8 px for a pane; 1 px, the divider's margin, for a divider), with
    /// that pane's old left and width.
    below: Neighbour,
    /// New, opening out of the top edge of this old pane (the one below it
    /// now): zero height at its old top minus the gap.
    above: Neighbour,
    /// New, a column of its own (or its divider) opening zero-width just
    /// right of this old column's old box (+ the column gap), at its final
    /// top and height.
    after_column: usize,
    /// …just left of this old column's old box (− the column gap).
    before_column: usize,
    /// New with nothing old around it (the very first pane): grows from
    /// zero width at its final box.
    in_place,

    pub fn isFresh(self: Origin) bool {
        return self != .moved;
    }
};

pub const PaneChange = struct {
    id: []const u8,
    origin: Origin,
};

pub const DividerChange = struct {
    origin: Origin,
};

pub const ColumnChange = struct {
    /// The old column this one continues (app.js matchColumns: greedy by
    /// shared panes, each old column used at most once), or null.
    from: ?usize,
    /// Parallel to the new column's panes.
    panes: []const PaneChange,
    /// Parallel to the new column's dividers (panes − 1).
    dividers: []const DividerChange,
};

/// A pane that went away (app.js removeTile's `leaving`): it stays on
/// screen at its old box while a clip closes in on it.
pub const Leaving = struct {
    id: []const u8,
    old: Slot,
    /// It had its column to itself: wiped from the right as the columns
    /// beyond slide in (clip from its old right edge to its left edge).
    alone: bool,
    /// Stacked: it is squeezed to the line where its neighbours meet. The
    /// old neighbour above it, if that pane is still in the layout: the
    /// line is half a stack gap below that pane's new bottom…
    above: ?[]const u8,
    /// …else the old neighbour below, if still there: half a gap above its
    /// new top; else the middle of the old box. Clamped to the old box.
    below: ?[]const u8,
};

pub const Change = struct {
    arena: std.heap.ArenaAllocator,
    /// Parallel to the new layout's columns.
    columns: []const ColumnChange,
    leaving: []const Leaving,
    /// The focused pane after the change: drawn over the others where boxes
    /// overlap in flight (app.js z-index 3).
    focused: ?[]const u8,
    /// False when nothing structural happened (same columns, panes, order,
    /// weights and full flags): no layout animation to run.
    structural: bool,

    pub fn deinit(self: *Change) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn pane(self: *const Change, id: []const u8) ?PaneChange {
        for (self.columns) |c| {
            for (c.panes) |p| if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }

    pub fn leavingPane(self: *const Change, id: []const u8) ?Leaving {
        for (self.leaving) |l| if (std.mem.eql(u8, l.id, id)) return l;
        return null;
    }
};

/// app.js matchColumns: every (new, old) pair sharing panes, sorted by
/// overlap descending (stable: ties keep new-then-old order), taken
/// greedily with each new and each old column used once.
pub fn matchColumns(gpa: Allocator, before: *const Snapshot, after: *const Snapshot) Allocator.Error![]?usize {
    const Pair = struct { n: usize, o: usize, overlap: usize };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);
    for (after.columns, 0..) |nc, n| {
        for (before.columns, 0..) |oc, o| {
            var overlap: usize = 0;
            for (nc.ids) |id| {
                for (oc.ids) |x| {
                    if (std.mem.eql(u8, id, x)) {
                        overlap += 1;
                        break;
                    }
                }
            }
            if (overlap > 0) try pairs.append(gpa, .{ .n = n, .o = o, .overlap = overlap });
        }
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.overlap > b.overlap;
        }
    }.lt);
    const match = try gpa.alloc(?usize, after.columns.len);
    @memset(match, null);
    const used = try gpa.alloc(bool, before.columns.len);
    defer gpa.free(used);
    @memset(used, false);
    for (pairs.items) |p| {
        if (match[p.n] != null or used[p.o]) continue;
        match[p.n] = p.o;
        used[p.o] = true;
    }
    return match;
}

pub fn diff(gpa: Allocator, before: *const Snapshot, after: *const Snapshot) Allocator.Error!Change {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const match = try matchColumns(a, before, after);
    const cols = try a.alloc(ColumnChange, after.columns.len);
    for (after.columns, cols, 0..) |nc, *cc, n| {
        const panes = try a.alloc(PaneChange, nc.ids.len);
        for (nc.ids, panes, 0..) |id, *pc, i| {
            const origin: Origin = if (before.find(id)) |old|
                .{ .moved = old }
            else
                try entry(a, before, after, match, n, i, .pane);
            pc.* = .{ .id = try a.dupe(u8, id), .origin = origin };
        }
        const dividers = try a.alloc(DividerChange, if (nc.ids.len > 0) nc.ids.len - 1 else 0);
        for (dividers, 0..) |*dc, d| {
            const old_col = match[n];
            dc.origin = if (old_col != null and d + 1 < before.columns[old_col.?].ids.len)
                .{ .moved = .{ .col = old_col.?, .row = d } }
            else
                try entry(a, before, after, match, n, d, .divider);
        }
        cc.* = .{ .from = match[n], .panes = panes, .dividers = dividers };
    }

    var leaving: std.ArrayList(Leaving) = .empty;
    for (before.columns, 0..) |oc, o| {
        for (oc.ids, 0..) |id, i| {
            if (after.find(id) != null) continue;
            const above = if (i > 0 and after.find(oc.ids[i - 1]) != null) oc.ids[i - 1] else null;
            const below = if (i + 1 < oc.ids.len and after.find(oc.ids[i + 1]) != null) oc.ids[i + 1] else null;
            try leaving.append(a, .{
                .id = try a.dupe(u8, id),
                .old = .{ .col = o, .row = i },
                .alone = oc.ids.len == 1,
                .above = if (above) |x| try a.dupe(u8, x) else null,
                .below = if (below) |x| try a.dupe(u8, x) else null,
            });
        }
    }

    // Every allocation before the arena's state is copied into the result.
    const leaving_slice = try leaving.toOwnedSlice(a);
    const focused = if (after.focused) |f| try a.dupe(u8, f) else null;
    return .{
        .arena = arena,
        .columns = cols,
        .leaving = leaving_slice,
        .focused = focused,
        .structural = !sameStructure(before, after),
    };
}

const ElementKind = enum { pane, divider };

/// app.js animateStrip `entryRect`. For a pane at row i of new column n:
/// the pane above it (row i−1) if it had an old box, else the pane below
/// (row i+1); for divider i, the pane above it is row i and below is i+1.
/// Then the old column matched to new column n−1, else to n+1, else in place.
fn entry(a: Allocator, before: *const Snapshot, after: *const Snapshot, match: []const ?usize, n: usize, i: usize, kind: ElementKind) Allocator.Error!Origin {
    const ids = after.columns[n].ids;
    const above_row: ?usize = switch (kind) {
        .pane => if (i > 0) i - 1 else null,
        .divider => i,
    };
    const below_row: ?usize = switch (kind) {
        .pane => i + 1,
        .divider => i + 1,
    };
    if (above_row) |r| if (before.find(ids[r])) |old| return .{ .below = .{ .id = try a.dupe(u8, ids[r]), .old = old } };
    if (below_row) |r| if (r < ids.len) if (before.find(ids[r])) |old| return .{ .above = .{ .id = try a.dupe(u8, ids[r]), .old = old } };
    if (n > 0) if (match[n - 1]) |o| return .{ .after_column = o };
    if (n + 1 < match.len) if (match[n + 1]) |o| return .{ .before_column = o };
    return .in_place;
}

fn sameStructure(a: *const Snapshot, b: *const Snapshot) bool {
    if (a.columns.len != b.columns.len) return false;
    for (a.columns, b.columns) |x, y| {
        if (x.full != y.full or x.ids.len != y.ids.len) return false;
        for (x.ids, y.ids) |p, q| if (!std.mem.eql(u8, p, q)) return false;
        for (x.sizes, y.sizes) |p, q| if (p != q) return false;
    }
    return true;
}
