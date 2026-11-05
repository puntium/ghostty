//! The protocol core of the webmux termio backend, independent of Termio so
//! it can be driven headlessly (see test.zig): it attaches to one session's
//! WebSocket, feeds snapshots and output to a `Sink`, sends input and
//! resizes, reports events, and reconnects with backoff.
//!
//! Threads:
//!   - reader thread (owned): connect, upgrade, read frames, call the sink
//!     and the event sink, reconnect. All sink and event callbacks run here.
//!   - writer thread (owned): sends queued frames, so `send` never blocks
//!     its caller on the socket (the termio thread calls `input`/`resize`
//!     with the renderer lock held; the shell calls `send` on the GTK main
//!     thread with multi-megabyte image pastes).
//!   - any thread: `send`, `input`, `resize` (thread-safe). Frames sent
//!     before the first socket opens are held and sent once it does (so
//!     Ghostty's `input` config and keys typed into a pane that is still
//!     connecting are not lost); after that, frames are dropped while no
//!     socket is open, as the Electron client drops input while its socket
//!     is not OPEN.
//!   - `stop` (any thread but the reader/writer): starts the WebSocket close
//!     handshake on an open socket (close 1000, then the reader drains
//!     until the host's close reply, at most `close_grace_ms`), then
//!     interrupts whatever is still blocked (read, connect, reconnect sleep)
//!     and joins both threads. Reads/writes are woken with shutdown(2),
//!     sleeps with an event.
//!
//! Closing (panels D6): no socket is closed with the host's frames still
//! unread, which resets the connection. After `exit` or `error` the
//! reader keeps reading (and discarding) until the host's close frame,
//! which the WebSocket layer echoes; a client-side close sends close 1000
//! first and waits for the reply.
//!
//! Lifecycle per attach (mirrors electron/ui/app.js connect()):
//!   open → link_up; snapshot → sink.snapshot (reset + replay), events
//!   snapshot_applied + title, then a resize with the local grid; output →
//!   sink.output; exit → "[session exited: N]" line, exit event, stop
//!   for good; error → error event, stop for good; socket drop while online
//!   → dim "[disconnected — reconnecting…]" line + link_down, reconnect after
//!   1 s, doubling to 10 s, reset after each successful open.
const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = @import("../../webmux/net.zig");
const protocol = net.protocol;
const WebSocket = net.WebSocket;

const log = std.log.scoped(.io_webmux);

/// Printed locally (not sent anywhere) when an online socket drops; the
/// same text and colour as the Electron client.
pub const disconnected_line = "\r\n\x1b[33m[disconnected \u{2014} reconnecting\u{2026}]\x1b[0m\r\n";

pub const retry_initial_ms: u32 = 1000;
pub const retry_max_ms: u32 = 10_000;

pub const GridSize = struct { cols: u16, rows: u16 };

/// Where terminal bytes go. Called on the reader thread only.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Fully reset the terminal and replay the snapshot (see replay.zig).
    /// Returns the local grid size, which is then reported to the host.
    /// `cancel` becomes true when the client is stopping; the replay may
    /// then stop early (the terminal is about to be destroyed).
    snapshot: *const fn (ctx: *anyopaque, snap: *const protocol.Snapshot, cancel: *const std.atomic.Value(bool)) GridSize,
    /// Feed bytes exactly like pty output.
    output: *const fn (ctx: *anyopaque, data: []const u8) void,
};

