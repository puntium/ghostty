//! The workspace model: a horizontal strip of columns, each a vertical stack
//! of panes (a terminal session or a file browser), in the style of niri /
//! PaperWM. Port of the layout half of `electron/ui/app.js` (layout helpers,
//! session actions, pane commands); every command keeps that code's exact
//! semantics, including its edge cases. No GTK, no pixels beyond the
//! divider drag (whose arithmetic is in pixels in app.js too).
//!
//! Ownership: the Layout owns every Pane and Column (heap-allocated, so
//! `*Pane` / `*Column` stay valid while the pane / column exists). Pane ids
//! are owned copies. A pane leaves memory when it is removed (`remove`); a
//! column when its last pane leaves it.
//!
//! Invariants (checked by `check`, which the tests run after every command):
//! no empty column; `sizes` parallel to `panes`, every weight finite and > 0;
//! each column's `active` is one of its panes; ids are unique; `focused` is a
//! pane of the layout, and null only when the layout is empty.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Layout = @This();

/// Panes whose id starts with this are file browsers (app.js `isFilesId`);
/// every other id is a terminal session id from the server.
pub const files_prefix = "files-";

pub const Kind = enum { terminal, files };

pub fn kindOf(id: []const u8) Kind {
    return if (std.mem.startsWith(u8, id, files_prefix)) .files else .terminal;
}

pub const Pane = struct {
    /// Terminal: the server's session id. Files: `files-<random>`.
    id: []const u8,
    kind: Kind,
    /// Files panes only: the browser's own state, an opaque JSON object as
    /// text (app.js keeps `{type, dir, cursor}` here). Null: none saved yet.
    state: ?[]const u8 = null,

    pub fn sessionId(self: *const Pane) ?[]const u8 {
        return if (self.kind == .terminal) self.id else null;
    }
};

pub const Column = struct {
    panes: std.ArrayList(*Pane) = .empty,
    /// Flex weights of the stack, parallel to `panes`; only their ratios
    /// matter (`width.stackGeometry` normalises).
    sizes: std.ArrayList(f64) = .empty,
    /// The pane that takes focus when the column is entered from the side.
    active: *Pane,
    /// ⌘F: the column spans the whole window instead of the width rule.
    full: bool = false,

    pub fn indexOf(self: *const Column, pane: *const Pane) ?usize {
        for (self.panes.items, 0..) |p, i| if (p == pane) return i;
        return null;
    }

    pub fn len(self: *const Column) usize {
        return self.panes.items.len;
    }
};

pub const Position = struct { col: usize, row: usize };

pub const Horizontal = enum {
    left,
    right,
    fn delta(self: Horizontal) isize {
        return if (self == .left) -1 else 1;
    }
};

pub const Vertical = enum {
    up,
    down,
    fn delta(self: Vertical) isize {
        return if (self == .up) -1 else 1;
    }
};

pub const Direction = enum { left, right, up, down };

pub const Error = Allocator.Error || error{
    /// The id is already in the layout.
    DuplicateId,
    /// A terminal id with the files prefix, a files id without it, or an
    /// empty id.
    InvalidId,
    /// A files state that is not a JSON object.
    InvalidState,
};

gpa: Allocator,
columns: std.ArrayList(*Column) = .empty,
focused: ?*Pane = null,

