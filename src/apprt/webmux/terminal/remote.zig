//! A terminal pane's link to a webmux session (termio.Webmux backend):
//! the backend config, and the backend's events marshalled to the GTK
//! main loop and applied to the pane.
//!
//! Threading and lifetime (see the top of src/termio/Webmux.zig):
//!
//!   reader thread  `onEvent` copies the event, retains the `Proxy`, posts
//!                  it with mainloop.post and returns; it never waits for
//!                  the main thread.
//!   main thread    `Delivery.run` resolves the pane through the proxy's
//!                  weak reference. If the pane has been finalized
//!                  meanwhile the weak ref is empty and the event is
//!                  dropped; a dying pane is never touched.
//!
//! The pane owns one proxy reference; it drops it in `State.destroy`,
//! which runs after the core surface (and so the backend's reader thread)
//! has stopped, so the reader can never retain a freed proxy. Queued
//! deliveries and the exit timer hold their own references.
const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gtk = @import("gtk");

const termio = @import("../../../termio.zig");
const mainloop = @import("../mainloop.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const iface = @import("../iface.zig");
const TerminalPane = @import("../pane.zig").TerminalPane;

const log = std.log.scoped(.webmux_remote);
const alloc = std.heap.c_allocator;

/// Electron removes an exited session's pane after this long
/// (electron/ui/app.js, `exit`: `setTimeout(removeTile, 1200)`).
pub const exit_close_delay_ms = 1200;

pub const Link = enum {
    /// Before the first attach.
    connecting,
    up,
    /// Lost; the backend is retrying.
    down,
};

/// Where a remote pane attaches. Copied by `State.create`.
pub const Target = struct {
    /// The host's HTTP unix socket.
    socket_path: []const u8,
    /// The session to attach (it must exist).
    session_id: []const u8,
    /// The connection's profile name, for connection-log lines.
    conn_name: []const u8 = "",
};

pub const State = struct {
    socket_path: [:0]u8,
    session_id: [:0]u8,
    conn_name: []u8,
    proxy: *Proxy,

    link: Link = .connecting,
    /// Snapshots replayed so far (1 per attach: first one plus one per
    /// reconnect).
    snapshots: u32 = 0,
    /// The last snapshot replay: its size and how long it took.
    last_replay: ?struct { bytes: usize, ms: u32 } = null,
    /// Set once the session's shell exited.
    exit_code: ?i64 = null,
    /// Set if the host said the session does not exist.
    session_error: bool = false,

    pub fn create(pane: *TerminalPane, target: Target) Allocator.Error!*State {
        const self = try alloc.create(State);
        errdefer alloc.destroy(self);
        const socket_path = try alloc.dupeSentinel(u8, target.socket_path, 0);
        errdefer alloc.free(socket_path);
        const session_id = try alloc.dupeSentinel(u8, target.session_id, 0);
        errdefer alloc.free(session_id);
        const conn_name = try alloc.dupe(u8, target.conn_name);
        errdefer alloc.free(conn_name);
        const proxy = try alloc.create(Proxy);
        errdefer alloc.destroy(proxy);
        const p_session = try alloc.dupe(u8, target.session_id);
        errdefer alloc.free(p_session);
        const p_conn = try alloc.dupe(u8, target.conn_name);
        proxy.* = .{ .session_id = p_session, .conn_name = p_conn };
        proxy.weak.set(pane);
        self.* = .{ .socket_path = socket_path, .session_id = session_id, .conn_name = conn_name, .proxy = proxy };
        live.append(alloc, self) catch {};
        return self;
    }

    /// Main thread, after the core surface has been deinitialized.
    pub fn destroy(self: *State) void {
        for (live.items, 0..) |st, i| if (st == self) {
            _ = live.swapRemove(i);
            break;
        };
        self.proxy.release();
        alloc.free(self.socket_path);
        alloc.free(self.session_id);
        alloc.free(self.conn_name);
        alloc.destroy(self);
    }

    /// The connection's profile name, or null (a pane with none).
    pub fn connName(self: *const State) ?[]const u8 {
        return if (self.conn_name.len == 0) null else self.conn_name;
    }

    /// For `Surface.termioBackend`. The strings live as long as the pane.
    pub fn backendConfig(self: *State) termio.Webmux.Config {
        return .{
            .socket_path = self.socket_path,
            .session_id = self.session_id,
            .events = .{ .userdata = self.proxy, .callback = onEvent },
        };
    }
};

/// Every remote pane's state, in creation order. Main thread.
var live: std.ArrayListUnmanaged(*State) = .empty;

/// The first pane on `socket_path` whose session socket is open (borrowed;
/// valid until control returns to the main loop), or null.
pub fn firstLive(socket_path: []const u8) ?*TerminalPane {
    for (live.items) |st| {
        if (st.link != .up) continue;
        if (!std.mem.eql(u8, st.socket_path, socket_path)) continue;
        const pane = st.proxy.pane() orelse continue;
        pane.unref(); // alive: its state is still registered
        return pane;
    }
    return null;
}

/// The sink's userdata: outlives both the pane's use of the backend and
/// every queued delivery.
const Proxy = struct {
    refs: std.atomic.Value(u32) = .init(1),
    weak: WeakRef(TerminalPane) = .empty,
    /// Copies for connection-log lines, which are written even after the
    /// pane is gone (the socket's "closed" line comes at its teardown).
    session_id: []u8,
    conn_name: []u8,

    fn retain(self: *Proxy) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Main thread only (the weak ref is cleared on the last release).
    fn release(self: *Proxy) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.weak.deinit();
            alloc.free(self.session_id);
            alloc.free(self.conn_name);
            alloc.destroy(self);
        }
    }

    /// The pane, with a strong reference, or null if it is gone.
    fn pane(self: *Proxy) ?*TerminalPane {
        return self.weak.get();
    }
};