/// Events for the shell. Delivered on the reader thread; every slice is
/// valid only during the callback (copy what you keep). The callback must
/// not block on the GTK main thread: surface close joins this thread from
/// the main thread, so marshal with g_idle_add (or similar) and return.
pub const Event = union(enum) {
    /// The WebSocket opened (first attach or a reconnect).
    link_up,
    /// The link went down (socket dropped, or the first connect failed);
    /// reconnecting. Sent once per outage, not per retry.
    link_down,
    /// A snapshot was replayed. `cols`/`rows`: local grid (reported to the
    /// host right after); `remote_*`: the size the snapshot was made at.
    snapshot_applied: struct {
        cols: u16,
        rows: u16,
        remote_cols: u16,
        remote_rows: u16,
        bytes: usize,
        pid: ?i64,
        /// Wall time of the replay (reset, feed, resize back).
        ms: u32 = 0,
    },
    /// This session's title (OSC 0/2 tracked by the host; also sent from
    /// the snapshot's `title` on every attach, possibly empty).
    title: []const u8,
    /// Any session's title changed (fanned out on every socket).
    session_title: struct { session: []const u8, title: []const u8 },
    /// The shell exited. Final: no reconnect follows.
    exit: struct { code: i64 },
    /// The host has no such session. Final: no reconnect follows.
    session_error: struct { message: []const u8 },
    /// How a pasted image was delivered ("claude" or "path").
    paste_result: struct { mode: []const u8, path: ?[]const u8 },
    /// A program in the session asked to open a URL. The host may deliver
    /// the same id on several sockets; dedupe by id.
    open_url: struct { url: []const u8, id: []const u8 },
    /// Socket lifecycle, for the connection log (the Electron page's
    /// `connect()` log lines, PARITY G-08).
    socket: Socket,

    pub const Socket = struct {
        kind: Kind,
        /// 1 for the first connect of this pane, counting up per attempt.
        attempt: u32,
        /// open/reopened: ms from the attempt's start to the open;
        /// dropped/connect_failed: ms the attempt was up (Electron upMs).
        ms: i64 = 0,
        /// WebSocket close code (1006 when the socket just ended).
        code: u16 = 1006,
        reason: []const u8 = "",
        clean: bool = false,
        /// dropped/connect_failed: the backoff before the next attempt.
        retry_in_ms: u32 = 0,
        /// snapshot: its size in bytes.
        bytes: usize = 0,

        pub const Kind = enum {
            connecting,
            reconnecting,
            open,
            reopened,
            snapshot,
            /// Closed for good: the pane closed or the session ended.
            closed,
            dropped,
            connect_failed,
        };
    };
};

pub const EventSink = struct {
    userdata: ?*anyopaque = null,
    callback: ?*const fn (userdata: ?*anyopaque, event: *const Event) void = null,

    pub fn emit(self: EventSink, ev: Event) void {
        if (self.callback) |cb| cb(self.userdata, &ev);
    }
};

pub const Options = struct {
    socket_path: []const u8,
    session_id: []const u8,
    events: EventSink = .{},
    /// Override the backoff (tests).
    retry_initial_ms: u32 = retry_initial_ms,
    retry_max_ms: u32 = retry_max_ms,
};

alloc: Allocator,
io: std.Io,
socket_path: []u8,
session_id: []u8,
target: []u8,
sink: Sink,
events: EventSink,
retry_initial: u32,
retry_max: u32,
/// The last socket's close frame (reader thread only).
close_info: CloseInfo = .{},

/// Guards everything below up to the threads.
mutex: std.Io.Mutex = .init,
/// Signalled when `queue` gains a frame, `sending` clears, or stop begins.
cond: std.Io.Condition = .init,
/// The open socket, or null while (re)connecting.
ws: ?*WebSocket = null,
/// The writer is inside a send on `ws`.
sending: bool = false,
stopping: bool = false,
/// A socket has been open at least once.
ever_open: bool = false,
queue: std.ArrayList([]u8) = .empty,

/// Wakes the reader's reconnect sleep at stop.
stop_event: std.Io.Event = .unset,
/// Set when the reader thread is done (for `stop`'s close grace).
reader_done: std.Io.Event = .unset,
/// The reader is inside a sink call (feeding output or replaying a
/// snapshot), not reading the socket. `stop`'s close grace does not run
/// meanwhile: the host's close reply cannot be read until the call
/// returns (a 4 KiB slice of scrolling output can take most of a second in
/// a Debug build).
in_sink: std.atomic.Value(bool) = .init(false),
/// Set at stop; checked between slices of a frame being fed (see `feed`).
cancel: std.atomic.Value(bool) = .init(false),

