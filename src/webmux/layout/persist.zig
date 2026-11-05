//! The layout on disk, and startup reconciliation with the server.
//!
//! File: `$XDG_STATE_HOME/webmux-gtk/layout/<host-slug>.json` (`statePath`),
//! one document holding what the Electron client keeps in two localStorage
//! keys, `webmux-layout` (`{columns, focused}`) and `webmux-widgets` (the
//! file browsers' state by pane id):
//!
//!     {"version":1,
//!      "columns":[{"panes":["s1","files-x"],"sizes":[1,0.5],"active":"s1","full":false}],
//!      "focused":"s1",
//!      "widgets":{"files-x":{"type":"files","dir":"~","cursor":null}}}
//!
//! The file is untrusted. `parse` never fails on content (only on memory):
//! anything malformed is dropped the way app.js `loadLayout` /
//! `sanitizeColumns` drop it, and a document it cannot use at all is an
//! empty layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Layout = @import("Layout.zig");

pub const version = 1;

// ---------------------------------------------------------------------------
// Serialise
// ---------------------------------------------------------------------------

pub fn serialize(gpa: Allocator, layout: *const Layout) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeLayout(layout, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeLayout(layout: *const Layout, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("version");
    try s.write(version);
    try s.objectField("columns");
    try s.beginArray();
    for (layout.columns.items) |col| {
        try s.beginObject();
        try s.objectField("panes");
        try s.beginArray();
        for (col.panes.items) |p| try s.write(p.id);
        try s.endArray();
        try s.objectField("sizes");
        try s.beginArray();
        for (col.sizes.items) |x| try s.write(x);
        try s.endArray();
        try s.objectField("active");
        try s.write(col.active.id);
        try s.objectField("full");
        try s.write(col.full);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("focused");
    try s.write(layout.focusedId());
    try s.objectField("widgets");
    try s.beginObject();
    for (layout.columns.items) |col| {
        for (col.panes.items) |p| {
            const state = p.state orelse continue;
            try s.objectField(p.id);
            try s.beginWriteRaw();
            try s.writer.writeAll(state);
            s.endWriteRaw();
        }
    }
    try s.endObject();
    try s.endObject();
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

/// Build a layout from a saved document. Mirrors app.js loadLayout +
/// sanitizeColumns:
/// - unparseable JSON, a root that is not an object, no `columns` array, or
///   another `version` → an empty layout;
/// - a column that is not an object with a `panes` array is skipped;
/// - a pane id that is not a string (app.js also accepts numbers; server
///   ids are strings, so a number never reconciles there either), is
///   empty, or repeats an id seen earlier in the document, is skipped
///   (with its weight);
/// - a weight that is not a finite number > 0 (or is missing) becomes 1;
/// - a column left with no panes is skipped;
/// - `active` must name one of the column's panes, else the first;
/// - `full` is true only if it is exactly `true`;
/// - `focused` is kept if it names a pane, else focus falls back to the
///   first column's active pane (app.js render);
/// - a widget state is kept only for a files pane of the layout, only if it
///   is a JSON object, and only up to `Layout.max_state_depth` deep.
/// At startup use `load` (parse + reconcile) instead: the saved focus can
/// name a session that only reconciliation brings into the layout.
pub fn parse(gpa: Allocator, text: []const u8) Allocator.Error!Layout {
    var saved = try parseSaved(gpa, text);
    defer if (saved.focused) |f| gpa.free(f);
    if (saved.focused) |f| saved.layout.focused = saved.layout.find(f);
    saved.layout.normalizeFocus();
    return saved.layout;
}

/// A parsed document before reconciliation: the layout (focus unset) and
/// the saved `focused` id, which may name no pane of it (app.js loadLayout:
/// "focused may name a pane that no longer exists").
pub const Saved = struct {
    layout: Layout,
    /// Owned by the layout's allocator.
    focused: ?[]u8,

    pub fn deinit(self: *Saved) void {
        if (self.focused) |f| self.layout.gpa.free(f);
        self.layout.deinit();
        self.* = undefined;
    }
};

pub fn parseSaved(gpa: Allocator, text: []const u8) Allocator.Error!Saved {
    var layout: Layout = .init(gpa);
    errdefer layout.deinit();
    var saved_focus: ?[]u8 = null;
    errdefer if (saved_focus) |f| gpa.free(f);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{
        .duplicate_field_behavior = .use_last, // JSON.parse keeps the last
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .layout = layout, .focused = null },
    };
    const empty: Saved = .{ .layout = layout, .focused = null };
    if (root != .object) return empty;
    if (root.object.get("version")) |v| {
        if (v != .integer or v.integer != version) return empty;
    }
    const columns = root.object.get("columns") orelse return empty;
    if (columns != .array) return empty;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    var sizes: std.ArrayList(f64) = .empty;
    for (columns.array.items) |col| {
        if (col != .object) continue;
        const panes = col.object.get("panes") orelse continue;
        if (panes != .array) continue;
        const raw_sizes: ?[]const std.json.Value = if (col.object.get("sizes")) |s|
            (if (s == .array) s.array.items else null)
        else
            null;
        ids.clearRetainingCapacity();
        sizes.clearRetainingCapacity();
        for (panes.array.items, 0..) |id, i| {
            // app.js keeps "" (a terminal id no session has, dropped at
            // reconciliation); it is dropped here already.
            if (id != .string or id.string.len == 0) continue;
            const gop = try seen.getOrPut(a, id.string);
            if (gop.found_existing) continue;
            try ids.append(a, id.string);
            const w: f64 = if (raw_sizes) |rs| (if (i < rs.len) weight(rs[i]) else 1) else 1;
            try sizes.append(a, w);
        }
        if (ids.items.len == 0) continue;
        var active: usize = 0;
        if (col.object.get("active")) |act| if (act == .string) {
            for (ids.items, 0..) |id, k| if (std.mem.eql(u8, id, act.string)) {
                active = k;
                break;
            };
        };
        const full = if (col.object.get("full")) |f| (f == .bool and f.bool) else false;
        layout.appendColumn(ids.items, sizes.items, active, full) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // ids are deduplicated above; an empty id cannot be appended
            // (app.js would keep it as a terminal that never reconciles).
            else => continue,
        };
    }

    if (root.object.get("focused")) |f| if (f == .string) {
        saved_focus = try gpa.dupe(u8, f.string);
    };

    if (root.object.get("widgets")) |widgets| if (widgets == .object) {
        var it = widgets.object.iterator();
        while (it.next()) |entry| {
            const pane = layout.find(entry.key_ptr.*) orelse continue;
            if (pane.kind != .files) continue;
            const v = entry.value_ptr.*;
            if (v != .object or Layout.jsonDepth(v, 0) > Layout.max_state_depth) continue;
            const text_state = try std.json.Stringify.valueAlloc(gpa, v, .{});
            if (pane.state) |old| gpa.free(old);
            pane.state = text_state;
        }
    };
    return .{ .layout = layout, .focused = saved_focus };
}

/// app.js: `Number(w)`, kept if finite and > 0, else 1. JSON numbers only:
/// app.js would also accept numeric strings and booleans (`Number("2")`),
/// which this client never writes.
fn weight(v: std.json.Value) f64 {
    const w: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return 1,
        else => return 1,
    };
    return if (std.math.isFinite(w) and w > 0) w else 1;
}