/// An event with owned copies of its strings.
const Owned = union(enum) {
    link_up,
    link_down,
    snapshot: struct { cols: u16, rows: u16, remote_cols: u16, remote_rows: u16, bytes: usize, ms: u32 },
    title: [:0]u8,
    exit: i64,
    session_error: []u8,
    paste_result: struct { claude: bool, path: ?[]u8 },
    open_url: struct { url: []u8, id: []u8 },
    socket: struct { ev: termio.Webmux.Event.Socket, reason: []u8 },

    fn copy(ev: *const termio.Webmux.Event) Allocator.Error!?Owned {
        return switch (ev.*) {
            .link_up => .link_up,
            .link_down => .link_down,
            .snapshot_applied => |s| .{ .snapshot = .{
                .cols = s.cols,
                .rows = s.rows,
                .remote_cols = s.remote_cols,
                .remote_rows = s.remote_rows,
                .bytes = s.bytes,
                .ms = s.ms,
            } },
            .title => |t| .{ .title = try alloc.dupeSentinel(u8, t, 0) },
            // Every pane keeps its own socket (contract › Deliberate
            // deviations 4), so each gets its own `title`; the fan-out of
            // other sessions' titles is not needed.
            .session_title => null,
            .exit => |e| .{ .exit = e.code },
            .session_error => |e| .{ .session_error = try alloc.dupe(u8, e.message) },
            .paste_result => |p| .{ .paste_result = .{
                .claude = std.mem.eql(u8, p.mode, "claude"),
                .path = if (p.path) |path| try alloc.dupe(u8, path) else null,
            } },
            .socket => |sk| .{ .socket = .{ .ev = sk, .reason = try alloc.dupe(u8, sk.reason) } },
            .open_url => |o| blk: {
                const url = try alloc.dupe(u8, o.url);
                errdefer alloc.free(url);
                break :blk .{ .open_url = .{ .url = url, .id = try alloc.dupe(u8, o.id) } };
            },
        };
    }

    fn free(self: Owned) void {
        switch (self) {
            .link_up, .link_down, .snapshot, .exit => {},
            .title => |t| alloc.free(t),
            .session_error => |m| alloc.free(m),
            .paste_result => |p| if (p.path) |path| alloc.free(path),
            .open_url => |o| {
                alloc.free(o.url);
                alloc.free(o.id);
            },
            .socket => |sk| alloc.free(sk.reason),
        }
    }
};