reader: ?std.Thread = null,
writer: ?std.Thread = null,

pub fn create(alloc: Allocator, io: std.Io, sink: Sink, opts: Options) !*Client {
    const socket_path = try alloc.dupe(u8, opts.socket_path);
    errdefer alloc.free(socket_path);
    const session_id = try alloc.dupe(u8, opts.session_id);
    errdefer alloc.free(session_id);
    const target = try net.api.sessionWsTarget(alloc, opts.session_id);
    errdefer alloc.free(target);
    const self = try alloc.create(Client);
    self.* = .{
        .alloc = alloc,
        .io = io,
        .socket_path = socket_path,
        .session_id = session_id,
        .target = target,
        .sink = sink,
        .events = opts.events,
        .retry_initial = opts.retry_initial_ms,
        .retry_max = opts.retry_max_ms,
    };
    return self;
}

/// Free everything. `stop` must have been called if `start` was.
pub fn destroy(self: *Client) void {
    std.debug.assert(self.reader == null and self.writer == null);
    for (self.queue.items) |f| self.alloc.free(f);
    self.queue.deinit(self.alloc);
    self.alloc.free(self.socket_path);
    self.alloc.free(self.session_id);
    self.alloc.free(self.target);
    self.alloc.destroy(self);
}

/// Start the reader and writer threads (the reader connects at once).
pub fn start(self: *Client) !void {
    self.writer = try std.Thread.spawn(.{}, writerMain, .{self});
    errdefer {
        _ = self.requestStop();
        self.writer.?.join();
        self.writer = null;
    }
    self.reader = try std.Thread.spawn(.{}, readerMain, .{self});
    self.reader.?.setName(self.io, "io-webmux") catch {};
    self.writer.?.setName(self.io, "io-webmux-w") catch {};
}

/// Stop for good and join the threads. Safe in any state (blocked read,
/// mid-connect, reconnect sleep, already exited) and idempotent. No sink or
/// event callback runs after this returns.
pub fn stop(self: *Client) void {
    if (self.requestStop() and self.reader != null) self.awaitCloseReply();
    self.interruptSocket();
    if (self.reader) |t| t.join();
    self.reader = null;
    if (self.writer) |t| t.join();
    self.writer = null;
}

/// How long `stop` waits for the host's reply to its close frame, counted
/// while the reader is reading the socket.
pub const close_grace_ms: u32 = 250;

/// Wait until the reader has read the host's close reply and finished
/// (returns at once then), or until the reader has been reading for
/// `close_grace_ms` without one (a stalled tunnel). Time the reader spends
/// inside a sink call does not count: interrupting the socket then would
/// close it with the reply unread (panels D6, seen with a Debug build and
/// a pane closed during heavy output). That time is spent anyway, as
/// `stop` joins the reader afterwards.
fn awaitCloseReply(self: *Client) void {
    const grace: i64 = @as(i64, close_grace_ms) * std.time.ns_per_ms;
    var deadline = net.Conn.now() + grace;
    while (!self.reader_done.isSet()) {
        const now = net.Conn.now();
        if (self.in_sink.load(.acquire)) {
            deadline = now + grace;
        } else if (now >= deadline) {
            break;
        }
        const step = @min(deadline - now, 5 * std.time.ns_per_ms);
        self.reader_done.waitTimeout(self.io, .{ .duration = .{
            .raw = .fromNanoseconds(@max(step, std.time.ns_per_ms)),
            .clock = .awake,
        } }) catch {};
    }
}

