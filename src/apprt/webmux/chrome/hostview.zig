//! One connection's content view in the window's stack: the registered
//! workspace (`iface.workspace_factory`) once the connection is reachable,
//! or — while no workspace is registered — a single terminal pane on the
//! host's first session (the same fallback dev mode has). Before the
//! server first answers the view shows a one-line placeholder.
//!
//! Lives inside its `hub.Entry`. Asynchronous results (the fallback's
//! session lookup) carry the entry id and a generation, so a view that
//! was rebuilt or removed in the meantime ignores them.
const std = @import("std");
const glib = @import("glib");
const gtk = @import("gtk");

const net = @import("../../../webmux/net.zig");
const global = @import("../../../global.zig");
const iface = @import("../iface.zig");
const mainloop = @import("../mainloop.zig");
const hub = @import("hub.zig");
const text_mod = @import("text.zig");

const log = std.log.scoped(.webmux_chrome);
const alloc = std.heap.c_allocator;

pub const View = struct {
    entry_id: u64,
    /// Root widget, owned by the stack (borrowed here).
    box: ?*gtk.Box = null,
    placeholder: ?*gtk.Label = null,

    /// The connection as handed to the workspace; its strings are owned
    /// below and outlive the workspace.
    conn: ?iface.Conn = null,
    socket: ?[:0]u8 = null,
    slug: ?[]u8 = null,
    /// Every name the Conn ever carried (renames), freed at deinit.
    names: std.ArrayList([]u8) = .empty,

    workspace: ?iface.Workspace = null,
    /// Fallback single terminal.
    pane: ?iface.Pane = null,
    generation: u64 = 0,
    retry_source: c_uint = 0,
    front: bool = false,

    /// Build the root widget (placeholder until content exists).
    pub fn build(v: *View, e: *hub.Entry) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 0);
        const w = box.as(gtk.Widget);
        w.addCssClass("wm-hostview");
        w.setHexpand(1);
        w.setVexpand(1);
        // Focusable so keys land here (and not in a hidden view) while
        // there is no content yet.
        w.setFocusable(1);
        v.box = box;
        v.placeholder = null;
        if (v.workspace) |ws| {
            box.append(ws.widget);
        } else if (v.pane) |p| {
            box.append(p.widget);
        } else {
            var buf: [4608]u8 = undefined;
            v.setPlaceholder(std.fmt.bufPrintSentinel(&buf, "{s}: connecting…", .{e.name}, 0) catch "connecting…");
        }
        return w;
    }

    fn setPlaceholder(v: *View, text: [:0]const u8) void {
        const box = v.box orelse return;
        if (v.placeholder) |l| {
            text_mod.set(l, text);
            return;
        }
        const l = gtk.Label.new(null);
        text_mod.set(l, text);
        const w = l.as(gtk.Widget);
        w.addCssClass("wm-placeholder");
        w.setVexpand(1);
        w.setHexpand(1);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        box.append(w);
        v.placeholder = l;
    }

    fn clearPlaceholder(v: *View) void {
        const l = v.placeholder orelse return;
        if (v.box) |b| b.remove(l.as(gtk.Widget));
        v.placeholder = null;
    }

    /// Before any content exists: say what the connection is doing.
    pub fn noteState(v: *View, e: *hub.Entry) void {
        if (v.conn != null or v.box == null) return;
        var buf: [4608]u8 = undefined;
        const t: [:0]const u8 = switch (e.state) {
            .connecting => std.fmt.bufPrintSentinel(&buf, "{s}: connecting…", .{e.name}, 0) catch "connecting…",
            .retry => std.fmt.bufPrintSentinel(&buf, "{s}: interrupted — retrying…", .{e.name}, 0) catch "retrying…",
            .failed => std.fmt.bufPrintSentinel(&buf, "{s}: connection failed — Connections (Ctrl+Shift+O) has the details", .{e.name}, 0) catch "connection failed",
            .connected => return,
        };
        v.setPlaceholder(t);
    }

    pub fn iconn(v: *View) ?*const iface.Conn {
        if (v.conn) |*c| return c;
        return null;
    }

    /// Content was built for this connection (it may be a placeholder for
    /// a fallback whose session ended).
    pub fn hasContent(v: *const View) bool {
        return v.conn != null;
    }

    pub fn kind(v: *const View) []const u8 {
        if (v.workspace != null) return "workspace";
        if (v.pane != null) return "terminal";
        if (v.conn != null) return "fallback-empty";
        return "placeholder";
    }

    /// The connection is reachable at `socket`: build the content unless
    /// it already exists for that socket. Returns true when it was (re)built.
    pub fn ensureContent(v: *View, e: *hub.Entry, socket: []const u8, slug: []const u8) bool {
        if (v.socket) |s| if (std.mem.eql(u8, s, socket)) return false;
        v.teardown();
        v.socket = alloc.dupeSentinel(u8, socket, 0) catch return false;
        v.slug = alloc.dupe(u8, slug) catch return false;
        const name = alloc.dupe(u8, e.name) catch return false;
        v.names.append(alloc, name) catch {
            alloc.free(name);
            return false;
        };
        v.conn = .{ .socket_path = v.socket.?, .slug = v.slug.?, .name = name };

        if (iface.workspace_factory) |wf| {
            const ws = wf.create(&v.conn.?, workspaceHost(v.entry_id)) catch |err| {
                // X-31: content that cannot come up shows the page, not an
                // error view. Logged; the next connect tries again.
                if (hub.hub.engine) |engine| engine.log().warn(e.name, "workspace failed to start", &.{.{ .key = "error", .value = .{ .str = @errorName(err) } }});
                var buf: [4608]u8 = undefined;
                v.setPlaceholder(std.fmt.bufPrintSentinel(&buf, "{s}: the workspace failed to start ({t})", .{ e.name, err }, 0) catch "workspace failed");
                v.freeConn();
                if (hub.hub.active == e) hub.show(null);
                return false;
            };
            v.clearPlaceholder();
            v.workspace = ws;
            if (v.box) |b| b.append(ws.widget);
            ws.setFront(v.front);
            if (v.front) ws.grabFocus();
            return true;
        }
        v.lookForSession();
        return true;
    }

    /// Main thread: the fallback's session lookup.
    fn lookForSession(v: *View) void {
        v.generation += 1;
        var buf: [4608]u8 = undefined;
        const name = if (v.conn) |c| c.name else "";
        v.setPlaceholder(std.fmt.bufPrintSentinel(&buf, "{s}: looking for a session…", .{name}, 0) catch "…");
        const sock = alloc.dupeSentinel(u8, v.socket orelse return, 0) catch return;
        const t = std.Thread.spawn(.{}, findSession, .{ v.entry_id, v.generation, sock }) catch {
            alloc.free(sock);
            return;
        };
        t.detach();
    }

    pub fn setFront(v: *View, front: bool) void {
        v.front = front;
        if (v.workspace) |ws| ws.setFront(front);
        if (v.pane) |p| p.setShown(front);
    }

    pub fn grabFocus(v: *View) void {
        if (v.workspace) |ws| return ws.grabFocus();
        if (v.pane) |p| return p.grabFocus();
        if (v.box) |b| _ = b.as(gtk.Widget).grabFocus();
    }

    /// Activate an action from the content (e.g. `pane.new-terminal` on
    /// the workspace widget).
    pub fn activate(v: *View, action: [:0]const u8) void {
        const ws = v.workspace orelse return;
        _ = ws.widget.activateAction(action.ptr, null);
    }

    /// Re-read the session list (Restart Sessions, tunnel back).
    pub fn reload(v: *View) void {
        if (v.workspace) |ws| return ws.reload();
        if (v.conn == null) return;
        // Fallback: drop the pane, look again.
        if (v.pane) |p| {
            if (v.box) |b| b.remove(p.widget);
            v.pane = null;
        }
        v.lookForSession();
    }

    pub fn renamed(v: *View, name: []const u8) void {
        const c = &(v.conn orelse return);
        const copy = alloc.dupe(u8, name) catch return;
        v.names.append(alloc, copy) catch {
            alloc.free(copy);
            return;
        };
        c.name = copy;
    }

    /// Destroy the content (keeps the root box).
    fn teardown(v: *View) void {
        v.generation += 1;
        if (v.retry_source != 0) {
            _ = glib.Source.remove(v.retry_source);
            v.retry_source = 0;
        }
        if (v.workspace) |ws| {
            if (v.box) |b| b.remove(ws.widget);
            v.workspace = null;
        }
        if (v.pane) |p| {
            if (v.box) |b| b.remove(p.widget);
            v.pane = null;
        }
        v.freeConn();
    }

    fn freeConn(v: *View) void {
        v.conn = null;
        if (v.socket) |s| alloc.free(s);
        if (v.slug) |s| alloc.free(s);
        v.socket = null;
        v.slug = null;
    }

    /// The entry goes away: remove the root widget from the stack (which
    /// destroys the workspace and its panes; sessions keep running).
    pub fn removeFrom(v: *View, stack: *gtk.Stack) void {
        v.generation += 1;
        if (v.retry_source != 0) {
            _ = glib.Source.remove(v.retry_source);
            v.retry_source = 0;
        }
        const box = v.box orelse return;
        v.workspace = null;
        v.pane = null;
        v.placeholder = null;
        v.box = null;
        stack.remove(box.as(gtk.Widget));
    }

    /// The window was destroyed with everything in it.
    pub fn widgetGone(v: *View) void {
        v.generation += 1;
        v.box = null;
        v.placeholder = null;
        v.workspace = null;
        v.pane = null;
    }

    pub fn deinit(v: *View) void {
        if (v.retry_source != 0) {
            _ = glib.Source.remove(v.retry_source);
            v.retry_source = 0;
        }
        v.freeConn();
        for (v.names.items) |n| alloc.free(n);
        v.names.deinit(alloc);
    }
};

