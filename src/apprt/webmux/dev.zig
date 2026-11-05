//! Dev mode: run the shell against a host's HTTP socket directly, with no
//! ssh and no connection page (docs/native-client.md › Phase 2, Dev mode).
//!
//! When `WEBMUX_GTK_DEV_SOCKET` names a socket, the window shows one
//! connection view for it, built from an `iface.Conn` with slug and name
//! `dev` and no chrome around it:
//!
//!   - the registered `iface.workspace_factory`, if any (and no
//!     `WEBMUX_GTK_DEV_SESSION`);
//!   - otherwise a single terminal pane (through
//!     `iface.factories.terminal`) attached to the host's first session,
//!     creating one when the host has none. When that pane closes (the
//!     session exited or vanished) the window shows a status line instead;
//!     the app keeps running.
//!
//! `WEBMUX_GTK_DEV_SESSION=<id>` forces the single pane, attached to that
//! id as is, even one the host does not have (the `error` frame, PARITY
//! T-39): the workspace's reconciliation never attaches an unknown session.
//!
//! The chrome's connection engine runs in dev mode too (`iface.engine`:
//! settings store, connection log, keyring), with no connections.
//!
//! `webmux-dev/headless start --host` sets this up with an isolated host.
const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const net = @import("../../webmux/net.zig");
const global = @import("../../global.zig");
const iface = @import("iface.zig");
const mainloop = @import("mainloop.zig");
const Window = @import("window.zig").Window;
const TerminalPane = @import("pane.zig").TerminalPane;
const WeakRef = @import("weak_ref.zig").WeakRef;

const log = std.log.scoped(.webmux_dev);
const alloc = std.heap.c_allocator;

pub const env_var = "WEBMUX_GTK_DEV_SOCKET";