/// Begin stopping: no more sink or event callbacks, wake sleeps, and send
/// close 1000 on an open socket. Returns true if a close was sent (the
/// reader is draining towards the host's reply).
fn requestStop(self: *Client) bool {
    self.cancel.store(true, .release);
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    self.cond.broadcast(self.io);
    // The writer has stopped sending (it checks `stopping`); wait out a
    // send in flight, then the close goes out with `sending` held so the
    // reader cannot free the socket under it.
    while (self.sending) self.cond.waitUncancelable(self.io, &self.mutex);
    const ws = self.ws;
    if (ws != null) self.sending = true;
    self.mutex.unlock(self.io);
    self.stop_event.set(self.io);
    const ws_ = ws orelse return false;
    const sent = if (ws_.close(1000, "")) |_| true else |err| blk: {
        log.debug("webmux: close frame not sent err={}", .{err});
        break :blk false;
    };
    self.mutex.lockUncancelable(self.io);
    self.sending = false;
    self.cond.broadcast(self.io);
    self.mutex.unlock(self.io);
    return sent;
}

/// Wake a read still blocked on the socket (after the close grace).
fn interruptSocket(self: *Client) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.ws) |ws| ws.interrupt();
}

fn isStopping(self: *Client) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.stopping;
}

/// Queue a frame for the host. Thread-safe, never blocks on the socket.
/// Dropped (returns false) after stop, and while no socket is open once
/// one has been (before the first open, frames are held).
pub fn send(self: *Client, frame: protocol.ClientFrame) bool {
    const bytes = protocol.encodeClientFrameAlloc(self.alloc, frame) catch {
        log.warn("webmux: out of memory encoding a frame; dropped", .{});
        return false;
    };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.stopping or (self.ws == null and self.ever_open)) {
        self.alloc.free(bytes);
        return false;
    }
    self.queue.append(self.alloc, bytes) catch {
        self.alloc.free(bytes);
        return false;
    };
    self.cond.signal(self.io);
    return true;
}

pub fn input(self: *Client, data: []const u8) void {
    if (data.len == 0) return;
    _ = self.send(.{ .input = data });
}

pub fn resize(self: *Client, cols: u16, rows: u16) void {
    _ = self.send(.{ .resize = .{ .cols = cols, .rows = rows } });
}

fn writerMain(self: *Client) void {
    var batch: std.ArrayList([]u8) = .empty;
    defer batch.deinit(self.alloc);
    self.mutex.lockUncancelable(self.io);
    while (true) {
        while ((self.queue.items.len == 0 or self.ws == null) and !self.stopping) self.cond.waitUncancelable(self.io, &self.mutex);
        if (self.stopping) break;
        std.mem.swap(std.ArrayList([]u8), &batch, &self.queue);
        for (batch.items) |frame| {
            defer self.alloc.free(frame);
            const ws = self.ws orelse continue; // socket gone: drop
            if (self.stopping) continue;
            self.sending = true;
            self.mutex.unlock(self.io);
            ws.sendText(frame) catch |err| {
                log.debug("webmux: send failed err={}", .{err});
                // Make the reader notice promptly.
                ws.interrupt();
            };
            self.mutex.lockUncancelable(self.io);
            self.sending = false;
            self.cond.broadcast(self.io);
        }
        batch.clearRetainingCapacity();
    }
    self.mutex.unlock(self.io);
}

const Outcome = enum {
    /// The socket dropped (or never opened); reconnect.
    dropped,
    /// exit or error frame, or stop: never reconnect.
    final,
};

