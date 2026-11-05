//! Webmux is a termio backend with no pty and no subprocess: the terminal's
//! bytes come from a webmux host's session WebSocket (`/ws?session=<id>`
//! over the host's HTTP unix socket, usually the ssh tunnel's local end),
//! and everything the terminal writes (keystrokes, paste, query replies)
//! goes back as `{"type":"input"}`. See docs/native-client.md › The backend
//! seam, and termio/webmux/Client.zig for the protocol core.
//!
//! ## How an apprt selects it
//!
//! Declare on the apprt's Surface type (`apprt.runtime.Surface`):
//!
//!     pub fn termioBackend(self: *Surface) !?termio.Webmux.Config
//!
//! `Surface.init` (core) calls it once while creating the core surface,
//! on the thread creating it. Return a Config to attach this surface to a
//! webmux session, or null for a normal local pty (`termio.Exec`). An apprt
//! that does not declare it (stock GTK, macOS) always gets Exec.
//!
//!     pub const Config = struct {
//!         socket_path: []const u8,   // host HTTP unix socket; copied
//!         session_id: []const u8,    // session to attach; copied
//!         events: EventSink = .{},   // see below
//!     };
//!
//! The strings only need to live until `termioBackend` returns to the core.
//!
//! ## Events
//!
//!     pub const EventSink = struct {
//!         userdata: ?*anyopaque = null,
//!         callback: ?*const fn (userdata: ?*anyopaque, event: *const Event) void = null,
//!     };
//!
//! `Event` (union, see webmux/Client.zig for field docs):
//!   .link_up                     socket open (first attach or reconnect)
//!   .link_down                   socket lost or first connect failed; retrying
//!   .snapshot_applied {cols, rows, remote_cols, remote_rows, bytes, pid}
//!   .title "…"                   this session's title (also on every attach)
//!   .session_title {session, title}   any session's title
//!   .exit {code}                 shell exited; final (the backend already
//!                                printed "[session exited: N]" in red)
//!   .session_error {message}     no such session; final
//!   .paste_result {mode, path}   "claude" | "path"
//!   .open_url {url, id}          dedupe by id
//!
//! The callback runs on the backend's reader thread. Slices in the event
//! are valid only during the call: copy them, marshal to the GTK main loop
//! (g_idle_add) and return. Never block on the main thread from the
//! callback: closing the surface joins this thread from the main thread.
//! No callback runs after the core surface's IO thread has stopped (i.e.
//! once `Surface.deinit` has stopped termio), so `userdata` must stay valid
//! until then.
//!
//! The terminal also processes the session's own OSC 0/2 titles, so the
//! apprt receives Ghostty's usual `set_title` action as well.
//!
//! ## Sending side-channel frames
//!
//!     webmux.send(.{ .paste_image = .{ .mime = "image/png", .data = base64 } })
//!     webmux.send(.{ .clipboard_sync = .{ .mime = "image/png", .data = base64 } })
//!
//! where `webmux` is `&core_surface.io.backend.webmux` (a `*termio.Webmux`;
//! check `core_surface.io.backend == .webmux`). Thread-safe, never blocks on
//! the socket (frames are queued and written by the backend's writer
//! thread), copies its input. Returns false when the frame was dropped
//! because no socket is open (the Electron client also drops these). Call
//! it only while the core surface is alive (the main thread, between
//! surface init and deinit, is always safe).
//!
//! ## Behaviour
//!
//!   - snapshot: the terminal is fully reset and the snapshot replayed
//!     under the renderer lock, at the snapshot's grid and then resized to
//!     the local grid (see webmux/replay.zig for why), then the local grid
//!     size is sent as `resize`. Terminal replies the replay provokes (a
//!     mode 2048 size report, focus reports, …) are discarded, so a replay
//!     never sends input.
//!   - output → the same parser path as pty output.
//!   - writes from the core (keys, paste, query replies) → `input`, after
//!     linefeed-mode translation; bytes that are not valid UTF-8 become
//!     U+FFFD (the protocol carries a JSON string and the host would make
//!     the same substitution). Writes made before the first socket opens
//!     (Ghostty's `input` config, early keys) are held and sent when it
//!     opens; after that, writes are dropped while disconnected.
//!   - grid changes → `resize`.
//!   - socket drop while online → dim "[disconnected — reconnecting…]",
//!     link_down, reconnect after 1 s doubling to 10 s; a fresh snapshot
//!     repaints. Never reconnects after exit, error, or surface close.
//!   - getProcessInfo: none (the processes are remote).
const Webmux = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const net = @import("../webmux/net.zig");
pub const Client = @import("webmux/Client.zig");
pub const replay = @import("webmux/replay.zig");