// ---------------------------------------------------------------------------
// WorkspaceHost (ctx = the entry id)
// ---------------------------------------------------------------------------

fn idCtx(id: u64) *anyopaque {
    return @ptrFromInt(@as(usize, @intCast(id)));
}

fn ctxId(ctx: *anyopaque) u64 {
    return @intCast(@intFromPtr(ctx));
}

fn workspaceHost(id: u64) iface.WorkspaceHost {
    return .{ .ctx = idCtx(id), .vtable = &ws_vtable };
}

const ws_vtable: iface.WorkspaceHost.VTable = .{ .summaryChanged = wsSummary, .viewportChanged = wsViewport };

fn wsSummary(ctx: *anyopaque, panes: usize, offline: bool) void {
    const e = hub.findId(ctxId(ctx)) orelse return;
    hub.summaryChanged(e, panes, offline);
}

fn wsViewport(ctx: *anyopaque) void {
    const e = hub.findId(ctxId(ctx)) orelse return;
    hub.viewportChanged(e);
}

// ---------------------------------------------------------------------------
// Fallback: one terminal pane on the host's first session
// ---------------------------------------------------------------------------

/// Worker thread: the first session id, created if the host has none.
fn findSession(id: u64, gen: u64, socket: [:0]u8) void {
    defer alloc.free(socket);
    const result: Found = found: {
        var client = net.http.Client.init(alloc, global.io(), socket) catch
            break :found .{ .id = id, .gen = gen, .err = "out of memory" };
        defer client.deinit();
        const list = net.api.listSessions(&client, alloc, .{}) catch |err|
            break :found .{ .id = id, .gen = gen, .err = @errorName(err) };
        defer list.deinit();
        if (list.value.len > 0) {
            break :found .{ .id = id, .gen = gen, .session = alloc.dupe(u8, list.value[0].id) catch null };
        }
        const sid = net.api.createSession(&client, alloc, 80, 24, .{}) catch |err|
            break :found .{ .id = id, .gen = gen, .err = @errorName(err) };
        break :found .{ .id = id, .gen = gen, .session = sid };
    };
    mainloop.post(result, Found.apply);
}