/// The dev socket, or null when dev mode is off.
pub fn socketPath() ?[:0]const u8 {
    const v = std.c.getenv(env_var) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// The single dev connection view. Lives until the process exits.
const View = struct {
    window: WeakRef(Window) = .empty,
    conn: iface.Conn,
    workspace: ?iface.Workspace = null,
    pane: ?iface.Pane = null,
};

var view: ?*View = null;

/// Fill a new window with the dev connection view. Main thread.
pub fn populate(win: *Window) void {
    const path = socketPath().?;
    const v = view orelse v: {
        const v = alloc.create(View) catch @panic("OOM");
        v.* = .{ .conn = .{
            .socket_path = alloc.dupeSentinel(u8, path, 0) catch @panic("OOM"),
            .slug = "dev",
            .name = "dev",
        } };
        view = v;
        break :v v;
    };
    v.window.set(win);
    log.info("dev mode: host socket {s}", .{path});

    const forced = std.c.getenv("WEBMUX_GTK_DEV_SESSION") != null;
    if (iface.workspace_factory) |wf| if (!forced) {
        const ws = wf.create(&v.conn, workspace_host) catch |err| {
            win.showStatus("dev: workspace failed: {t}", .{err});
            return;
        };
        v.workspace = ws;
        win.setBody(ws.widget);
        ws.setFront(true);
        ws.grabFocus();
        return;
    };

    win.showStatus("dev: looking for a session on {s}…", .{path});
    const thread = std.Thread.spawn(.{}, findSession, .{v.conn.socket_path}) catch |err| {
        win.showStatus("dev: cannot start lookup: {t}", .{err});
        return;
    };
    thread.detach();
}

/// Worker thread: the host's first session id, created if there is none.
fn findSession(socket_path: [:0]const u8) void {
    const result: Found = found: {
        // DEV HOOK (terminal pane): WEBMUX_GTK_DEV_SESSION=<id> attaches
        // that session id as is, even one the host does not have (to
        // exercise the `error` frame, PARITY T-39).
        if (std.c.getenv("WEBMUX_GTK_DEV_SESSION")) |forced| {
            break :found .{ .id = alloc.dupe(u8, std.mem.span(forced)) catch break :found .{ .err = "out of memory" } };
        }
        var client = net.http.Client.init(alloc, global.io(), socket_path) catch
            break :found .{ .err = "out of memory" };
        defer client.deinit();
        const list = net.api.listSessions(&client, alloc, .{}) catch |err|
            break :found .{ .err = @errorName(err) };
        defer list.deinit();
        if (list.value.len > 0) {
            break :found .{ .id = alloc.dupe(u8, list.value[0].id) catch break :found .{ .err = "out of memory" } };
        }
        const id = net.api.createSession(&client, alloc, 80, 24, .{}) catch |err|
            break :found .{ .err = @errorName(err) };
        log.info("dev: host had no session; created {s}", .{id});
        break :found .{ .id = id };
    };
    mainloop.post(result, Found.apply);
}

const Found = union(enum) {
    id: []u8,
    err: []const u8,

    fn apply(self: *Found) void {
        const v = view.?;
        defer if (self.* == .id) alloc.free(self.id);
        const win = v.window.get() orelse return;
        defer win.unref();
        switch (self.*) {
            .err => |e| win.showStatus("dev: cannot reach the host: {s}", .{e}),
            .id => |id| attach(v, win, id),
        }
    }
};

fn attach(v: *View, win: *Window, id: []const u8) void {
    const factory = iface.factories.terminal orelse {
        win.showStatus("dev: no terminal pane factory registered", .{});
        return;
    };
    const pane = factory.create(&v.conn, id, null, pane_host) catch |err| {
        win.showStatus("dev: pane failed: {t}", .{err});
        return;
    };
    v.pane = pane;
    win.setBody(pane.widget);
    pane.grabFocus();
    log.info("dev: attached to session {s}", .{id});
}

// --- PaneHost for the single dev pane ------------------------------------

var host_ctx: u8 = 0;

const pane_host: iface.PaneHost = .{ .ctx = &host_ctx, .vtable = &.{
    .titleChanged = paneTitleChanged,
    .closeRequested = paneCloseRequested,
    .stateChanged = paneIgnored,
    .focusEntered = paneIgnored,
    .linkChanged = paneLinkChanged,
} };

fn paneTitleChanged(_: *anyopaque, _: []const u8) void {
    const v = view orelse return;
    const pane = v.pane orelse return;
    const win = v.window.get() orelse return;
    defer win.unref();
    var buf: [256]u8 = undefined;
    const t: [:0]const u8 = if (pane.title()) |title|
        std.fmt.bufPrintSentinel(&buf, "{s} — webmux (dev)", .{title}, 0) catch "webmux (dev)"
    else
        "webmux (dev)";
    win.as(gtk.Window).setTitle(t.ptr);
}

fn paneCloseRequested(_: *anyopaque, id: []const u8) void {
    log.info("dev: pane {s} asked to close", .{id});
    // Never remove it from inside the call.
    _ = @import("glib").idleAddOnce(removePane, null);
}

fn removePane(_: ?*anyopaque) callconv(.c) void {
    const v = view orelse return;
    if (v.pane == null) return;
    v.pane = null;
    const win = v.window.get() orelse return;
    defer win.unref();
    win.showStatus("dev: the session ended", .{});
}

fn paneLinkChanged(_: *anyopaque, id: []const u8, up: bool) void {
    log.info("dev: pane {s} link {s}", .{ id, if (up) "up" else "down" });
}

fn paneIgnored(_: *anyopaque, _: []const u8) void {}

// --- WorkspaceHost ------------------------------------------------------

const workspace_host: iface.WorkspaceHost = .{ .ctx = &host_ctx, .vtable = &.{
    .summaryChanged = workspaceSummary,
} };

fn workspaceSummary(_: *anyopaque, panes: usize, offline: bool) void {
    log.info("dev: workspace panes={d} offline={}", .{ panes, offline });
}

comptime {
    _ = adw;
    _ = gobject;
    _ = TerminalPane;
}