const log = std.log.scoped(.io_webmux);

pub const Event = Client.Event;
pub const EventSink = Client.EventSink;
pub const ClientFrame = net.protocol.ClientFrame;

pub const Config = struct {
    socket_path: []const u8,
    session_id: []const u8,
    events: EventSink = .{},
};

/// Heap-allocated so its address is stable while the Backend union that
/// holds this struct is moved around during Termio init.
client: *Client,

pub fn init(alloc: Allocator, cfg: Config) !Webmux {
    // The sink's ctx (the Termio) is only known at threadEnter.
    const client = try Client.create(alloc, global.io(), .{
        .ctx = undefined,
        .snapshot = sinkSnapshot,
        .output = sinkOutput,
    }, .{
        .socket_path = cfg.socket_path,
        .session_id = cfg.session_id,
        .events = cfg.events,
    });
    return .{ .client = client };
}

pub fn deinit(self: *Webmux) void {
    // threadExit has stopped the client if it was started.
    self.client.stop();
    self.client.destroy();
}

pub fn initTerminal(self: *Webmux, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *Webmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    self.client.sink.ctx = io;
    td.backend = .{ .webmux = .{} };
    try self.client.start();
}

pub fn threadExit(self: *Webmux, td: *termio.Termio.ThreadData) void {
    _ = td;
    self.client.stop();
}

pub fn focusGained(self: *Webmux, td: *termio.Termio.ThreadData, focused: bool) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(self: *Webmux, grid_size: renderer.GridSize, screen_size: renderer.ScreenSize) !void {
    _ = screen_size;
    self.client.resize(@intCast(@min(grid_size.columns, std.math.maxInt(u16))), @intCast(@min(grid_size.rows, std.math.maxInt(u16))));
}

/// Thread-safe side-channel send for the shell (see the top comment).
pub fn send(self: *Webmux, frame: ClientFrame) bool {
    return self.client.send(frame);
}

pub fn queueWrite(
    self: *Webmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    const tdw = &td.backend.webmux;
    // Replay brackets: everything the terminal wrote while replaying a
    // snapshot sits between these two markers in the termio mailbox.
    if (data.ptr == replay_begin.ptr and data.len == 1) {
        tdw.replaying = true;
        return;
    }
    if (data.ptr == replay_end.ptr and data.len == 1) {
        tdw.replaying = false;
        return;
    }
    if (tdw.replaying) {
        log.debug("webmux: dropping {d} bytes written during snapshot replay", .{data.len});
        return;
    }
    if (!linefeed) return self.client.input(data);

    // Linefeed mode (LNM): CR → CRLF, as Exec does.
    var out: std.ArrayList(u8) = try .initCapacity(alloc, data.len + 8);
    defer out.deinit(alloc);
    for (data) |c| {
        try out.append(alloc, c);
        if (c == '\r') try out.append(alloc, '\n');
    }
    self.client.input(out.items);
}