const Found = struct {
    id: u64,
    gen: u64,
    session: ?[]u8 = null,
    err: ?[]const u8 = null,

    fn apply(self: *Found) void {
        defer if (self.session) |s| alloc.free(s);
        if (hub.hub.shut_down) return;
        const e = hub.findId(self.id) orelse return;
        const v = &e.view;
        if (v.generation != self.gen or v.conn == null) return;
        const sid = self.session orelse {
            // A-07: keep trying while the connection is up.
            log.info("{s}: session list failed ({s}); retrying", .{ e.name, self.err orelse "?" });
            var buf: [4608]u8 = undefined;
            v.setPlaceholder(std.fmt.bufPrintSentinel(&buf, "{s}: cannot list sessions ({s}) — retrying…", .{ e.name, self.err orelse "?" }, 0) catch "retrying…");
            if (v.retry_source == 0) v.retry_source = glib.timeoutAddSeconds(1, retryLookup, idCtx(self.id));
            return;
        };
        attach(e, sid);
    }
};

fn retryLookup(ud: ?*anyopaque) callconv(.c) c_int {
    const e = hub.findId(ctxId(ud.?)) orelse return 0;
    e.view.retry_source = 0;
    if (e.view.conn == null or e.view.pane != null) return 0;
    e.view.lookForSession();
    return 0;
}