pub fn init(gpa: Allocator) Layout {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Layout) void {
    for (self.columns.items) |col| {
        for (col.panes.items) |p| self.destroyPane(p);
        self.destroyColumn(col);
    }
    self.columns.deinit(self.gpa);
    self.* = undefined;
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

pub fn isEmpty(self: *const Layout) bool {
    return self.columns.items.len == 0;
}

pub fn paneCount(self: *const Layout) usize {
    var n: usize = 0;
    for (self.columns.items) |c| n += c.len();
    return n;
}

pub fn find(self: *const Layout, id: []const u8) ?*Pane {
    for (self.columns.items) |c| {
        for (c.panes.items) |p| if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

pub fn position(self: *const Layout, pane: *const Pane) ?Position {
    for (self.columns.items, 0..) |c, ci| {
        if (c.indexOf(pane)) |i| return .{ .col = ci, .row = i };
    }
    return null;
}

pub fn positionOf(self: *const Layout, id: []const u8) ?Position {
    const p = self.find(id) orelse return null;
    return self.position(p);
}

pub fn columnIndexOf(self: *const Layout, pane: *const Pane) ?usize {
    return if (self.position(pane)) |pos| pos.col else null;
}

pub fn focusedId(self: *const Layout) ?[]const u8 {
    return if (self.focused) |f| f.id else null;
}

pub fn focusedPosition(self: *const Layout) ?Position {
    return if (self.focused) |f| self.position(f) else null;
}

/// The column the focused pane is in.
pub fn focusedColumn(self: *const Layout) ?usize {
    return if (self.focusedPosition()) |pos| pos.col else null;
}

// ---------------------------------------------------------------------------
// Allocation helpers
// ---------------------------------------------------------------------------

fn createPane(self: *Layout, id: []const u8, state: ?[]const u8) Allocator.Error!*Pane {
    const p = try self.gpa.create(Pane);
    errdefer self.gpa.destroy(p);
    const id_copy = try self.gpa.dupe(u8, id);
    errdefer self.gpa.free(id_copy);
    const state_copy = if (state) |s| try self.gpa.dupe(u8, s) else null;
    p.* = .{ .id = id_copy, .kind = kindOf(id), .state = state_copy };
    return p;
}

fn destroyPane(self: *Layout, p: *Pane) void {
    self.gpa.free(p.id);
    if (p.state) |s| self.gpa.free(s);
    self.gpa.destroy(p);
}

/// app.js `newColumn`: `{ panes: [id], sizes: [1], active: id }`.
fn createColumn(self: *Layout, pane: *Pane) Allocator.Error!*Column {
    const col = try self.gpa.create(Column);
    errdefer self.gpa.destroy(col);
    col.* = .{ .active = pane };
    errdefer col.panes.deinit(self.gpa);
    try col.panes.append(self.gpa, pane);
    errdefer col.sizes.deinit(self.gpa);
    try col.sizes.append(self.gpa, 1);
    return col;
}

fn destroyColumn(self: *Layout, col: *Column) void {
    col.panes.deinit(self.gpa);
    col.sizes.deinit(self.gpa);
    self.gpa.destroy(col);
}

/// Validates a new pane's id against the layout and the kind it should be.
fn checkNewId(self: *const Layout, id: []const u8, kind: Kind) Error!void {
    if (id.len == 0 or kindOf(id) != kind) return error.InvalidId;
    if (kind == .files and id.len == files_prefix.len) return error.InvalidId;
    if (self.find(id) != null) return error.DuplicateId;
}

/// A files state must be a JSON object (what app.js stores). Nesting is
/// capped so that re-serialising it can never overflow a stack.
pub const max_state_depth = 64;

pub fn validState(gpa: Allocator, text: []const u8) Allocator.Error!bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return v == .object and jsonDepth(v, 0) <= max_state_depth;
}

/// Depth of a JSON value (a scalar is 0, `{}` is 1); stops counting past
/// the cap so a hostile document costs at most cap levels of recursion.
pub fn jsonDepth(v: std.json.Value, level: usize) usize {
    if (level > max_state_depth) return level;
    var deepest = level;
    switch (v) {
        .array => |a| {
            deepest = level + 1;
            for (a.items) |item| deepest = @max(deepest, jsonDepth(item, level + 1));
        },
        .object => |o| {
            deepest = level + 1;
            for (o.values()) |item| deepest = @max(deepest, jsonDepth(item, level + 1));
        },
        else => {},
    }
    return deepest;
}

// ---------------------------------------------------------------------------
// Layout helpers (app.js insertIntoColumn / removeFromColumn / focusAfterRemoval)
// ---------------------------------------------------------------------------

/// The new pane gets the column's average weight, i.e. an equal share of a
/// column that was evenly split and a middling one of a resized one. It
/// becomes the column's active pane.
fn insertIntoColumn(self: *Layout, col: *Column, pane: *Pane, index: usize) Allocator.Error!void {
    try col.panes.ensureUnusedCapacity(self.gpa, 1);
    try col.sizes.ensureUnusedCapacity(self.gpa, 1);
    var sum: f64 = 0;
    for (col.sizes.items) |w| sum += w;
    const avg: f64 = if (col.sizes.items.len > 0) sum / @as(f64, @floatFromInt(col.sizes.items.len)) else 1;
    col.panes.insertAssumeCapacity(index, pane);
    col.sizes.insertAssumeCapacity(index, avg);
    col.active = pane;
}

/// Removes the pane from its column (the pane itself stays allocated); an
/// emptied column disappears with it. If the pane was the column's active
/// one, the pane now at its index (else the new last) becomes active.
fn removeFromColumn(self: *Layout, pane: *Pane) void {
    const pos = self.position(pane) orelse return;
    const col = self.columns.items[pos.col];
    _ = col.panes.orderedRemove(pos.row);
    _ = col.sizes.orderedRemove(pos.row);
    if (col.panes.items.len == 0) {
        _ = self.columns.orderedRemove(pos.col);
        self.destroyColumn(col);
    } else if (col.active == pane) {
        col.active = col.panes.items[@min(pos.row, col.panes.items.len - 1)];
    }
}

/// The pane that should take focus once `pane` goes away: the next one
/// down its stack, else the one above, else the column to the right's
/// active pane, else the left one's.
fn focusAfterRemoval(self: *const Layout, pane: *const Pane) ?*Pane {
    const pos = self.position(pane) orelse return null;
    const cols = self.columns.items;
    const col = cols[pos.col];
    if (pos.row + 1 < col.len()) return col.panes.items[pos.row + 1];
    if (pos.row > 0) return col.panes.items[pos.row - 1];
    if (pos.col + 1 < cols.len) return cols[pos.col + 1].active;
    if (pos.col > 0) return cols[pos.col - 1].active;
    return null;
}

// ---------------------------------------------------------------------------
// Session actions
// ---------------------------------------------------------------------------

/// ⌘↩: a new terminal (the server already created session `id`) as its own
/// column immediately right of the focused one, or at the end of the strip
/// when nothing is focused; it takes focus.
pub fn newTerminal(self: *Layout, id: []const u8) Error!void {
    try self.checkNewId(id, .terminal);
    try self.openInNewColumn(id, null);
}

/// ⌘⇧↩: a new file browser, placed like `newTerminal`. `state` is its
/// initial state (a JSON object; app.js starts at `{"type":"files","dir":"~","cursor":null}`)
/// or null.
pub fn newFiles(self: *Layout, id: []const u8, state: ?[]const u8) Error!void {
    try self.checkNewId(id, .files);
    if (state) |s| if (!try validState(self.gpa, s)) return error.InvalidState;
    try self.openInNewColumn(id, state);
}

fn openInNewColumn(self: *Layout, id: []const u8, state: ?[]const u8) Allocator.Error!void {
    const pane = try self.createPane(id, state);
    errdefer self.destroyPane(pane);
    const col = try self.createColumn(pane);
    errdefer self.destroyColumn(col);
    const at = if (self.focusedColumn()) |ci| ci + 1 else self.columns.items.len;
    try self.columns.insert(self.gpa, at, col);
    self.focused = pane;
}

/// ⌥⌘↩: a new terminal stacked directly below the focused pane, with the
/// column's average weight; it takes focus and becomes the column's active
/// pane. With nothing focused this is `newTerminal`.
pub fn newTerminalBelow(self: *Layout, id: []const u8) Error!void {
    const f = self.focused orelse return self.newTerminal(id);
    try self.checkNewId(id, .terminal);
    const pos = self.position(f).?;
    const col = self.columns.items[pos.col];
    const pane = try self.createPane(id, null);
    errdefer self.destroyPane(pane);
    try self.insertIntoColumn(col, pane, pos.row + 1);
    self.focused = pane;
}

/// Close a pane (⌘W / ✕ on the focused one; a session that exited or is
/// gone on the host for any other): it leaves the layout and is freed. If it
/// was focused, focus goes to the next pane down its stack, else the one
/// above, else the right neighbour column's active pane, else the left
/// one's. Returns false if no pane has this id.
pub fn remove(self: *Layout, id: []const u8) bool {
    const pane = self.find(id) orelse return false;
    if (self.focused == pane) self.focused = self.focusAfterRemoval(pane);
    self.removeFromColumn(pane);
    self.destroyPane(pane);
    return true;
}

/// Replace a files pane's opaque state (the browser saves as it navigates).
pub fn setPaneState(self: *Layout, id: []const u8, state: ?[]const u8) Error!void {
    const pane = self.find(id) orelse return error.InvalidId;
    if (pane.kind != .files) return error.InvalidId;
    if (state) |s| if (!try validState(self.gpa, s)) return error.InvalidState;
    const copy = if (state) |s| try self.gpa.dupe(u8, s) else null;
    if (pane.state) |old| self.gpa.free(old);
    pane.state = copy;
}

// ---------------------------------------------------------------------------
// Focus
// ---------------------------------------------------------------------------

/// Focus bookkeeping for a click (app.js `setFocus`): the pane becomes
/// focused and its column's active pane. Returns whether either changed
/// (app.js saves the layout only then; it reveals the column either way).
pub fn setFocus(self: *Layout, id: []const u8) bool {
    const pane = self.find(id) orelse return false;
    return self.focusPane(pane);
}

fn focusPane(self: *Layout, pane: *Pane) bool {
    const ci = self.columnIndexOf(pane) orelse return false;
    const col = self.columns.items[ci];
    if (self.focused == pane and col.active == pane) return false;
    self.focused = pane;
    col.active = pane;
    return true;
}

/// ⌘←/→: the neighbouring column's active pane; ⌘↑/↓: the neighbour in
/// the stack. Nothing past either end. Returns true when focus moved (the
/// view then puts keyboard focus in the pane and reveals it).
pub fn focus(self: *Layout, dir: Direction) bool {
    switch (dir) {
        .left, .right => {
            // app.js: columns[columnIndexOf(focusedId) + dir], where a
            // missing focus is index -1 (so → with no focus picks column 0).
            const ci: isize = if (self.focusedColumn()) |c| @intCast(c) else -1;
            const t = ci + @as(isize, if (dir == .left) -1 else 1);
            if (t < 0 or t >= self.columns.items.len) return false;
            const target = self.columns.items[@intCast(t)].active;
            _ = self.focusPane(target);
            return true;
        },
        .up, .down => {
            const pos = self.focusedPosition() orelse return false;
            const col = self.columns.items[pos.col];
            const t = @as(isize, @intCast(pos.row)) + @as(isize, if (dir == .up) -1 else 1);
            if (t < 0 or t >= col.len()) return false;
            _ = self.focusPane(col.panes.items[@intCast(t)]);
            return true;
        },
    }
}

// ---------------------------------------------------------------------------
// Structural pane commands. Each returns whether the layout changed; the
// focused pane keeps focus throughout.
// ---------------------------------------------------------------------------

/// ⌥⌘←/→: the whole column (stack and full flag included) swaps places with
/// its neighbour on that side.
pub fn moveColumn(self: *Layout, dir: Horizontal) bool {
    const ci = self.focusedColumn() orelse return false;
    const t = @as(isize, @intCast(ci)) + dir.delta();
    if (t < 0 or t >= self.columns.items.len) return false;
    const items = self.columns.items;
    std.mem.swap(*Column, &items[ci], &items[@intCast(t)]);
    return true;
}

/// ⌥⌘↑/↓: the pane swaps places (and weights) with its stack neighbour.
pub fn movePane(self: *Layout, dir: Vertical) bool {
    const pos = self.focusedPosition() orelse return false;
    const col = self.columns.items[pos.col];
    const j = @as(isize, @intCast(pos.row)) + dir.delta();
    if (j < 0 or j >= col.len()) return false;
    const ju: usize = @intCast(j);
    std.mem.swap(*Pane, &col.panes.items[pos.row], &col.panes.items[ju]);
    std.mem.swap(f64, &col.sizes.items[pos.row], &col.sizes.items[ju]);
    return true;
}

/// ⌘[ / ⌘]: niri's consume-or-expel. A pane sharing a column splits out
/// into a new column of its own on that side; a pane alone in its column
/// merges into the neighbouring column on that side, at the bottom, with
/// that column's average weight (its own column, and that column's full
/// flag, go away); a lone pane with no column on that side stays put.
pub fn consumeOrExpel(self: *Layout, dir: Horizontal) Allocator.Error!bool {
    const f = self.focused orelse return false;
    const ci = self.columnIndexOf(f) orelse return false;
    const col = self.columns.items[ci];
    if (col.len() > 1) {
        try self.expel(f, ci, dir);
        return true;
    }
    const t = @as(isize, @intCast(ci)) + dir.delta();
    if (t < 0 or t >= self.columns.items.len) return false;
    const target = self.columns.items[@intCast(t)];
    try target.panes.ensureUnusedCapacity(self.gpa, 1);
    try target.sizes.ensureUnusedCapacity(self.gpa, 1);
    self.removeFromColumn(f);
    self.insertIntoColumn(target, f, target.len()) catch unreachable; // capacity reserved
    return true;
}

/// The (stacked) pane leaves its column for a new column of its own on
/// that side. The column it left keeps its full flag.
fn expel(self: *Layout, pane: *Pane, ci: usize, dir: Horizontal) Allocator.Error!void {
    std.debug.assert(self.columns.items[ci].len() > 1);
    const col = try self.createColumn(pane);
    errdefer self.destroyColumn(col);
    try self.columns.ensureUnusedCapacity(self.gpa, 1);
    self.removeFromColumn(pane); // its column survives: it had other panes
    self.columns.insertAssumeCapacity(if (dir == .right) ci + 1 else ci, col);
}

/// ⌘F: toggle the focused pane between the width rule and the whole
/// window. A stacked pane first splits out into a new column right of its
/// stack, and that column goes full (the stack keeps its own flag); a lone
/// pane just flips its column's flag.
pub fn toggleFull(self: *Layout) Allocator.Error!bool {
    const f = self.focused orelse return false;
    const ci = self.columnIndexOf(f) orelse return false;
    const col = self.columns.items[ci];
    if (col.len() > 1) {
        const new_col = try self.createColumn(f);
        errdefer self.destroyColumn(new_col);
        try self.columns.ensureUnusedCapacity(self.gpa, 1);
        self.removeFromColumn(f);
        new_col.full = true;
        self.columns.insertAssumeCapacity(ci + 1, new_col);
    } else {
        col.full = !col.full;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Divider drag
// ---------------------------------------------------------------------------

/// Stacked panes never get shorter than this while a divider is dragged
/// (app.js MIN_PANE_PX), unless the pair is too short for it.
pub const min_pane_px: f64 = 110;

/// app.js makeDivider: the pointer's offset below the top of pane `i`
/// (`offset_px`, clientY − top of pane i) over the span from that top to
/// the bottom of pane i+1 (`span_px`, divider included) is the share of the
/// pair's combined weight pane i gets, clamped so neither side is shorter
/// than `min_px` (at most 45 % of the span each way).
pub fn dividerRatio(offset_px: f64, span_px: f64, min_px: f64) f64 {
    const min = @min(min_px / span_px, 0.45);
    return @min(1 - min, @max(min, offset_px / span_px));
}

/// Drag divider `i` of column `col_index` (between panes i and i+1).
/// `width.StackGeometry.dividerSpan` gives `span_px`. Returns false (and
/// changes nothing) for an out-of-range divider or a degenerate span; app.js
/// would write NaN weights there, which this model never holds.
pub fn dragDivider(self: *Layout, col_index: usize, i: usize, offset_px: f64, span_px: f64, min_px: f64) bool {
    if (col_index >= self.columns.items.len) return false;
    const col = self.columns.items[col_index];
    if (i + 1 >= col.len()) return false;
    if (!(span_px > 0) or !std.math.isFinite(span_px) or !std.math.isFinite(offset_px)) return false;
    const sum = col.sizes.items[i] + col.sizes.items[i + 1];
    const ratio = dividerRatio(offset_px, span_px, min_px);
    const a = sum * ratio;
    const b = sum * (1 - ratio);
    if (!(a > 0) or !(b > 0) or !std.math.isFinite(a) or !std.math.isFinite(b)) return false;
    col.sizes.items[i] = a;
    col.sizes.items[i + 1] = b;
    return true;
}

// ---------------------------------------------------------------------------
// Commands by name (app.js PANE_COMMANDS; the shell's keymap and menu)
// ---------------------------------------------------------------------------

pub const Command = enum {
    new_terminal,
    new_files,
    new_terminal_below,
    close_pane,
    toggle_full,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    move_column_left,
    move_column_right,
    move_pane_up,
    move_pane_down,
    consume_expel_left,
    consume_expel_right,

    /// The app.js name: `new-terminal`, `focus-left`, …
    pub fn name(self: Command) []const u8 {
        return switch (self) {
            inline else => |c| comptime blk: {
                const tag = @tagName(c);
                var buf: [tag.len]u8 = undefined;
                for (tag, 0..) |ch, k| buf[k] = if (ch == '_') '-' else ch;
                const final = buf;
                break :blk &final;
            },
        };
    }

    pub fn fromName(s: []const u8) ?Command {
        for (std.enums.values(Command)) |c| {
            if (std.mem.eql(u8, s, c.name())) return c;
        }
        return null;
    }

    /// The commands the shell carries out itself, because they need the
    /// server first (a new session id) or after (killing the session):
    /// new_terminal → `newTerminal`, new_terminal_below → `newTerminalBelow`,
    /// new_files → `newFiles`, close_pane → `remove(focusedId)`.
    pub fn needsShell(self: Command) bool {
        return switch (self) {
            .new_terminal, .new_files, .new_terminal_below, .close_pane => true,
            else => false,
        };
    }
};

/// Run one of the pure layout commands (`!cmd.needsShell()`); returns
/// whether anything changed (for the focus commands: whether focus moved).
/// The shell-side commands return false without doing anything.
pub fn run(self: *Layout, cmd: Command) Allocator.Error!bool {
    return switch (cmd) {
        .new_terminal, .new_files, .new_terminal_below, .close_pane => false,
        .toggle_full => try self.toggleFull(),
        .focus_left => self.focus(.left),
        .focus_right => self.focus(.right),
        .focus_up => self.focus(.up),
        .focus_down => self.focus(.down),
        .move_column_left => self.moveColumn(.left),
        .move_column_right => self.moveColumn(.right),
        .move_pane_up => self.movePane(.up),
        .move_pane_down => self.movePane(.down),
        .consume_expel_left => try self.consumeOrExpel(.left),
        .consume_expel_right => try self.consumeOrExpel(.right),
    };
}

// ---------------------------------------------------------------------------
// Building from parts (persistence, tests)
// ---------------------------------------------------------------------------

/// Append a column holding these panes (ids must be new and unique; the
/// kinds follow from the ids) with these weights (each finite and > 0).
/// `active` is an index into `ids`. Does not touch focus. For persistence
/// and tests; commands are the normal way to change a layout.
pub fn appendColumn(
    self: *Layout,
    ids: []const []const u8,
    sizes: []const f64,
    active: usize,
    full: bool,
) Error!void {
    std.debug.assert(ids.len > 0 and ids.len == sizes.len and active < ids.len);
    for (ids, 0..) |id, k| {
        if (id.len == 0) return error.InvalidId;
        if (self.find(id) != null) return error.DuplicateId;
        for (ids[0..k]) |other| if (std.mem.eql(u8, id, other)) return error.DuplicateId;
    }
    try self.columns.ensureUnusedCapacity(self.gpa, 1);
    const first = try self.createPane(ids[0], null);
    const col = self.createColumn(first) catch |err| {
        self.destroyPane(first);
        return err;
    };
    errdefer {
        for (col.panes.items) |p| self.destroyPane(p);
        self.destroyColumn(col);
    }
    col.sizes.items[0] = sizes[0];
    for (ids[1..], sizes[1..]) |id, w| {
        try col.panes.ensureUnusedCapacity(self.gpa, 1);
        try col.sizes.ensureUnusedCapacity(self.gpa, 1);
        const p = try self.createPane(id, null);
        col.panes.appendAssumeCapacity(p);
        col.sizes.appendAssumeCapacity(w);
    }
    col.active = col.panes.items[active];
    col.full = full;
    self.columns.appendAssumeCapacity(col);
}

/// Like `newTerminal`/`newFiles` placement-wise but always at the end and
/// without focusing (reconciliation: a session opened elsewhere).
pub fn appendNewColumn(self: *Layout, id: []const u8) Error!void {
    if (id.len == 0) return error.InvalidId;
    if (self.find(id) != null) return error.DuplicateId;
    try self.columns.ensureUnusedCapacity(self.gpa, 1);
    const pane = try self.createPane(id, null);
    const col = self.createColumn(pane) catch |err| {
        self.destroyPane(pane);
        return err;
    };
    self.columns.appendAssumeCapacity(col);
}

/// Drop a pane without the focus fall-through of `remove` (reconciliation).
/// Focus is cleared if it was this pane.
pub fn drop(self: *Layout, pane: *Pane) void {
    if (self.focused == pane) self.focused = null;
    self.removeFromColumn(pane);
    self.destroyPane(pane);
}

/// What app.js render() does before drawing: a focus that names no pane
/// falls back to the first column's active pane.
pub fn normalizeFocus(self: *Layout) void {
    if (self.focused) |f| if (self.position(f) != null) return;
    self.focused = if (self.columns.items.len > 0) self.columns.items[0].active else null;
}

// ---------------------------------------------------------------------------
// Invariants
// ---------------------------------------------------------------------------

pub fn check(self: *const Layout) !void {
    var count: usize = 0;
    for (self.columns.items, 0..) |col, ci| {
        if (col.len() == 0) return error.EmptyColumn;
        if (col.sizes.items.len != col.len()) return error.SizesMismatch;
        for (col.sizes.items) |w| if (!(w > 0) or !std.math.isFinite(w)) return error.BadWeight;
        if (col.indexOf(col.active) == null) return error.ActiveNotInColumn;
        for (col.panes.items, 0..) |p, i| {
            if (p.kind != kindOf(p.id)) return error.KindMismatch;
            count += 1;
            for (self.columns.items[0 .. ci + 1], 0..) |other, cj| {
                const end = if (cj == ci) i else other.len();
                for (other.panes.items[0..end]) |q| if (std.mem.eql(u8, p.id, q.id)) return error.DuplicateId;
            }
        }
    }
    if (self.focused) |f| {
        if (self.position(f) == null) return error.FocusDangling;
    } else if (count > 0) return error.NoFocus;
}