fn readerMain(self: *Client) void {
    defer self.reader_done.set(self.io);
    var retry_ms: u32 = 0;
    var online = false; // a socket was open since the last drop line
    var link: enum { unknown, up, down } = .unknown;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    var attempt: u32 = 0;

    while (!self.isStopping()) {
        attempt += 1;
        const started = net.Conn.now();
        self.events.emit(.{ .socket = .{ .kind = if (attempt == 1) .connecting else .reconnecting, .attempt = attempt } });
        const ws = WebSocket.connect(self.alloc, self.io, self.socket_path, self.target, .{}) catch |err| {
            log.debug("webmux: connect failed err={}", .{err});
            if (self.isStopping()) break;
            if (link != .down) {
                link = .down;
                self.events.emit(.link_down);
            }
            retry_ms = nextRetry(retry_ms, self.retry_initial, self.retry_max);
            self.events.emit(.{ .socket = .{
                .kind = .connect_failed,
                .attempt = attempt,
                .ms = msSince(started),
                .retry_in_ms = retry_ms,
            } });
            if (self.sleepOrStop(retry_ms)) break;
            continue;
        };

        // Publish the socket (unless stop raced us).
        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            ws.deinit();
            break;
        }
        self.ws = ws;
        self.ever_open = true;
        self.cond.broadcast(self.io); // the writer may hold early frames
        self.mutex.unlock(self.io);

        online = true;
        retry_ms = 0;
        link = .up;
        self.events.emit(.{ .socket = .{
            .kind = if (attempt == 1) .open else .reopened,
            .attempt = attempt,
            .ms = msSince(started),
        } });
        self.events.emit(.link_up);

        self.close_info = .{};
        const outcome = self.readLoop(ws, &arena);

        // Unpublish: interrupt any in-flight send, wait for it, then free.
        self.mutex.lockUncancelable(self.io);
        ws.interrupt();
        self.ws = null;
        while (self.sending) self.cond.waitUncancelable(self.io, &self.mutex);
        for (self.queue.items) |f| self.alloc.free(f);
        self.queue.clearRetainingCapacity();
        const stopping = self.stopping;
        self.mutex.unlock(self.io);
        ws.deinit();

        if (outcome == .final or stopping) {
            self.events.emit(.{ .socket = .{
                .kind = .closed,
                .attempt = attempt,
                .code = self.close_info.code orelse 1005,
            } });
            break;
        }

        const was_online = online;
        if (online) {
            online = false;
            self.sink.output(self.sink.ctx, disconnected_line);
        }
        if (link != .down) {
            link = .down;
            self.events.emit(.link_down);
        }
        retry_ms = nextRetry(retry_ms, self.retry_initial, self.retry_max);
        self.events.emit(.{ .socket = .{
            .kind = if (was_online) .dropped else .connect_failed,
            .attempt = attempt,
            .ms = msSince(started),
            .code = self.close_info.code orelse 1006,
            .reason = self.close_info.reasonSlice(),
            .clean = self.close_info.code != null,
            .retry_in_ms = retry_ms,
        } });
        if (self.sleepOrStop(retry_ms)) break;
    }
    log.debug("webmux: reader done session={s}", .{self.session_id});
}

fn msSince(t0: i64) i64 {
    return @divTrunc(net.Conn.now() - t0, std.time.ns_per_ms);
}

/// The server's close frame, if the last socket got one (reader thread).
const CloseInfo = struct {
    code: ?u16 = null,
    reason_buf: [123]u8 = undefined,
    reason_len: u8 = 0,

    fn reasonSlice(self: *const CloseInfo) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

/// Electron: retryDelay = min((retryDelay || 500) * 2, 10000).
fn nextRetry(prev: u32, initial: u32, max: u32) u32 {
    if (prev == 0) return @min(initial, max);
    return @min(prev *| 2, max);
}

/// Sleep `ms` unless stop is requested first. Returns true if stopping.
fn sleepOrStop(self: *Client, ms: u32) bool {
    const deadline = net.Conn.now() + @as(i64, ms) * std.time.ns_per_ms;
    while (true) {
        if (self.isStopping()) return true;
        const left = deadline - net.Conn.now();
        if (left <= 0) return self.isStopping();
        self.stop_event.waitTimeout(self.io, .{ .duration = .{
            .raw = .fromNanoseconds(left),
            .clock = .awake,
        } }) catch {};
    }
}

/// Slice size for feeding output. Parsing is fast in release builds, but a
/// 32 KiB frame of scrolling output takes seconds in a Debug build; feeding
/// in slices lets `stop` cut a frame short instead of waiting it out.
const feed_slice = 4096;

/// Feed output to the sink in slices, giving up (false) once stop begins.
fn feed(self: *Client, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        if (self.cancel.load(.acquire)) return false;
        const end = @min(data.len, off + feed_slice);
        self.in_sink.store(true, .release);
        self.sink.output(self.sink.ctx, data[off..end]);
        self.in_sink.store(false, .release);
        off = end;
    }
    return true;
}