/// The backend's event callback. Reader thread.
fn onEvent(userdata: ?*anyopaque, ev: *const termio.Webmux.Event) void {
    const proxy: *Proxy = @ptrCast(@alignCast(userdata orelse return));
    const owned = (Owned.copy(ev) catch {
        log.warn("out of memory copying a backend event; dropped", .{});
        return;
    }) orelse return;
    proxy.retain();
    mainloop.post(Delivery{ .proxy = proxy, .event = owned }, Delivery.run);
}

const Delivery = struct {
    proxy: *Proxy,
    event: Owned,

    fn run(self: *Delivery) void {
        defer self.proxy.release();
        defer self.event.free();
        // Socket lines are logged whether or not the pane still exists.
        if (self.event == .socket) return logSocket(self.proxy, self.event.socket.ev, self.event.socket.reason);
        const pane = self.proxy.pane() orelse return;
        defer pane.unref();
        const state = pane.remoteState() orelse return;
        apply(pane, state, self.proxy, self.event);
    }
};

fn apply(pane: *TerminalPane, state: *State, proxy: *Proxy, ev: Owned) void {
    switch (ev) {
        .link_up => pane.setLink(.up),
        .link_down => pane.setLink(.down),
        .snapshot => |s| {
            state.snapshots += 1;
            state.last_replay = .{ .bytes = s.bytes, .ms = s.ms };
            log.debug("snapshot applied local={d}x{d} remote={d}x{d} bytes={d}", .{
                s.cols, s.rows, s.remote_cols, s.remote_rows, s.bytes,
            });
        },
        .title => |t| pane.setTitle(if (t.len == 0) null else t),
        .exit => |code| {
            state.exit_code = code;
            log.info("session {s} exited code={d}", .{ state.session_id, code });
            // The backend printed "[session exited: N]"; remove the pane
            // after the same delay as the Electron client. The connection
            // log line is written then, and only if the pane is still
            // there: a pane the user closed (DELETE, then the exit frame
            // during its close animation) is not a session that exited
            // (S-09; app.js closes the socket before the DELETE).
            const pending = alloc.create(ExitPending) catch return;
            pending.* = .{ .proxy = proxy, .code = code };
            proxy.retain();
            _ = glib.timeoutAddOnce(exit_close_delay_ms, closeAfterExit, pending);
        },
        .session_error => |msg| {
            state.session_error = true;
            // PARITY T-39's log line.
            log.warn("session gone on the host — closing its tab (session {s}: {s})", .{ state.session_id, msg });
            connLog(state, .warn, "session gone on the host — closing its tab", "error", null, msg);
            pane.requestClose();
        },
        .paste_result => |p| {
            if (p.claude) {
                iface.services.status(state.connName(), "image in clipboard — Ctrl+V forwarded to Claude");
            } else {
                var buf: [512]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "pasted image → {s}", .{p.path orelse ""}) catch "pasted image";
                iface.services.status(state.connName(), text);
            }
        },
        .socket => {}, // handled in Delivery.run
        .open_url => |o| {
            // Nobody clicked: offer the open/copy chooser, once per id
            // (the host may deliver one id on several sockets).
            if (seenOpenUrl(state.socket_path, o.id)) return;
            iface.services.url(o.url, .choose, pane.as(gtk.Widget));
        },
    }
}

/// A connection-log line with `{"session": id, <key>: int|string}`, as the
/// Electron page's logInfo/logWarn.
fn connLog(
    state: *State,
    level: iface.services.LogLevel,
    msg: []const u8,
    key: []const u8,
    int: ?i64,
    str: ?[]const u8,
) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var js: std.json.Stringify = .{ .writer = &w };
    blk: {
        js.beginObject() catch break :blk;
        js.objectField("session") catch break :blk;
        js.write(state.session_id) catch break :blk;
        js.objectField(key) catch break :blk;
        if (int) |v| js.write(v) catch break :blk else js.write(str orelse "") catch break :blk;
        js.endObject() catch break :blk;
        iface.services.connLog(level, state.conn_name, msg, w.buffered());
        return;
    }
    iface.services.connLog(level, state.conn_name, msg, null);
}