// ---------------------------------------------------------------------------
// Startup reconciliation (app.js attachExisting)
// ---------------------------------------------------------------------------

/// Reconcile a saved layout with the server's live session ids (in the
/// server's order):
/// - every terminal pane whose session is not live is dropped (in layout
///   order, each as app.js removeFromColumn: an emptied column goes, a
///   column whose active pane went activates the pane now at its index);
///   files panes are client-side and always stay;
/// - every live session the layout does not hold (opened from another
///   client) is appended as a column of its own on the right, in order;
/// - focus goes to the pane `saved_focus` names if the layout now has it
///   (also when it is a live session the saved columns lacked, which the
///   previous step just appended), else to the first column's active pane.
/// Afterwards an empty layout means "open a first terminal" (app.js
/// newSession). File-browser state is already limited to the layout's
/// panes (pruneWidgetStates). Ids in `live` that repeat, are empty, or
/// carry the files prefix are ignored (the server never sends them).
/// `saved_focus` may point into the layout (it is copied first).
pub fn reconcile(layout: *Layout, live: []const []const u8, saved_focus: ?[]const u8) Allocator.Error!void {
    const focus_id: ?[]u8 = if (saved_focus) |f| try layout.gpa.dupe(u8, f) else null;
    defer if (focus_id) |f| layout.gpa.free(f);

    // allIds() is taken before any removal; removing never reorders the
    // rest, so walking a copy of the pointers keeps app.js's order.
    var stale: std.ArrayList(*Layout.Pane) = .empty;
    defer stale.deinit(layout.gpa);
    for (layout.columns.items) |col| {
        for (col.panes.items) |p| {
            if (p.kind == .files) continue;
            if (!contains(live, p.id)) try stale.append(layout.gpa, p);
        }
    }
    for (stale.items) |p| layout.drop(p);

    for (live, 0..) |id, k| {
        if (id.len == 0 or Layout.kindOf(id) == .files) continue;
        if (contains(live[0..k], id)) continue;
        if (layout.find(id) != null) continue;
        layout.appendNewColumn(id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // checked above
        };
    }

    layout.focused = if (focus_id) |f| layout.find(f) else null;
    layout.normalizeFocus();
}

/// Startup: parse the saved document and reconcile it with the live
/// session ids (app.js loadLayout + attachExisting).
pub fn load(gpa: Allocator, text: []const u8, live: []const []const u8) Allocator.Error!Layout {
    var saved = try parseSaved(gpa, text);
    defer if (saved.focused) |f| gpa.free(f);
    errdefer saved.layout.deinit();
    try reconcile(&saved.layout, live, saved.focused);
    return saved.layout;
}

fn contains(list: []const []const u8, id: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Where the file lives
// ---------------------------------------------------------------------------

pub const PathError = Allocator.Error || error{
    /// No XDG_STATE_HOME and no HOME, or a slug that is not a plain name.
    InvalidPath,
};

/// `<state>/webmux-gtk/layout/<host-slug>.json`, where `<state>` is
/// `xdg_state_home` when it is set and absolute (the XDG rule), else
/// `<home>/.local/state`. The slug must be a single path component.
pub fn statePath(gpa: Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8, host_slug: []const u8) PathError![]u8 {
    if (host_slug.len == 0 or std.mem.eql(u8, host_slug, ".") or std.mem.eql(u8, host_slug, "..") or
        std.mem.indexOfAny(u8, host_slug, "/\x00") != null) return error.InvalidPath;
    if (xdg_state_home) |s| if (s.len > 0 and s[0] == '/') {
        return std.fmt.allocPrint(gpa, "{s}/webmux-gtk/layout/{s}.json", .{ std.mem.trimEnd(u8, s, "/"), host_slug });
    };
    const h = home orelse return error.InvalidPath;
    if (h.len == 0 or h[0] != '/') return error.InvalidPath;
    return std.fmt.allocPrint(gpa, "{s}/.local/state/webmux-gtk/layout/{s}.json", .{ std.mem.trimEnd(u8, h, "/"), host_slug });
}