fn readLoop(self: *Client, ws: *WebSocket, arena: *std.heap.ArenaAllocator) Outcome {
    // After exit/error: the session is over; read on (discarding) until
    // the host's close frame so the socket is never closed with it unread.
    var ended = false;
    while (true) {
        _ = arena.reset(.retain_capacity);
        const msg = ws.readMessage() catch |err| {
            log.debug("webmux: socket ended err={}", .{err});
            if (ended) return .final;
            return if (self.isStopping()) .final else .dropped;
        };
        const text = switch (msg) {
            .text => |t| t,
            .binary => continue,
            .close => |c| {
                // The WebSocket layer has echoed it (or it answers ours).
                log.debug("webmux: server closed code={?}", .{c.code});
                self.close_info.code = c.code orelse 1005;
                const n = @min(c.reason.len, self.close_info.reason_buf.len);
                @memcpy(self.close_info.reason_buf[0..n], c.reason[0..n]);
                self.close_info.reason_len = @intCast(n);
                return if (ended or self.isStopping()) .final else .dropped;
            },
        };
        // Stopping (close sent, waiting for the reply) or the session
        // ended: no more callbacks, just drain.
        if (ended or self.cancel.load(.acquire)) continue;
        const json = tolerateLoneSurrogates(arena.allocator(), text) catch text;
        const frame = protocol.parseServerFrame(arena.allocator(), json) catch |err| {
            log.warn("webmux: unparseable frame err={}", .{err});
            continue;
        };
        switch (frame) {
            .snapshot => |*snap| {
                self.events.emit(.{ .socket = .{ .kind = .snapshot, .attempt = 0, .bytes = snap.data.len } });
                const replay_t0 = net.Conn.now();
                self.in_sink.store(true, .release);
                const grid = self.sink.snapshot(self.sink.ctx, snap, &self.cancel);
                self.in_sink.store(false, .release);
                const replay_ms: u32 = @intCast(std.math.clamp(msSince(replay_t0), 0, std.math.maxInt(u32)));
                if (self.cancel.load(.acquire)) continue; // drain to the close reply
                self.events.emit(.{ .snapshot_applied = .{
                    .cols = grid.cols,
                    .rows = grid.rows,
                    .remote_cols = snap.cols,
                    .remote_rows = snap.rows,
                    .bytes = snap.data.len,
                    .pid = snap.pid,
                    .ms = replay_ms,
                } });
                self.events.emit(.{ .title = snap.title });
                self.resize(grid.cols, grid.rows);
            },
            .output => |data| if (!self.feed(data)) continue,
            .title => |t| self.events.emit(.{ .title = t }),
            .session_title => |st| self.events.emit(.{ .session_title = .{ .session = st.session, .title = st.title } }),
            .exit => |e| {
                var buf: [96]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "\r\n\x1b[31m[session exited: {d}]\x1b[0m\r\n", .{e.code}) catch unreachable;
                self.sink.output(self.sink.ctx, line);
                self.events.emit(.{ .exit = .{ .code = e.code } });
                ended = true;
            },
            .@"error" => |e| {
                self.events.emit(.{ .session_error = .{ .message = e.message } });
                ended = true;
            },
            .paste_result => |p| self.events.emit(.{ .paste_result = .{ .mode = p.mode, .path = p.path } }),
            .open_url => |u| self.events.emit(.{ .open_url = .{ .url = u.url, .id = u.id } }),
            .unknown => |typ| log.debug("webmux: ignoring frame type={s}", .{typ}),
        }
    }
}