fn attach(e: *hub.Entry, session: []const u8) void {
    const v = &e.view;
    const factory = iface.factories.terminal orelse {
        v.setPlaceholder("no terminal pane factory registered");
        return;
    };
    const pane = factory.create(&v.conn.?, session, null, paneHost(e.id)) catch |err| {
        var buf: [128]u8 = undefined;
        v.setPlaceholder(std.fmt.bufPrintSentinel(&buf, "terminal failed: {t}", .{err}, 0) catch "terminal failed");
        return;
    };
    v.clearPlaceholder();
    v.pane = pane;
    if (v.box) |b| b.append(pane.widget);
    pane.setShown(v.front);
    if (v.front) pane.grabFocus();
    log.info("{s}: terminal attached to session {s}", .{ e.name, session });
    hub.summaryChanged(e, 1, false);
}

fn paneHost(id: u64) iface.PaneHost {
    return .{ .ctx = idCtx(id), .vtable = &pane_vtable };
}

const pane_vtable: iface.PaneHost.VTable = .{
    .titleChanged = paneIgnored,
    .closeRequested = paneClose,
    .stateChanged = paneIgnored,
    .focusEntered = paneIgnored,
    .linkChanged = paneLink,
};

fn paneIgnored(_: *anyopaque, _: []const u8) void {}

fn paneClose(ctx: *anyopaque, _: []const u8) void {
    // Never remove it from inside the call.
    _ = glib.idleAddOnce(removePane, ctx);
}

fn removePane(ud: ?*anyopaque) callconv(.c) void {
    if (hub.hub.shut_down) return;
    const e = hub.findId(ctxId(ud.?)) orelse return;
    const v = &e.view;
    const p = v.pane orelse return;
    if (v.box) |b| b.remove(p.widget);
    v.pane = null;
    var buf: [4608]u8 = undefined;
    v.setPlaceholder(std.fmt.bufPrintSentinel(&buf, "{s}: the session ended", .{e.name}, 0) catch "the session ended");
    if (v.front) v.grabFocus();
    hub.summaryChanged(e, 0, false);
}

fn paneLink(ctx: *anyopaque, _: []const u8, up: bool) void {
    const e = hub.findId(ctxId(ctx)) orelse return;
    hub.summaryChanged(e, if (e.view.pane != null) 1 else 0, !up);
}
