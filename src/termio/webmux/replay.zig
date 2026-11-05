//! Snapshot replay: turn whatever the terminal holds into exactly the
//! host's view of the session.
//!
//! The host's snapshot (host/internal/ptyhost/snapshot.go) is libghostty's
//! VT formatter output for its mirror terminal, at the mirror's size
//! (`cols` × `rows` in the frame): scrollback and screen, then modes, the
//! scrolling region, cursor position, pen, open hyperlink and Kitty keyboard
//! flags; on the alternate screen, the primary part, `?1049h`, then the
//! alternate part. Its cursor position (CUP) and scrolling region are
//! absolute coordinates on a grid of that size.
//!
//! The local grid is usually a different size. Feeding the snapshot at the
//! local size (what the Electron client does with xterm.js) puts the cursor
//! and scroll region on the wrong rows whenever the heights differ, and
//! wraps remote lines at the wrong column. So instead:
//!
//!   1. CAN + RIS through the stream: abort any half-parsed sequence left
//!      by a dropped socket, then a full reset (clears scrollback, both
//!      screens, modes, Kitty flags, hyperlink state, title).
//!   2. Resize the (now empty) terminal to the snapshot's grid.
//!   3. Feed the snapshot through the same stream as ordinary output, so
//!      every mode and its side effects are applied as they would be live.
//!   4. Resize back to the local grid. This is Ghostty's own resize with
//!      reflow, the same code the host's libghostty mirror runs when we
//!      report our size right after, so local and remote state stay in step.
//!
//! `apply` does it in one call under the caller's lock (tests). The live
//! path (`Webmux.sinkSnapshot`) uses `Replay` in steps and releases the
//! renderer lock between slices, with synchronized output (mode 2026) held
//! on so the renderer draws no intermediate state.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");

/// CAN (abort any escape sequence in progress) then RIS (full reset).
pub const reset_sequence = "\x18\x1bc";

pub const CellSize = struct { width: u32, height: u32 };

pub const Strategy = enum {
    /// Replay at the snapshot's grid, then resize to the local grid (used).
    remote_grid,
    /// Replay straight into the local grid, as the Electron client does
    /// (kept for the fidelity comparison test).
    local_grid,
};

/// A replay in steps, so the caller can release its lock between slices
/// (`Webmux.sinkSnapshot`): `begin` (reset, resize to the snapshot grid),
/// any number of `feed`, then `finish` (resize to the local grid).
pub const Replay = struct {
    local_cols: u16,
    local_rows: u16,
    cell: ?CellSize,
    resized: bool,

    /// Reset the terminal and size it for the snapshot. `stream` is
    /// anything with `nextSlice([]const u8) void` that drives `term`
    /// (Termio's StreamHandler stream, or `term.vtStream()` in tests).
    pub fn begin(
        alloc: Allocator,
        term: *terminal.Terminal,
        stream: anytype,
        remote_cols: u16,
        remote_rows: u16,
        cell: ?CellSize,
        strategy: Strategy,
    ) Replay {
        const local_cols: u16 = @intCast(term.cols);
        const local_rows: u16 = @intCast(term.rows);
        reset(stream);

        const resize_for_replay = strategy == .remote_grid and remote_cols > 0 and remote_rows > 0 and
            (remote_cols != local_cols or remote_rows != local_rows);
        var resized = false;
        if (resize_for_replay) {
            if (term.resize(alloc, .{
                .cols = remote_cols,
                .rows = remote_rows,
                .cell_size_px = if (cell) |c| .{ .width = c.width, .height = c.height } else null,
            })) |_| {
                resized = true;
            } else |err| {
                std.log.scoped(.io_webmux).warn("webmux: snapshot-size resize failed err={}; replaying at local size", .{err});
            }
        }
        return .{ .local_cols = local_cols, .local_rows = local_rows, .cell = cell, .resized = resized };
    }

    pub fn feed(stream: anytype, data: []const u8) void {
        stream.nextSlice(data);
    }

    /// Resize to the local grid: the one at `begin`, or `local` if the
    /// local grid changed meanwhile.
    pub fn finish(self: *const Replay, alloc: Allocator, term: *terminal.Terminal, local: ?struct { cols: u16, rows: u16 }) void {
        const cols = if (local) |l| l.cols else self.local_cols;
        const rows = if (local) |l| l.rows else self.local_rows;
        if (!self.resized and term.cols == cols and term.rows == rows) return;
        term.resize(alloc, .{
            .cols = cols,
            .rows = rows,
            .cell_size_px = if (self.cell) |c| .{ .width = c.width, .height = c.height } else null,
        }) catch |err| {
            std.log.scoped(.io_webmux).warn("webmux: resize back after snapshot failed err={}", .{err});
        };
    }
};

/// Abort any escape sequence a dropped socket left half parsed, then a
/// full reset. CAN only when the parser is mid-sequence: in the ground
/// state it is just an invalid C0 that the stream logs (audit D-13).
fn reset(stream: anytype) void {
    const S = @typeInfo(@TypeOf(stream)).pointer.child;
    const in_ground = if (comptime @hasDecl(S, "ground")) stream.ground() else false;
    if (!in_ground) stream.nextSlice(reset_sequence[0..1]);
    stream.nextSlice(reset_sequence[1..]);
}

/// The whole replay in one call (tests; the caller holds the lock).
pub fn apply(
    alloc: Allocator,
    term: *terminal.Terminal,
    stream: anytype,
    data: []const u8,
    remote_cols: u16,
    remote_rows: u16,
    cell: ?CellSize,
    strategy: Strategy,
    cancel: ?*const std.atomic.Value(bool),
) void {
    const r = Replay.begin(alloc, term, stream, remote_cols, remote_rows, cell, strategy);
    var off: usize = 0;
    while (off < data.len) {
        if (cancel) |c| if (c.load(.acquire)) break;
        const end = @min(data.len, off + 16 * 1024);
        Replay.feed(stream, data[off..end]);
        off = end;
    }
    r.finish(alloc, term, null);
}