/// JSON text with every lone UTF-16 surrogate escape (`\\ud800` without its
/// pair, or a stray low half) replaced by `\\ufffd`, which JSON.parse in the
/// Electron client tolerates and Zig's parser rejects (panels D10: the
/// whole frame was dropped). Returns `text` itself when there is none.
pub fn tolerateLoneSurrogates(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, text, "\\ud") == null and std.mem.indexOf(u8, text, "\\uD") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            out.appendAssumeCapacity(text[i]);
            i += 1;
            continue;
        }
        if (text[i + 1] != 'u') { // any other escape, incl. an escaped backslash
            out.appendSliceAssumeCapacity(text[i .. i + 2]);
            i += 2;
            continue;
        }
        const v = hex4(text, i + 2) orelse {
            out.appendSliceAssumeCapacity(text[i .. i + 2]);
            i += 2;
            continue;
        };
        if (v >= 0xd800 and v <= 0xdbff) {
            if (i + 12 <= text.len and text[i + 6] == '\\' and text[i + 7] == 'u') {
                if (hex4(text, i + 8)) |lo| if (lo >= 0xdc00 and lo <= 0xdfff) {
                    out.appendSliceAssumeCapacity(text[i .. i + 12]);
                    i += 12;
                    continue;
                };
            }
            out.appendSliceAssumeCapacity("\\ufffd");
        } else if (v >= 0xdc00 and v <= 0xdfff) {
            out.appendSliceAssumeCapacity("\\ufffd");
        } else {
            out.appendSliceAssumeCapacity(text[i .. i + 6]);
        }
        i += 6;
    }
    return out.toOwnedSlice(alloc);
}

fn hex4(text: []const u8, at: usize) ?u16 {
    if (at + 4 > text.len) return null;
    return std.fmt.parseInt(u16, text[at .. at + 4], 16) catch null;
}

test "tolerateLoneSurrogates" {
    const a = std.testing.allocator;
    const same = "{\"type\":\"output\",\"data\":\"a\\ud83d\\ude00b\"}";
    {
        const got = try tolerateLoneSurrogates(a, same); // a valid pair is kept
        defer if (got.ptr != same.ptr) a.free(got);
        try std.testing.expectEqualStrings(same, got);
        const plain = "{\"type\":\"output\",\"data\":\"abc\"}";
        try std.testing.expectEqual(@as([*]const u8, plain), (try tolerateLoneSurrogates(a, plain)).ptr);
    }
    const cases = [_][2][]const u8{
        .{ "\"x\\ud800y\"", "\"x\\ufffdy\"" },
        .{ "\"\\udc00\"", "\"\\ufffd\"" },
        .{ "\"\\ud800\\u0041\"", "\"\\ufffd\\u0041\"" },
        .{ "\"\\\\ud800\"", "\"\\\\ud800\"" }, // an escaped backslash, then text
        .{ "\"\\ud83d\\ude00\\ud800\"", "\"\\ud83d\\ude00\\ufffd\"" },
    };
    for (cases) |c| {
        const got = try tolerateLoneSurrogates(a, c[0]);
        defer if (got.ptr != c[0].ptr) a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
    // And the result parses.
    const fixed = try tolerateLoneSurrogates(a, "{\"type\":\"output\",\"data\":\"a\\ud800b\"}");
    defer a.free(fixed);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const f = try protocol.parseServerFrame(arena.allocator(), fixed);
    try std.testing.expectEqualStrings("a\u{FFFD}b", f.output);
}