const ExitPending = struct { proxy: *Proxy, code: i64 };

fn closeAfterExit(ud: ?*anyopaque) callconv(.c) void {
    const pending: *ExitPending = @ptrCast(@alignCast(ud.?));
    const proxy = pending.proxy;
    defer alloc.destroy(pending);
    defer proxy.release();
    const pane = proxy.pane() orelse return; // closed by the user meanwhile
    defer pane.unref();
    const state = pane.remoteState() orelse return;
    connLog(state, .info, "session exited", "exitCode", pending.code, null);
    pane.requestClose();
}

/// The Electron page's per-socket log lines (app.js `connect()`, G-08).
fn logSocket(proxy: *Proxy, sk: termio.Webmux.Event.Socket, reason: []const u8) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var js: std.json.Stringify = .{ .writer = &w };
    const level: iface.services.LogLevel, const msg: []const u8 = switch (sk.kind) {
        .connecting => .{ .debug, "session socket connecting" },
        .reconnecting => .{ .debug, "session socket reconnecting" },
        .open => .{ .info, "session socket open" },
        .reopened => .{ .info, "session socket reopened" },
        .snapshot => .{ .debug, "snapshot received" },
        .closed => .{ .debug, "session socket closed (tab closed or session exited)" },
        .dropped => .{ .warn, "session socket dropped — retrying" },
        .connect_failed => .{ .warn, "session socket connect failed — retrying" },
    };
    const data: ?[]const u8 = blk: {
        js.beginObject() catch break :blk null;
        js.objectField("session") catch break :blk null;
        js.write(proxy.session_id) catch break :blk null;
        switch (sk.kind) {
            .connecting, .reconnecting => {
                js.objectField("attempt") catch break :blk null;
                js.write(sk.attempt) catch break :blk null;
            },
            .open, .reopened => {
                js.objectField("attempt") catch break :blk null;
                js.write(sk.attempt) catch break :blk null;
                js.objectField("ms") catch break :blk null;
                js.write(sk.ms) catch break :blk null;
            },
            .snapshot => {
                js.objectField("bytes") catch break :blk null;
                js.write(sk.bytes) catch break :blk null;
            },
            .closed => {
                js.objectField("code") catch break :blk null;
                js.write(sk.code) catch break :blk null;
            },
            .dropped, .connect_failed => {
                js.objectField("code") catch break :blk null;
                js.write(sk.code) catch break :blk null;
                if (reason.len > 0) {
                    js.objectField("reason") catch break :blk null;
                    js.write(reason) catch break :blk null;
                }
                js.objectField("clean") catch break :blk null;
                js.write(sk.clean) catch break :blk null;
                js.objectField("upMs") catch break :blk null;
                js.write(sk.ms) catch break :blk null;
                js.objectField("retryInMs") catch break :blk null;
                js.write(sk.retry_in_ms) catch break :blk null;
            },
        }
        js.endObject() catch break :blk null;
        break :blk w.buffered();
    };
    iface.services.connLog(level, proxy.conn_name, msg, data);
}

/// open-url ids already shown, per host socket (Electron: the page-wide
/// `seenOpenIds`). Bounded: the oldest ids are forgotten first.
var seen_ids: [256]?[]u8 = @splat(null);
var seen_next: usize = 0;

fn seenOpenUrl(socket_path: []const u8, id: []const u8) bool {
    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ socket_path, id }) catch return false;
    for (seen_ids) |maybe| {
        if (maybe) |k| if (std.mem.eql(u8, k, key)) return true;
    }
    if (seen_ids[seen_next]) |old| alloc.free(old);
    seen_ids[seen_next] = alloc.dupe(u8, key) catch null;
    seen_next = (seen_next + 1) % seen_ids.len;
    return false;
}

test "open-url dedupe is per host" {
    try std.testing.expect(!seenOpenUrl("/a", "1"));
    try std.testing.expect(seenOpenUrl("/a", "1"));
    try std.testing.expect(!seenOpenUrl("/b", "1"));
}