pub fn childExitedAbnormally(
    self: *Webmux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *Webmux, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    /// Between the replay markers (termio thread only).
    replaying: bool = false,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

// Mailbox markers, recognised by address. One mutable array guarantees two
// distinct addresses (identical constants could be merged).
var replay_markers: [2]u8 = .{ 0, 0 };
const replay_begin: []const u8 = replay_markers[0..1];
const replay_end: []const u8 = replay_markers[1..2];

/// Replay a snapshot without holding the renderer lock for the whole of
/// it (audit D1: a large replay froze the GTK main thread, which takes this
/// surface's lock for input, mouse, resize and focus). The lock is taken
/// per slice, so other threads get it in between; synchronized output
/// (mode 2026) stays on until the end, so the renderer, which skips
/// drawing while it is set, never shows a half-replayed screen. Replies the
/// replay provokes are bracketed by the replay markers slice by slice, so
/// keys typed meanwhile (queued between slices) are not dropped.
fn sinkSnapshot(ctx: *anyopaque, snap: *const net.protocol.Snapshot, cancel: *const std.atomic.Value(bool)) Client.GridSize {
    const io: *termio.Termio = @ptrCast(@alignCast(ctx));
    const mutex = io.renderer_state.mutex;
    const t = &io.terminal;

    const t0 = net.Conn.now();
    mutex.lockUncancelable(global.io());
    const grid: Client.GridSize = .{ .cols = t.cols, .rows = t.rows };
    // Cell size from the terminal's own (lock-protected) pixel geometry.
    const cell: ?replay.CellSize = if (t.cols > 0 and t.rows > 0 and t.width_px > 0)
        .{ .width = t.width_px / t.cols, .height = t.height_px / t.rows }
    else
        null;
    io.mailbox.send(.{ .write_stable = replay_begin }, mutex);
    const r = replay.Replay.begin(io.alloc, t, &io.terminal_stream, snap.cols, snap.rows, cell, .remote_grid);
    t.modes.set(.synchronized_output, true);
    const replay_cols = t.cols;
    const replay_rows = t.rows;
    io.mailbox.send(.{ .write_stable = replay_end }, mutex);
    mutex.unlock(global.io());
    const t1 = net.Conn.now();
    var longest: i64 = 0;

    // If something else resizes the terminal meanwhile (a window resize
    // reaching the io thread), that is the local grid to end on.
    var external: ?Client.GridSize = null;
    var last_pause = net.Conn.now();
    var off: usize = 0;
    while (off < snap.data.len) {
        if (cancel.load(.acquire)) break;
        const end = @min(snap.data.len, off + replay_slice);
        const ts = net.Conn.now();
        mutex.lockUncancelable(global.io());
        if (t.cols != replay_cols or t.rows != replay_rows) {
            external = .{ .cols = t.cols, .rows = t.rows };
        }
        io.mailbox.send(.{ .write_stable = replay_begin }, mutex);
        replay.Replay.feed(&io.terminal_stream, snap.data[off..end]);
        t.modes.set(.synchronized_output, true);
        io.mailbox.send(.{ .write_stable = replay_end }, mutex);
        mutex.unlock(global.io());
        longest = @max(longest, net.Conn.now() - ts);
        off = end;
        // Hand the lock over now and then: a bare unlock/lock lets this
        // thread take it straight back and starve a waiting main thread.
        // A pause per ~20 ms of replay keeps input latency at a frame or
        // two without stretching the replay much.
        if (net.Conn.now() - last_pause > 20 * std.time.ns_per_ms) {
            const us = replayPauseUs();
            if (us > 0) {
                const pause: std.c.timespec = .{ .sec = 0, .nsec = @as(isize, us) * std.time.ns_per_us };
                _ = std.c.nanosleep(&pause, null);
            }
            last_pause = net.Conn.now();
        }
    }

    const t2 = net.Conn.now();
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());
    defer log.debug("webmux: replay of {d} bytes: begin {d} ms, slices {d} ms (longest hold {d} ms), finish {d} ms", .{
        snap.data.len,
        @divTrunc(t1 - t0, std.time.ns_per_ms),
        @divTrunc(t2 - t1, std.time.ns_per_ms),
        @divTrunc(longest, std.time.ns_per_ms),
        @divTrunc(net.Conn.now() - t2, std.time.ns_per_ms),
    });
    const final: Client.GridSize = external orelse grid;
    r.finish(io.alloc, t, if (external) |e| .{ .cols = @intCast(e.cols), .rows = @intCast(e.rows) } else null);
    t.modes.set(.synchronized_output, false);
    io.terminal_stream.handler.termio_messaged = false;
    io.mailbox.notify();
    io.terminal_stream.handler.queueRender() catch {};
    return final;
}

/// The pause per ~20 ms of replay, in microseconds: 500, or
/// WEBMUX_GTK_REPLAY_PAUSE_US (0 disables it; for measuring its cost).
fn replayPauseUs() u32 {
    const S = struct {
        var value: ?u32 = null;
    };
    if (S.value) |v| return v;
    const v: u32 = if (std.c.getenv("WEBMUX_GTK_REPLAY_PAUSE_US")) |e|
        std.fmt.parseInt(u32, std.mem.span(e), 10) catch 500
    else
        500;
    S.value = @min(v, 100_000);
    return S.value.?;
}

/// Bytes replayed per lock hold (see `sinkSnapshot`).
const replay_slice = 4096;

fn sinkOutput(ctx: *anyopaque, data: []const u8) void {
    const io: *termio.Termio = @ptrCast(@alignCast(ctx));
    io.processOutput(data);
}

// Referenced at container level so the headless suite is found even when
// a test filter excludes this file's unnamed test.
comptime {
    if (@import("builtin").is_test) _ = @import("webmux/test.zig");
}

test {
    _ = Client;
    _ = replay;
}
