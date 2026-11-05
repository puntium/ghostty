//! `WebmuxWorkspace`: one connection's strip of columns (electron/ui/app.js
//! rendering, strip scrolling, layout animation, session actions, pane
//! commands, startup). The model is `layout.Layout`; this widget is a thin
//! view over it:
//!
//!   - every pane sits in a `PaneFrame` (chrome) that is allocated once at
//!     its final box (`geometry.zig`, the model's width rule and stacks);
//!     the strip scrolls by moving allocation origins, never sizes;
//!   - a structural change (any command but focus moves) animates FLIP
//!     style, like app.js animateStrip: the final allocation is in place
//!     from the first frame and `snapshot` draws each element translated
//!     back to where it was, clipped to its in-flight size, over a ghost of
//!     its shell when it shrinks; a closing pane stays at its old box while
//!     a clip closes in. Nothing is re-allocated per frame, so terminals
//!     resize (and tell the host their grid) once per change;
//!   - sessions are created and deleted on worker threads (`sessions.zig`);
//!     the layout file is written debounced and atomically (`store.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gsk = @import("gsk.zig");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const ext = @import("../ext.zig");
const iface = @import("../iface.zig");
const scale_util = @import("../scale.zig");
const global = @import("../../../global.zig");
const conn = @import("../../../webmux/conn.zig");
const layout = @import("../../../webmux/layout.zig");
const Layout = layout.Layout;
const Command = layout.Command;
const width = layout.width;

const anim = @import("anim.zig");
const Box = anim.Box;
const Flight = anim.Flight;
const geometry = @import("geometry.zig");
const Geometry = geometry.Geometry;
const store = @import("store.zig");
const sessions = @import("sessions.zig");
const PaneFrame = @import("frame.zig").PaneFrame;
const frame_mod = @import("frame.zig");

const log = std.log.scoped(.webmux_workspace);
const alloc = std.heap.c_allocator;

/// A wheel notch pans the strip by this many pixels (Chromium's
/// per-notch wheel delta on Linux is in this range; a touchpad's pixel
/// deltas are used as they come).
pub const wheel_step_px: f64 = 53;
/// Layout file writes are debounced by this much.
pub const save_delay_ms: c_uint = 250;
/// Cell-width poll (font size and scale changes have no signal).
pub const cell_poll_ms: c_uint = 500;

/// The last cell width (CSS px) any workspace learned from a terminal, so
/// a workspace that holds no terminal still lays out at the real width.
var last_cell_px: f64 = geometry.default_cell_px;

const Item = struct {
    id: [:0]u8,
    kind: layout.Kind,
    frame: *PaneFrame,
    pane: ?iface.Pane = null,
    /// From the session list, until the pane reports its own (S-04).
    seed_title: ?[:0]u8 = null,
    link_down: bool = false,
    /// Delete the session on the host once the pane is destroyed.
    kill: bool = false,
    col: usize = 0,
    row: usize = 0,
    /// Final box, snapped, strip space: the frame's allocation.
    box: Box = .{},
    flight: ?Flight = null,

    fn deinit(self: *Item) void {
        alloc.free(self.id);
        if (self.seed_title) |t| alloc.free(t);
        alloc.destroy(self);
    }
};

const Divider = struct {
    ws: *Workspace,
    widget: *gtk.Widget,
    col: usize = 0,
    row: usize = 0,
    box: Box = .{},
    flight: ?Flight = null,
    drag_start_y: f64 = 0,
};

const Ghost = struct {
    widget: *gtk.Widget,
    flight: Flight,
    pane: bool,
    focused: bool,
};

const Leaving = struct {
    item: *Item,
    /// Where it was on screen when it left (mid-flight if it was moving).
    from: Box,
    cut: anim.Cut,
};

const Anim = struct {
    start_us: i64,
    serial: u32,
    timeout: c_uint = 0,
};

const Chase = struct {
    target: f64,
    pos: f64,
    last_us: ?i64 = null,
};

/// Boxes as the eye saw them before a change (app.js snapshotStrip).
const Visual = struct {
    const PaneBox = struct { col: usize, row: usize, box: Box };
    panes: std.ArrayList(PaneBox) = .empty,
    dividers: std.ArrayList(PaneBox) = .empty,
    cols: std.ArrayList(Box) = .empty,
    extent: f64 = 0,

    fn deinit(self: *Visual) void {
        self.panes.deinit(alloc);
        self.dividers.deinit(alloc);
        self.cols.deinit(alloc);
    }

    pub fn oldPane(self: *const Visual, s: layout.change.Slot) ?Box {
        for (self.panes.items) |p| if (p.col == s.col and p.row == s.row) return p.box;
        return null;
    }
    fn oldDivider(self: *const Visual, s: layout.change.Slot) ?Box {
        for (self.dividers.items) |p| if (p.col == s.col and p.row == s.row) return p.box;
        return null;
    }
    pub fn oldColumn(self: *const Visual, i: usize) ?Box {
        return if (i < self.cols.items.len) self.cols.items[i] else null;
    }
};

const Pre = struct {
    before: layout.Snapshot,
    visual: Visual,

    fn deinit(self: *Pre) void {
        self.before.deinit();
        self.visual.deinit();
    }
};

pub const Workspace = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxWorkspace",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    /// Test knob (control socket): every animation takes this many times
    /// as long, so a screenshot can catch it mid-flight.
    pub var time_scale: f64 = 1;
    /// Test knob: force reduced motion on (true) or off (false).
    pub var reduced_override: ?bool = null;

    const Private = struct {
        socket_path: [:0]u8 = undefined,
        slug: []u8 = undefined,
        name: []u8 = undefined,
        host: iface.WorkspaceHost = undefined,
        model: Layout = undefined,
        items: std.ArrayList(*Item) = .empty,
        dividers: std.ArrayList(*Divider) = .empty,
        leaving: std.ArrayList(*Leaving) = .empty,
        ghosts: std.ArrayList(*Ghost) = .empty,
        geom: ?Geometry = null,
        vw: c_int = 0,
        vh: c_int = 0,
        cell_px: f64 = geometry.default_cell_px,
        settings: conn.Settings = .{},
        scroll: f64 = 0,
        chase: ?Chase = null,
        keeper: ?f64 = null,
        anim: ?Anim = null,
        anim_serial: u32 = 0,
        tick_id: c_uint = 0,
        message: *gtk.Label = undefined,
        layout_path: ?[]u8 = null,
        saved_text: ?[]u8 = null,
        loaded: bool = false,
        list_inflight: bool = false,
        list_backoff_ms: c_uint = 1000,
        list_retry: c_uint = 0,
        save_source: c_uint = 0,
        cell_poll: c_uint = 0,
        front: bool = true,
        disposed: bool = false,
        pending_creates: u32 = 0,
        reported_panes: ?usize = null,
        reported_offline: bool = false,
        /// The page-level link flag (app.js `linkDown`).
        link_offline: bool = false,
        /// Pointer position over the strip (for the scroll hit test).
        pointer: ?struct { x: f64, y: f64 } = null,
        sb_hover: bool = false,
        sb_drag: ?struct { start_scroll: f64, per_px: f64 } = null,
        dragging: ?*Divider = null,
        saves: u32 = 0,

        pub var offset: c_int = 0;
    };

    // =====================================================================
    // Creation (iface.WorkspaceFactory)
    // =====================================================================

    pub fn new(c: *const iface.Conn, host: iface.WorkspaceHost) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.socket_path = alloc.dupeSentinel(u8, c.socket_path, 0) catch @panic("OOM");
        priv.slug = alloc.dupe(u8, c.slug) catch @panic("OOM");
        priv.name = alloc.dupe(u8, c.name) catch @panic("OOM");
        priv.host = host;
        priv.model = .init(alloc);
        priv.settings = iface.settings.get();
        priv.cell_px = last_cell_px;
        _ = iface.settings.subscribe(.{ .ctx = self, .changed = settingsChanged });

        priv.layout_path = store.pathFor(alloc, c.slug) catch |err| blk: {
            log.warn("{s}: no layout file path ({t}); the layout will not persist", .{ c.name, err });
            break :blk null;
        };
        if (priv.layout_path) |p| priv.saved_text = store.read(global.io(), alloc, p);
        log.info("{s}: workspace (layout {s}, {s})", .{ c.name, priv.layout_path orelse "-", if (priv.saved_text != null) "saved" else "none saved" });

        self.fetchSessions();
        priv.cell_poll = glib.timeoutAdd(cell_poll_ms, cellPoll, self);
        return self;
    }

    /// The iface view of this workspace. `ctx` is the widget itself.
    pub fn handle(self: *Self) iface.Workspace {
        return .{ .widget = self.as(gtk.Widget), .ctx = self, .vtable = &workspace_vtable };
    }

    const workspace_vtable: iface.Workspace.VTable = .{
        .setFront = vtSetFront,
        .grabFocus = vtGrabFocus,
        .reload = vtReload,
    };

    fn fromCtx(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    fn vtSetFront(ctx: *anyopaque, front: bool) void {
        fromCtx(ctx).setFront(front);
    }
    fn vtGrabFocus(ctx: *anyopaque) void {
        fromCtx(ctx).focusKeyboard();
    }
    fn vtReload(ctx: *anyopaque) void {
        fromCtx(ctx).reload();
    }

    pub fn setFront(self: *Self, front: bool) void {
        const priv = self.private();
        priv.front = front;
        for (priv.items.items) |it| if (it.pane) |p| p.setShown(front);
    }

    pub fn reload(self: *Self) void {
        log.info("{s}: reload", .{self.private().name});
        self.fetchSessions();
    }

    // =====================================================================
    // Sessions: list (startup, reload), create, close
    // =====================================================================

    fn fetchSessions(self: *Self) void {
        const priv = self.private();
        if (priv.list_inflight) return;
        if (priv.list_retry != 0) {
            _ = glib.Source.remove(priv.list_retry);
            priv.list_retry = 0;
        }
        priv.list_inflight = true;
        sessions.list(Self, self, priv.socket_path) catch |err| {
            priv.list_inflight = false;
            log.err("{s}: cannot start the session list fetch: {t}", .{ priv.name, err });
        };
    }

    /// Main loop: the session list arrived (or failed).
    pub fn onSessionList(self: *Self, r: *sessions.ListResult) void {
        const priv = self.private();
        priv.list_inflight = false;
        if (priv.disposed) return;
        const list = r.sessions orelse {
            // A-07: retry with backoff while the connection is up (the
            // chrome destroys the workspace when it is not), and say so.
            var buf: [256]u8 = undefined;
            const data = std.fmt.bufPrint(&buf, "{{\"api\":\"{s}\",\"error\":\"{s}\"}}", .{ priv.socket_path, r.err }) catch null;
            iface.services.connLog(.@"error", priv.name, "session list fetch failed", data);
            const secs = priv.list_backoff_ms / 1000;
            log.warn("{s}: session list fetch failed ({s}); retrying in {d} s", .{ priv.name, r.err, secs });
            if (priv.items.items.len == 0)
                self.showMessage("Cannot list the sessions on {s} ({s}). Retrying in {d} s…", .{ priv.name, r.err, secs })
            else if (priv.list_backoff_ms == 1000)
                self.statusf("Cannot list the sessions on {s} ({s}); retrying", .{ priv.name, r.err });
            priv.list_retry = glib.timeoutAdd(priv.list_backoff_ms, listRetry, self);
            priv.list_backoff_ms = @min(priv.list_backoff_ms * 2, 10_000);
            return;
        };
        priv.list_backoff_ms = 1000;
        self.hideMessage();

        var ids = alloc.alloc([]const u8, list.len) catch return;
        defer alloc.free(ids);
        for (list, 0..) |s, i| ids[i] = s.id;

        if (!priv.loaded) {
            var buf: [512]u8 = undefined;
            const data = std.fmt.bufPrint(&buf, "{{\"sessions\":{d},\"api\":\"{s}\"}}", .{ list.len, priv.socket_path }) catch null;
            iface.services.connLog(.info, priv.name, "page attached", data);
            const text = priv.saved_text orelse "";
            var loaded = layout.persist.load(alloc, text, ids) catch {
                log.err("{s}: out of memory loading the layout", .{priv.name});
                return;
            };
            std.mem.swap(Layout, &priv.model, &loaded);
            loaded.deinit();
            if (priv.saved_text) |t| alloc.free(t);
            priv.saved_text = null;
            priv.loaded = true;
        } else {
            // Workspace.reload: reconcile what is on screen with the host.
            self.settle();
            const f = if (priv.model.focusedId()) |x| alloc.dupe(u8, x) catch null else null;
            defer if (f) |x| alloc.free(x);
            layout.persist.reconcile(&priv.model, ids, f) catch return;
            var i: usize = priv.items.items.len;
            while (i > 0) {
                i -= 1;
                const it = priv.items.items[i];
                if (priv.model.find(it.id) == null) {
                    _ = priv.items.orderedRemove(i);
                    self.destroyItem(it);
                }
            }
        }

        // Every pane of the model gets its frame (S-04: titles seeded).
        for (priv.model.columns.items) |col| for (col.panes.items) |p| {
            if (self.itemById(p.id) != null) continue;
            var seed: ?[]const u8 = null;
            for (list) |s| if (std.mem.eql(u8, s.id, p.id) and s.title.len > 0) {
                seed = s.title;
            };
            _ = self.makeItem(p.id, p.kind, p.state, seed);
        };
        self.syncDividers();
        self.relayout();
        self.clampScrollNow();
        self.updateFocusClasses();
        self.reveal();
        self.scheduleSave();
        self.reportSummary();
        self.as(gtk.Widget).queueAllocate();

        // S-06: an empty workspace opens a first terminal.
        if (priv.model.isEmpty()) {
            if (priv.pending_creates == 0) self.requestNewTerminal(false);
        } else self.focusKeyboard();
    }

    fn listRetry(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        self.private().list_retry = 0;
        self.fetchSessions();
        return 0;
    }

    fn requestNewTerminal(self: *Self, below: bool) void {
        const priv = self.private();
        priv.pending_creates += 1;
        sessions.create(Self, self, priv.socket_path, below) catch |err| {
            priv.pending_creates -= 1;
            self.statusf("Could not create a terminal on {s}: {t}", .{ priv.name, err });
        };
    }

    /// Main loop: POST /api/sessions answered.
    pub fn onSessionCreated(self: *Self, r: *sessions.CreateResult) void {
        const priv = self.private();
        priv.pending_creates -|= 1;
        if (priv.disposed) return;
        const id = r.id orelse {
            // A-08: a failed create is reported, not swallowed.
            const msg = r.message[0..r.message_len];
            if (msg.len > 0)
                self.statusf("Could not create a terminal on {s}: {s}", .{ priv.name, msg })
            else
                self.statusf("Could not create a terminal on {s}: {s}", .{ priv.name, r.err });
            iface.services.connLog(.@"error", priv.name, "session create failed", null);
            return;
        };
        var pre = self.prepare() catch return;
        const res = if (r.below and priv.model.focused != null)
            priv.model.newTerminalBelow(id)
        else
            priv.model.newTerminal(id);
        res catch |err| {
            pre.deinit();
            log.err("{s}: new session {s} not added: {t}", .{ priv.name, id, err });
            return;
        };
        _ = self.makeItem(id, .terminal, null, null);
        self.commit(&pre, null);
        self.focusKeyboard();
    }

    fn newFiles(self: *Self) void {
        const priv = self.private();
        var buf: [64]u8 = undefined;
        var rnd: [4]u8 = undefined;
        global.io().random(&rnd);
        const now_ms: u64 = @intCast(@divTrunc(glib.getRealTime(), 1000));
        const id = store.newFilesId(&buf, now_ms, std.mem.readInt(u32, &rnd, .little));
        var pre = self.prepare() catch return;
        priv.model.newFiles(id, store.initial_files_state) catch |err| {
            pre.deinit();
            log.err("{s}: new file browser not added: {t}", .{ priv.name, err });
            return;
        };
        _ = self.makeItem(id, .files, store.initial_files_state, null);
        self.commit(&pre, null);
        self.focusKeyboard();
    }

    /// S-09 / L-34: close a pane. `kill`: also delete its session on the
    /// host (✕ and close-pane; not for a session that already ended).
    pub fn closePane(self: *Self, id: []const u8, kill: bool) void {
        const priv = self.private();
        const idx = self.itemIndex(id) orelse return;
        var pre = self.prepare() catch return;
        const it = priv.items.orderedRemove(idx);
        _ = priv.model.remove(it.id);
        // S-09: the session is deleted once the pane is gone and its socket
        // closed (app.js closes the socket first), so the host's `exit`
        // never reaches it and no "session exited" is logged for a pane
        // the user closed.
        it.kill = kill and it.kind == .terminal;
        // Its content holds still while the clip closes in (the session
        // is going away; nothing it draws now matters).
        if (it.pane) |p| p.setShown(false);
        it.frame.detach();
        self.commit(&pre, it);
        self.focusKeyboard();
    }

    // =====================================================================
    // Panes
    // =====================================================================

    fn makeItem(self: *Self, id: []const u8, kind: layout.Kind, state: ?[]const u8, seed: ?[]const u8) ?*Item {
        const priv = self.private();
        const it = alloc.create(Item) catch return null;
        const frame = PaneFrame.new(self, id, kind);
        it.* = .{
            .id = alloc.dupeSentinel(u8, id, 0) catch @panic("OOM"),
            .kind = kind,
            .frame = frame,
            .seed_title = if (seed) |s| alloc.dupeSentinel(u8, s, 0) catch null else null,
        };
        frame.as(gtk.Widget).setParent(self.as(gtk.Widget));
        priv.items.append(alloc, it) catch @panic("OOM");

        const c: iface.Conn = .{ .socket_path = priv.socket_path, .slug = priv.slug, .name = priv.name };
        if (iface.factories.get(kind)) |factory| {
            if (factory.create(&c, id, state, self.paneHost())) |pane| {
                it.pane = pane;
                frame.setBody(pane.widget);
                if (!priv.front) pane.setShown(false);
            } else |err| {
                log.err("{s}: pane {s} could not be created: {t}", .{ priv.name, id, err });
                var buf: [160]u8 = undefined;
                frame.setBody(placeholder(std.fmt.bufPrintSentinel(&buf, "This pane could not be opened ({t}).", .{err}, 0) catch "This pane could not be opened."));
            }
        } else {
            frame.setBody(placeholder(switch (kind) {
                .files => "File browser — not available in this build.",
                .terminal => "Terminal — not available in this build.",
            }));
        }
        self.refreshTitle(it);
        return it;
    }

    /// A pane kind with no factory (or one that failed): a focusable box
    /// with a line of text, so the pane still takes focus and the chords.
    fn placeholder(text: [:0]const u8) *gtk.Widget {
        const l = gtk.Label.new(text.ptr);
        l.setWrap(1);
        l.as(gtk.Widget).setHexpand(1);
        l.as(gtk.Widget).setVexpand(1);
        const b = gtk.Box.new(.vertical, 0);
        b.append(l.as(gtk.Widget));
        const w = b.as(gtk.Widget);
        w.addCssClass("pane-placeholder");
        w.setFocusable(1);
        w.setFocusOnClick(1);
        return w;
    }

    fn destroyItem(self: *Self, it: *Item) void {
        it.frame.detach();
        // Drops the last reference: the pane finalizes, its backend stops
        // and its socket closes, before the DELETE below.
        it.frame.as(gtk.Widget).unparent();
        if (it.kill) sessions.delete(self.private().socket_path, it.id);
        it.deinit();
    }

    fn itemIndex(self: *Self, id: []const u8) ?usize {
        for (self.private().items.items, 0..) |it, i| if (std.mem.eql(u8, it.id, id)) return i;
        return null;
    }

    fn itemById(self: *Self, id: []const u8) ?*Item {
        const i = self.itemIndex(id) orelse return null;
        return self.private().items.items[i];
    }

    fn refreshTitle(self: *Self, it: *Item) void {
        _ = self;
        const t: [:0]const u8 = blk: {
            if (it.pane) |p| if (p.title()) |x| if (x.len > 0) break :blk x;
            if (it.seed_title) |s| break :blk s;
            break :blk it.id;
        };
        it.frame.setTitle(t);
    }

    fn paneHost(self: *Self) iface.PaneHost {
        return .{ .ctx = self, .vtable = &pane_host_vtable };
    }

    const pane_host_vtable: iface.PaneHost.VTable = .{
        .titleChanged = phTitle,
        .closeRequested = phClose,
        .stateChanged = phState,
        .focusEntered = phFocus,
        .linkChanged = phLink,
    };

    fn phTitle(ctx: *anyopaque, id: []const u8) void {
        const self = fromCtx(ctx);
        if (self.private().disposed) return;
        if (self.itemById(id)) |it| self.refreshTitle(it);
    }

    const CloseIdle = struct {
        ws: *Self,
        id: []u8,
        fn run(ud: ?*anyopaque) callconv(.c) void {
            const c: *CloseIdle = @ptrCast(@alignCast(ud.?));
            defer {
                c.ws.unref();
                alloc.free(c.id);
                alloc.destroy(c);
            }
            if (c.ws.private().disposed) return;
            c.ws.closePane(c.id, false);
        }
    };

    fn phClose(ctx: *anyopaque, id: []const u8) void {
        const self = fromCtx(ctx);
        if (self.private().disposed) return;
        log.info("{s}: pane {s} asked to close", .{ self.private().name, id });
        // Never from inside the call (the pane's core may be on the stack).
        const c = alloc.create(CloseIdle) catch return;
        c.* = .{ .ws = self.ref(), .id = alloc.dupe(u8, id) catch {
            self.unref();
            alloc.destroy(c);
            return;
        } };
        _ = glib.idleAddOnce(CloseIdle.run, c);
    }

    fn phState(ctx: *anyopaque, _: []const u8) void {
        const self = fromCtx(ctx);
        if (self.private().disposed) return;
        self.scheduleSave();
    }

    fn phFocus(ctx: *anyopaque, id: []const u8) void {
        const self = fromCtx(ctx);
        if (self.private().disposed) return;
        self.setFocus(id, false);
    }

    fn phLink(ctx: *anyopaque, id: []const u8, up: bool) void {
        const self = fromCtx(ctx);
        const priv = self.private();
        if (priv.disposed) return;
        const it = self.itemById(id) orelse return;
        it.link_down = !up;
        // app.js setLinkDown: down when any socket drops, up again when any
        // socket opens (not "while any is down").
        priv.link_offline = !up;
        // Same wording as the dev view ("<conn>: pane <id> link down").
        log.info("{s}: pane {s} link {s}", .{ priv.name, id, if (up) "up" else "down" });
        self.reportSummary();
    }

    /// S-12 / iface: pane count and whether any terminal's link is down.
    fn reportSummary(self: *Self) void {
        const priv = self.private();
        const n = priv.model.paneCount();
        const offline = priv.link_offline;
        if (offline != priv.reported_offline) {
            if (offline)
                iface.services.connLog(.warn, priv.name, "link down — a session socket dropped and is retrying", null)
            else
                iface.services.connLog(.info, priv.name, "link up — a session socket is open again", null);
        }
        if (priv.reported_panes != null and priv.reported_panes.? == n and offline == priv.reported_offline) return;
        priv.reported_panes = n;
        priv.reported_offline = offline;
        priv.host.summaryChanged(n, offline);
    }

    // =====================================================================
    // Focus (L-19 … L-22)
    // =====================================================================

    /// Focus bookkeeping (app.js setFocus): the pane becomes focused and
    /// its column's active pane; ring and fade follow; the strip reveals
    /// its column. `keyboard`: also move keyboard focus into it.
    pub fn setFocus(self: *Self, id: []const u8, keyboard: bool) void {
        const priv = self.private();
        if (!priv.loaded) return;
        if (priv.model.setFocus(id)) {
            self.updateFocusClasses();
            self.scheduleSave();
        }
        self.reveal();
        if (keyboard) self.focusKeyboard();
    }

    /// Keyboard focus into the focused pane (or the strip itself when it
    /// holds none, so the pane chords still reach `pane.*`).
    pub fn focusKeyboard(self: *Self) void {
        const priv = self.private();
        if (priv.model.focusedId()) |f| if (self.itemById(f)) |it| {
            if (it.pane) |p| {
                p.grabFocus();
                return;
            }
            if (it.frame.body()) |b| {
                _ = b.grabFocus();
                return;
            }
        };
        _ = self.as(gtk.Widget).grabFocus();
    }

    fn fadeStrength(self: *Self) f64 {
        return @as(f64, @floatFromInt(@min(self.private().settings.unfocused_fade, 100))) / 100;
    }

    fn updateFocusClasses(self: *Self) void {
        const priv = self.private();
        const f = priv.model.focusedId();
        const k = self.fadeStrength();
        const instant = self.reducedMotion();
        for (priv.items.items) |it| {
            const is = f != null and std.mem.eql(u8, f.?, it.id);
            it.frame.setFocused(is, k, instant);
        }
    }

    // Called by PaneFrame's gestures (and the control socket, which enters
    // at the same functions).

    pub fn paneClicked(self: *Self, id: []const u8) void {
        const it = self.itemById(id) orelse return;
        // A pane that cannot take focus by itself gets it here.
        self.setFocus(id, it.pane == null);
    }

    pub fn paneBarClicked(self: *Self, id: []const u8) void {
        self.setFocus(id, true);
    }

    pub fn paneCloseClicked(self: *Self, id: []const u8) void {
        self.closePane(id, true);
    }

    // =====================================================================
    // Commands (pane.<command> actions, L-06 … L-18)
    // =====================================================================

    pub fn runCommand(self: *Self, cmd: Command) void {
        const priv = self.private();
        if (!priv.loaded) {
            log.info("{s}: {s} ignored: sessions not listed yet", .{ priv.name, cmd.name() });
            return;
        }
        switch (cmd) {
            .new_terminal => self.requestNewTerminal(false),
            .new_terminal_below => self.requestNewTerminal(true),
            .new_files => self.newFiles(),
            .close_pane => if (priv.model.focusedId()) |f| {
                const id = alloc.dupe(u8, f) catch return;
                defer alloc.free(id);
                self.closePane(id, true);
            },
            .focus_left, .focus_right, .focus_up, .focus_down => {
                const moved = priv.model.run(cmd) catch false;
                if (!moved) return;
                // Focus moves rebuild nothing (L-22): ring, fade, scroll.
                self.updateFocusClasses();
                self.scheduleSave();
                self.reveal();
                self.focusKeyboard();
            },
            else => {
                var pre = self.prepare() catch return;
                const changed = priv.model.run(cmd) catch false;
                if (!changed) {
                    pre.deinit();
                    return;
                }
                self.commit(&pre, null);
                self.focusKeyboard();
            },
        }
    }

    fn commandAction(comptime cmd: Command) ext.actions.Action(Self).Callback {
        return struct {
            fn cb(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
                self.runCommand(cmd);
            }
        }.cb;
    }

    const command_actions = blk: {
        const cmds = std.enums.values(Command);
        var out: [cmds.len]ext.actions.Action(Self) = undefined;
        for (cmds, 0..) |c, i| {
            out[i] = .init(std.fmt.comptimePrint("{s}", .{c.name()}), commandAction(c), null);
        }
        const all = out;
        break :blk all;
    };

    // =====================================================================
    // Structural changes and their animation
    // =====================================================================

    /// Before a change: the model's structure and what the eye sees.
    fn prepare(self: *Self) !Pre {
        const priv = self.private();
        var before = try layout.change.snapshot(alloc, &priv.model);
        errdefer before.deinit();
        var v: Visual = .{};
        errdefer v.deinit();
        const p = self.progress();
        for (priv.items.items) |it| {
            const b = if (it.flight) |f| f.at(p) else it.box;
            try v.panes.append(alloc, .{ .col = it.col, .row = it.row, .box = b });
        }
        for (priv.dividers.items) |d| {
            const b = if (d.flight) |f| f.at(p) else d.box;
            try v.dividers.append(alloc, .{ .col = d.col, .row = d.row, .box = b });
        }
        if (priv.geom) |*g| {
            for (0..g.strip.columns.len) |ci| try v.cols.append(alloc, g.columnBox(ci));
            v.extent = @max(g.extent(), priv.keeper orelse 0);
        }
        return .{ .before = before, .visual = v };
    }

    /// After the model changed (and new items exist, a removed one is
    /// `gone`): lay out the final geometry once and animate into it.
    fn commit(self: *Self, pre: *Pre, gone: ?*Item) void {
        defer pre.deinit();
        const priv = self.private();
        const animate = !self.reducedMotion() and self.as(gtk.Widget).getMapped() != 0 and priv.geom != null;
        self.settle();

        var after = layout.change.snapshot(alloc, &priv.model) catch return;
        defer after.deinit();
        var chg = layout.change.diff(alloc, &pre.before, &after) catch return;
        defer chg.deinit();

        self.syncDividers();
        self.relayout();

        var any = false;
        if (animate) {
            any = self.planFlights(pre, &chg);
            if (gone) |it| {
                if (chg.leavingPane(it.id)) |l| if (pre.visual.oldPane(l.old)) |from| {
                    const above = if (l.above) |a| (if (self.itemById(a)) |x| x.box else null) else null;
                    const below = if (l.below) |b| (if (self.itemById(b)) |x| x.box else null) else null;
                    const lv = alloc.create(Leaving) catch @panic("OOM");
                    lv.* = .{ .item = it, .from = from, .cut = anim.exitCut(from, l.alone, above, below) };
                    priv.leaving.append(alloc, lv) catch @panic("OOM");
                    any = true;
                };
            }
        }
        if (gone) |it| {
            var kept = false;
            for (priv.leaving.items) |l| kept = kept or l.item == it;
            if (!kept) self.destroyItem(it);
        }
        if (any) {
            priv.anim_serial +%= 1;
            const now = self.frameTime();
            priv.anim = .{ .start_us = now, .serial = priv.anim_serial };
            // L-39: settled no later than 250 ms after it starts.
            priv.anim.?.timeout = glib.timeoutAdd(@intFromFloat(anim.settle_ms * time_scale), settleTimeout, self);
            // Hold the old scroll extent open while it runs.
            priv.keeper = pre.visual.extent;
            self.ensureTick();
        }

        self.clampScrollNow();
        if (any) self.chaseEnd();
        self.updateFocusClasses();
        self.reveal();
        self.scheduleSave();
        self.reportSummary();
        self.as(gtk.Widget).queueAllocate();
        self.as(gtk.Widget).queueDraw();
    }

    /// Flights for every pane and divider of the new layout, and ghosts for
    /// those that shrink. Returns whether anything moves.
    fn planFlights(self: *Self, pre: *const Pre, chg: *const layout.Change) bool {
        const priv = self.private();
        var any = false;
        const f = priv.model.focusedId();
        for (priv.items.items) |it| {
            const pc = chg.pane(it.id) orelse continue;
            const to = it.box;
            const from: Box = switch (pc.origin) {
                .moved => |s| pre.visual.oldPane(s) orelse to,
                else => anim.entryBox(pc.origin, true, to, &pre.visual),
            };
            const fresh = pc.origin.isFresh();
            if (!fresh and from.eql(to)) continue;
            const fl: Flight = .{ .from = from, .to = to, .fresh = fresh };
            it.flight = fl;
            any = true;
            if (fl.shrinks()) self.addGhost(fl, true, f != null and std.mem.eql(u8, f.?, it.id));
        }
        for (priv.dividers.items) |d| {
            if (d.col >= chg.columns.len or d.row >= chg.columns[d.col].dividers.len) continue;
            const origin = chg.columns[d.col].dividers[d.row].origin;
            const to = d.box;
            const from: Box = switch (origin) {
                .moved => |s| pre.visual.oldDivider(s) orelse to,
                else => anim.entryBox(origin, false, to, &pre.visual),
            };
            if (from.eql(to)) continue;
            const fl: Flight = .{ .from = from, .to = to };
            d.flight = fl;
            any = true;
            if (fl.shrinks()) self.addGhost(fl, false, false);
        }
        return any;
    }

    fn addGhost(self: *Self, fl: Flight, pane: bool, focused: bool) void {
        const priv = self.private();
        const box = gtk.Box.new(.horizontal, 0);
        const w = box.as(gtk.Widget);
        w.addCssClass("strip-ghost");
        w.addCssClass(if (pane) "pane-ghost" else "divider-ghost");
        if (focused) w.addCssClass("focused");
        w.setCanTarget(0);
        w.setCanFocus(0);
        w.setParent(self.as(gtk.Widget));
        const g = alloc.create(Ghost) catch @panic("OOM");
        g.* = .{ .widget = w, .flight = fl, .pane = pane, .focused = focused };
        priv.ghosts.append(alloc, g) catch @panic("OOM");
    }

    /// End a layout animation (app.js settleStrip): flights cleared,
    /// ghosts and leaving panes gone. The allocations were final already.
    fn settle(self: *Self) void {
        const priv = self.private();
        if (priv.anim) |a| {
            if (a.timeout != 0) _ = glib.Source.remove(a.timeout);
            priv.anim = null;
        }
        for (priv.items.items) |it| it.flight = null;
        for (priv.dividers.items) |d| d.flight = null;
        for (priv.ghosts.items) |g| {
            g.widget.unparent();
            alloc.destroy(g);
        }
        priv.ghosts.clearRetainingCapacity();
        for (priv.leaving.items) |l| {
            self.destroyItem(l.item);
            alloc.destroy(l);
        }
        priv.leaving.clearRetainingCapacity();
        if (priv.chase == null) {
            priv.keeper = null;
            self.clampScrollNow();
        }
        self.as(gtk.Widget).queueAllocate();
        self.as(gtk.Widget).queueDraw();
    }

    fn settleTimeout(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        const priv = self.private();
        if (priv.anim) |*a| {
            a.timeout = 0;
            self.settle();
        }
        return 0;
    }

    /// Eased progress of the running layout animation (1 when none).
    fn progress(self: *Self) f64 {
        const priv = self.private();
        const a = priv.anim orelse return 1;
        const ms = @as(f64, @floatFromInt(self.frameTime() - a.start_us)) / 1000;
        return anim.moveEase(ms / (anim.move_ms * time_scale));
    }

    /// Animation time. Monotonic time rather than the frame clock's: after
    /// the clock has been idle its frame time is stale, so the first frames
    /// of an animation or a chase measured with it jumped ahead (audit:
    /// the second chase step acted as if ~50 ms had passed).
    fn frameTime(self: *Self) i64 {
        _ = self;
        return glib.getMonotonicTime();
    }

    pub fn reducedMotion(self: *Self) bool {
        _ = self;
        if (reduced_override) |r| return r;
        const settings = gtk.Settings.getDefault() orelse return false;
        const obj = settings.as(gobject.Object);
        {
            var v = gobject.ext.Value.new(c_int);
            defer v.unset();
            obj.getProperty("gtk-enable-animations", &v);
            if (v.getInt() == 0) return true;
        }
        // gtk-interface-reduced-motion exists from GTK 4.20.
        if (gtk.getMajorVersion() > 4 or gtk.getMinorVersion() >= 20) {
            var v = gobject.ext.Value.new(gtk.ReducedMotion);
            defer v.unset();
            obj.getProperty("gtk-interface-reduced-motion", &v);
            if (v.getEnum() == @intFromEnum(gtk.ReducedMotion.reduce)) return true;
        }
        return false;
    }

    fn ensureTick(self: *Self) void {
        const priv = self.private();
        if (priv.tick_id == 0) priv.tick_id = self.as(gtk.Widget).addTickCallback(tick, null, null);
    }

    fn tick(w: *gtk.Widget, fc: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
        const self = gobject.ext.cast(Self, w).?;
        const priv = self.private();
        _ = fc;
        const now = glib.getMonotonicTime();
        if (priv.anim) |a| {
            const ms = @as(f64, @floatFromInt(now - a.start_us)) / 1000;
            if (ms >= anim.move_ms * time_scale) self.settle() else w.queueDraw();
        }
        if (priv.chase) |*c| {
            const dt: f64 = if (c.last_us) |l| @as(f64, @floatFromInt(now - l)) / 1000 else 16;
            c.last_us = now;
            const step = width.chaseStep(c.pos, c.target, dt / time_scale);
            c.pos = step.pos;
            priv.scroll = step.pos;
            if (step.done) self.endChase();
            w.queueAllocate();
        }
        if (priv.anim == null and priv.chase == null) {
            priv.tick_id = 0;
            return 0;
        }
        return 1;
    }

    // =====================================================================
    // Geometry and scrolling (L-15, L-16, L-25 … L-28)
    // =====================================================================

    /// One divider widget per divider of the model, in layout order.
    fn syncDividers(self: *Self) void {
        const priv = self.private();
        var need: usize = 0;
        for (priv.model.columns.items) |c| need += c.len() - 1;
        while (priv.dividers.items.len > need) {
            const d = priv.dividers.pop().?;
            d.widget.unparent();
            alloc.destroy(d);
        }
        while (priv.dividers.items.len < need) {
            const d = alloc.create(Divider) catch @panic("OOM");
            const box = gtk.Box.new(.horizontal, 0);
            const w = box.as(gtk.Widget);
            w.addCssClass("wm-divider");
            w.setCursorFromName("row-resize");
            d.* = .{ .ws = self, .widget = w };
            const drag = gtk.GestureDrag.new();
            _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Divider, dragBegin, d, .{});
            _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Divider, dragUpdate, d, .{});
            _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Divider, dragEnd, d, .{});
            w.addController(drag.as(gtk.EventController));
            w.setParent(self.as(gtk.Widget));
            priv.dividers.append(alloc, d) catch @panic("OOM");
        }
        var k: usize = 0;
        for (priv.model.columns.items, 0..) |c, ci| {
            for (0..c.len() - 1) |row| {
                priv.dividers.items[k].col = ci;
                priv.dividers.items[k].row = row;
                k += 1;
            }
        }
    }

    /// Recompute the geometry from the model and the strip's size, and
    /// give every pane and divider its final box.
    fn relayout(self: *Self) void {
        const priv = self.private();
        if (priv.vw <= 0 or priv.vh <= 0) return;
        const s = geometry.settingsOf(priv.settings.min_cols, priv.settings.max_cols);
        const g = geometry.compute(alloc, priv.model.columns.items, @floatFromInt(priv.vw), @floatFromInt(priv.vh), priv.cell_px, s) catch return;
        if (priv.geom) |*old| old.deinit(alloc);
        priv.geom = g;
        for (g.panes) |slot| {
            const id = priv.model.columns.items[slot.col].panes.items[slot.row].id;
            const it = self.itemById(id) orelse continue;
            it.col = slot.col;
            it.row = slot.row;
            it.box = slot.box.snapped();
        }
        for (g.dividers, 0..) |slot, i| {
            if (i >= priv.dividers.items.len) break;
            priv.dividers.items[i].box = slot.box.snapped();
        }
        self.as(gtk.Widget).queueAllocate();
    }

    fn maxScroll(self: *Self) f64 {
        const priv = self.private();
        const g = &(priv.geom orelse return 0);
        return geometry.maxScroll(g, priv.keeper);
    }

    fn clampScrollNow(self: *Self) void {
        const priv = self.private();
        priv.scroll = @max(0, @min(priv.scroll, self.maxScroll()));
    }

    /// app.js scrollStripTo.
    fn scrollTo(self: *Self, target_in: f64) void {
        const priv = self.private();
        const g = &(priv.geom orelse return);
        const target = geometry.clampScroll(g, priv.keeper, target_in);
        if (self.reducedMotion()) {
            self.endChase();
            priv.scroll = target;
            self.as(gtk.Widget).queueAllocate();
            return;
        }
        if (priv.chase) |*c| {
            c.target = target;
            return;
        }
        if (target == priv.scroll) return;
        priv.chase = .{ .target = target, .pos = priv.scroll, .last_us = glib.getMonotonicTime() };
        self.ensureTick();
    }

    /// The chase is over (arrived, or the hand took over).
    fn endChase(self: *Self) void {
        const priv = self.private();
        priv.chase = null;
        if (priv.anim == null and priv.keeper != null) {
            priv.keeper = null;
            self.clampScrollNow();
        }
    }

    /// L-25 (app.js revealFocusedNow): the minimum scroll that shows the
    /// focused column whole, judged against the target in flight.
    fn reveal(self: *Self) void {
        const priv = self.private();
        const g = &(priv.geom orelse return);
        const ci = priv.model.focusedColumn() orelse return;
        if (ci >= g.strip.columns.len) return;
        const c = g.strip.columns[ci];
        const left = c.x - g.strip.strip_pad;
        const right = c.right() + g.strip.strip_pad;
        var target = if (priv.chase) |ch| ch.target else priv.scroll;
        if (left < target) {
            target = left;
        } else if (right > target + g.strip.viewport) {
            target = right - g.strip.viewport;
        }
        self.scrollTo(target);
    }

    /// L-28 (app.js chaseStripEnd).
    fn chaseEnd(self: *Self) void {
        const priv = self.private();
        const g = &(priv.geom orelse return);
        if (g.strip.columns.len == 0) return;
        const last = g.strip.columns[g.strip.columns.len - 1];
        const max = @max(0, last.right() + g.strip.strip_pad - g.strip.viewport);
        if (priv.scroll > max) self.scrollTo(max);
    }

    /// L-27: a horizontal swipe pans the strip directly, cancelling any
    /// reveal in flight. `dx` in pixels.
    pub fn pan(self: *Self, dx: f64) void {
        const priv = self.private();
        self.endChase();
        priv.scroll = @max(0, @min(priv.scroll + dx, self.maxScroll()));
        self.as(gtk.Widget).queueAllocate();
    }

    /// Scroll handling shared by the capture- and bubble-phase controllers
    /// (and the control socket). Returns whether the strip took it.
    /// `capture`: the pass before the pane under the pointer sees the
    /// event; a file browser gets the event first (its own columns scroll,
    /// and it lets the event through at their edge to the bubble pass).
    pub fn handleScroll(self: *Self, dx_in: f64, dy_in: f64, unit: gdk.ScrollUnit, capture: bool, over: ?layout.Kind) bool {
        if (@abs(dx_in) <= @abs(dy_in)) return false;
        if (capture and over == .files) return false;
        const f: f64 = if (unit == .wheel) wheel_step_px else 1;
        self.pan(dx_in * f);
        return true;
    }

    fn kindAt(self: *Self, x: f64, y: f64) ?layout.Kind {
        const priv = self.private();
        const sx = x + @round(priv.scroll);
        for (priv.items.items) |it| {
            const b = it.box;
            if (sx >= b.x and sx < b.right() and y >= b.y and y < b.bottom()) return it.kind;
        }
        return null;
    }

    fn scrollCapture(ec: *gtk.EventControllerScroll, dx: f64, dy: f64, self: *Self) callconv(.c) c_int {
        const priv = self.private();
        const over = if (priv.pointer) |p| self.kindAt(p.x, p.y) else null;
        return @intFromBool(self.handleScroll(dx, dy, ec.getUnit(), true, over));
    }

    fn scrollBubble(ec: *gtk.EventControllerScroll, dx: f64, dy: f64, self: *Self) callconv(.c) c_int {
        return @intFromBool(self.handleScroll(dx, dy, ec.getUnit(), false, null));
    }

    fn motion(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.pointer = .{ .x = x, .y = y };
        const hover = if (self.scrollbarGeom()) |sb| sb.thumb.contains(x, y) else false;
        if (hover != priv.sb_hover) {
            priv.sb_hover = hover;
            self.as(gtk.Widget).queueDraw();
        }
    }

    fn motionLeave(_: *gtk.EventControllerMotion, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.pointer = null;
        if (priv.sb_hover and priv.sb_drag == null) {
            priv.sb_hover = false;
            self.as(gtk.Widget).queueDraw();
        }
    }

    // =====================================================================
    // The strip's scrollbar (index.html ::-webkit-scrollbar: 10 px,
    // transparent track, a pill thumb inset 3 px, brighter on hover)
    // =====================================================================

    pub const Scrollbar = struct {
        /// Widget coordinates.
        track: Box,
        thumb: Box,
        /// Scroll offset per pixel of thumb travel.
        per_px: f64,
    };

    /// Chromium's geometry: the thumb's length is the visible fraction of
    /// the track (at least 20 px), its position the scrolled fraction.
    pub fn scrollbarGeom(self: *Self) ?Scrollbar {
        const priv = self.private();
        const g = &(priv.geom orelse return null);
        if (!g.scrollbar) return null;
        const vw: f64 = @floatFromInt(priv.vw);
        const vh: f64 = @floatFromInt(priv.vh);
        const extent = @max(g.extent(), priv.keeper orelse 0);
        const max = @max(1, extent - vw);
        const len = @min(vw, @max(20, vw * vw / extent));
        const travel = @max(1, vw - len);
        const pos = std.math.clamp(@round(priv.scroll) / max, 0, 1) * travel;
        return .{
            .track = .{ .x = 0, .y = vh - geometry.scrollbar_px, .w = vw, .h = geometry.scrollbar_px },
            .thumb = .{ .x = pos, .y = vh - geometry.scrollbar_px, .w = len, .h = geometry.scrollbar_px },
            .per_px = max / travel,
        };
    }

    fn drawScrollbar(self: *Self, snap: *gtk.Snapshot) void {
        const priv = self.private();
        const sb = self.scrollbarGeom() orelse return;
        const dark = frame_mod.isDark();
        const hot = priv.sb_hover or priv.sb_drag != null;
        // --scrollbar / --scrollbar-hover in both schemes.
        const c: gdk.RGBA = if (dark)
            .{ .f_red = 200.0 / 255.0, .f_green = 200.0 / 255.0, .f_blue = 216.0 / 255.0, .f_alpha = if (hot) 0.4 else 0.22 }
        else
            .{ .f_red = 52.0 / 255.0, .f_green = 59.0 / 255.0, .f_blue = 88.0 / 255.0, .f_alpha = if (hot) 0.45 else 0.25 };
        const t = sb.thumb;
        var rr: gsk.RoundedRect = undefined;
        _ = rr.initFromRect(&rect(t.x + 3, t.y + 3, t.w - 6, t.h - 6), 2);
        snap.pushRoundedClip(&rr);
        snap.appendColor(&c, &rect(t.x + 3, t.y + 3, t.w - 6, t.h - 6));
        snap.pop();
    }

    fn sbDragBegin(g: *gtk.GestureDrag, x: f64, y: f64, self: *Self) callconv(.c) void {
        if (!self.scrollbarPress(x, y)) _ = g.as(gtk.Gesture).setState(.denied) else _ = g.as(gtk.Gesture).setState(.claimed);
    }

    fn sbDragUpdate(_: *gtk.GestureDrag, off_x: f64, _: f64, self: *Self) callconv(.c) void {
        self.scrollbarDragTo(off_x);
    }

    fn sbDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, self: *Self) callconv(.c) void {
        self.private().sb_drag = null;
        self.as(gtk.Widget).queueDraw();
    }

    /// A press at (x, y): on the thumb it starts a drag; elsewhere on the
    /// track it pages the strip towards the press (Chromium scrolls by
    /// 87.5 % of the view). False when the press is not on the scrollbar.
    pub fn scrollbarPress(self: *Self, x: f64, y: f64) bool {
        const priv = self.private();
        const sb = self.scrollbarGeom() orelse return false;
        if (!sb.track.contains(x, y)) return false;
        if (sb.thumb.contains(x, y)) {
            self.endChase();
            priv.sb_drag = .{ .start_scroll = priv.scroll, .per_px = sb.per_px };
        } else {
            const page = 0.875 * @as(f64, @floatFromInt(priv.vw));
            const from = if (priv.chase) |ch| ch.target else priv.scroll;
            self.scrollTo(if (x < sb.thumb.x) from - page else from + page);
        }
        self.as(gtk.Widget).queueDraw();
        return true;
    }

    pub fn scrollbarDragTo(self: *Self, off_x: f64) void {
        const priv = self.private();
        const d = priv.sb_drag orelse return;
        priv.scroll = @max(0, @min(d.start_scroll + off_x * d.per_px, self.maxScroll()));
        self.as(gtk.Widget).queueAllocate();
    }

    // =====================================================================
    // Divider drags (L-29, L-30)
    // =====================================================================

    // The gesture lives on the divider, which moves under the pointer on
    // every update, so GestureDrag's offsets (relative to the moving
    // widget) are useless (the audit's L-30: half speed, oscillation).
    // Every update takes the pointer's own position instead, converted
    // through the divider's current transform into the strip's
    // coordinates: strip y, which does not scroll vertically.

    fn pointerStripY(g: *gtk.GestureDrag, d: *Divider) ?f64 {
        const gs = g.as(gtk.Gesture);
        const seq = g.as(gtk.GestureSingle).getCurrentSequence();
        var x: f64 = 0;
        var y: f64 = 0;
        if (gs.getPoint(seq, &x, &y) == 0) return null;
        const local: graphene.Point = .{ .f_x = @floatCast(x), .f_y = @floatCast(y) };
        var out: graphene.Point = undefined;
        if (d.widget.computePoint(d.ws.as(gtk.Widget), &local, &out) == 0) return null;
        return out.f_y;
    }

    fn dragBegin(g: *gtk.GestureDrag, _: f64, _: f64, d: *Divider) callconv(.c) void {
        d.ws.dividerDragBegin(d, pointerStripY(g, d) orelse d.box.y + d.box.h / 2);
    }

    fn dragUpdate(g: *gtk.GestureDrag, _: f64, _: f64, d: *Divider) callconv(.c) void {
        const y = pointerStripY(g, d) orelse return;
        d.ws.dividerDragTo(d, y);
    }

    fn dragEnd(_: *gtk.GestureDrag, _: f64, _: f64, d: *Divider) callconv(.c) void {
        d.ws.dividerDragEnd(d);
    }

    pub fn dividerAt(self: *Self, col: usize, row: usize) ?*Divider {
        for (self.private().dividers.items) |d| if (d.col == col and d.row == row) return d;
        return null;
    }

    /// `pointer_y`: in strip space (the divider's own top + the press).
    pub fn dividerDragBegin(self: *Self, d: *Divider, pointer_y: f64) void {
        const priv = self.private();
        self.settle();
        d.drag_start_y = pointer_y;
        priv.dragging = d;
        d.widget.addCssClass("dragging");
    }

    pub fn dividerDragTo(self: *Self, d: *Divider, pointer_y: f64) void {
        const priv = self.private();
        const g = &(priv.geom orelse return);
        if (d.col >= g.stacks.len) return;
        const st = &g.stacks[d.col];
        if (d.row + 1 >= st.panes.len) return;
        const span = st.dividerSpan(d.row);
        const offset = st.dividerOffset(d.row, pointer_y);
        if (priv.model.dragDivider(d.col, d.row, offset, span, Layout.min_pane_px)) {
            // Terminals refit live (their allocation changes).
            self.relayout();
        }
    }

    pub fn dividerDragEnd(self: *Self, d: *Divider) void {
        const priv = self.private();
        priv.dragging = null;
        d.widget.removeCssClass("dragging");
        self.scheduleSave();
    }

    // =====================================================================
    // Persistence
    // =====================================================================

    fn scheduleSave(self: *Self) void {
        const priv = self.private();
        if (!priv.loaded or priv.layout_path == null) return;
        if (priv.save_source == 0) priv.save_source = glib.timeoutAdd(save_delay_ms, saveTimeout, self);
    }

    fn saveTimeout(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        self.private().save_source = 0;
        self.saveNow();
        return 0;
    }

    pub fn saveNow(self: *Self) void {
        const priv = self.private();
        if (priv.save_source != 0) {
            _ = glib.Source.remove(priv.save_source);
            priv.save_source = 0;
        }
        if (!priv.loaded) return;
        const path = priv.layout_path orelse return;
        // File browsers' own state (F-02) goes in with the layout.
        for (priv.items.items) |it| {
            if (it.kind != .files) continue;
            const p = it.pane orelse continue;
            const st = p.saveState(alloc) catch continue;
            if (st) |s| {
                defer alloc.free(s);
                priv.model.setPaneState(it.id, s) catch |err| log.warn("{s}: pane {s} state not saved: {t}", .{ priv.name, it.id, err });
            }
        }
        const text = layout.persist.serialize(alloc, &priv.model) catch return;
        defer alloc.free(text);
        store.write(global.io(), path, text) catch |err| {
            log.warn("{s}: layout not saved to {s}: {t}", .{ priv.name, path, err });
            return;
        };
        priv.saves += 1;
    }

    // =====================================================================
    // Settings, cell width, messages
    // =====================================================================

    fn settingsChanged(ctx: *anyopaque, new_settings: *const conn.Settings) void {
        const self = fromCtx(ctx);
        const priv = self.private();
        if (priv.disposed) return;
        priv.settings = new_settings.*;
        self.settle();
        self.relayout();
        self.clampScrollNow();
        self.updateFocusClasses();
        self.reveal();
    }

    fn cellPoll(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        self.checkCellWidth();
        return 1;
    }

    /// L-16: the width rule follows the terminal's cell (font size, scale).
    fn checkCellWidth(self: *Self) void {
        const priv = self.private();
        for (priv.items.items) |it| {
            if (it.kind != .terminal) continue;
            const p = it.pane orelse continue;
            const dev = p.cellWidthPx() orelse continue;
            const scale = scale_util.widgetSurfaceScale(p.widget);
            const css = @as(f64, @floatFromInt(dev)) / (if (scale > 0) scale else 1);
            last_cell_px = css;
            if (@abs(css - priv.cell_px) > 0.001) {
                log.info("{s}: cell width {d:.3} px (was {d:.3})", .{ priv.name, css, priv.cell_px });
                priv.cell_px = css;
                self.settle();
                self.relayout();
                self.clampScrollNow();
                self.reveal();
            }
            return;
        }
    }

    fn showMessage(self: *Self, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const t = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "…";
        const l = self.private().message;
        l.setText(t.ptr);
        l.as(gtk.Widget).setVisible(1);
    }

    fn hideMessage(self: *Self) void {
        self.private().message.as(gtk.Widget).setVisible(0);
    }

    fn statusf(self: *Self, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, fmt, args) catch "…";
        iface.services.status(self.private().name, t);
    }

    // =====================================================================
    // GTK: measure, allocate, draw
    // =====================================================================

    fn measure(
        _: *Self,
        _: gtk.Orientation,
        _: c_int,
        minimum: ?*c_int,
        natural: ?*c_int,
        min_baseline: ?*c_int,
        nat_baseline: ?*c_int,
    ) callconv(.c) void {
        if (minimum) |m| m.* = 0;
        if (natural) |n| n.* = 0;
        if (min_baseline) |b| b.* = -1;
        if (nat_baseline) |b| b.* = -1;
    }

    fn sizeAllocate(self: *Self, w: c_int, h: c_int, _: c_int) callconv(.c) void {
        const priv = self.private();
        if (w != priv.vw or h != priv.vh) {
            priv.vw = w;
            priv.vh = h;
            // L-16: a resize refits and re-reveals (no layout animation).
            self.settle();
            self.relayout();
            self.clampScrollNow();
            self.reveal();
        }
        const sx = @round(priv.scroll);
        for (priv.items.items) |it| allocBox(it.frame.as(gtk.Widget), it.box, sx);
        for (priv.dividers.items) |d| allocBox(d.widget, d.box, sx);
        for (priv.ghosts.items) |g| allocBox(g.widget, g.flight.ghostBox(), sx);
        for (priv.leaving.items) |l| allocBox(l.item.frame.as(gtk.Widget), l.item.box, sx);
        const m = priv.message.as(gtk.Widget);
        if (m.getVisible() != 0) {
            var mn: c_int = 0;
            m.measure(.horizontal, -1, &mn, null, null, null);
            m.allocate(@max(w, mn), h, -1, null);
        }
    }

    fn allocBox(w: *gtk.Widget, b: Box, sx: f64) void {
        var mn: c_int = 0;
        w.measure(.horizontal, -1, &mn, null, null, null);
        w.measure(.vertical, -1, &mn, null, null, null);
        var p: graphene.Point = .{ .f_x = @floatCast(b.x - sx), .f_y = @floatCast(b.y) };
        const t = gsk.Transform.translate(null, &p);
        w.allocate(@intFromFloat(b.w), @intFromFloat(b.h), -1, t);
    }

    fn rect(x: f64, y: f64, w: f64, h: f64) graphene.Rect {
        return .{ .f_origin = .{ .f_x = @floatCast(x), .f_y = @floatCast(y) }, .f_size = .{ .f_width = @floatCast(@max(0, w)), .f_height = @floatCast(@max(0, h)) } };
    }

    fn pushRoundedClip(snap: *gtk.Snapshot, r: graphene.Rect, radius: f64) void {
        var rr: gsk.RoundedRect = undefined;
        _ = rr.initFromRect(&r, @floatCast(radius));
        snap.pushRoundedClip(&rr);
    }

    /// One element of the strip at its in-flight box: its allocation is
    /// the final box `a`; it is translated back to `v`'s origin, clipped to
    /// `v`'s size while it grows, and faded in when it is fresh.
    fn drawMoving(self: *Self, snap: *gtk.Snapshot, child: *gtk.Widget, a: Box, fl: ?Flight, p: f64, radius: f64) void {
        const w = self.as(gtk.Widget);
        const f = fl orelse {
            w.snapshotChild(child, snap);
            return;
        };
        const sx = @round(self.private().scroll);
        const v = f.at(p);
        snap.save();
        var off: graphene.Point = .{ .f_x = @floatCast(v.x - a.x), .f_y = @floatCast(v.y - a.y) };
        snap.translate(&off);
        var pushes: usize = 0;
        if (f.grows()) {
            pushRoundedClip(snap, rect(a.x - sx, a.y, @min(a.w, v.w), @min(a.h, v.h)), radius);
            pushes += 1;
        }
        if (f.fresh) {
            snap.pushOpacity(p);
            pushes += 1;
        }
        w.snapshotChild(child, snap);
        for (0..pushes) |_| snap.pop();
        snap.restore();
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const priv = self.private();
        const w = self.as(gtk.Widget);
        const W: f64 = @floatFromInt(w.getWidth());
        const H: f64 = @floatFromInt(w.getHeight());
        const p = self.progress();
        const sx = @round(priv.scroll);
        const k = self.fadeStrength();
        snap.pushClip(&rect(0, 0, W, H));

        // Ghosts under everything, then dividers, leaving panes, panes,
        // and the focused pane on top (app.js z-index -1/1/1/2/3).
        for (priv.ghosts.items) |g| {
            const a = g.flight.ghostBox();
            const v = g.flight.at(p);
            snap.save();
            var off: graphene.Point = .{ .f_x = @floatCast(v.x - a.x), .f_y = @floatCast(v.y - a.y) };
            snap.translate(&off);
            const clip = rect(a.x - sx, a.y, v.w, v.h);
            pushRoundedClip(snap, clip, if (g.pane) anim.pane_radius else anim.divider_radius);
            w.snapshotChild(g.widget, snap);
            if (g.pane and !g.focused) frame_mod.appendFade(snap, clip, k, false);
            snap.pop();
            snap.restore();
        }
        for (priv.dividers.items) |d| self.drawMoving(snap, d.widget, d.box, d.flight, p, anim.divider_radius);
        for (priv.leaving.items) |l| {
            const a = l.item.box;
            const c = anim.exitClip(l.from, l.cut, p);
            snap.save();
            var off: graphene.Point = .{ .f_x = @floatCast(l.from.x - a.x), .f_y = @floatCast(l.from.y - a.y) };
            snap.translate(&off);
            pushRoundedClip(snap, rect(c.x - l.from.x + a.x - sx, c.y - l.from.y + a.y, c.w, c.h), anim.pane_radius);
            w.snapshotChild(l.item.frame.as(gtk.Widget), snap);
            snap.pop();
            snap.restore();
        }
        var focused: ?*Item = null;
        const fid = priv.model.focusedId();
        for (priv.items.items) |it| {
            if (fid != null and std.mem.eql(u8, fid.?, it.id)) {
                focused = it;
                continue;
            }
            self.drawMoving(snap, it.frame.as(gtk.Widget), it.box, it.flight, p, anim.pane_radius);
        }
        if (focused) |it| self.drawMoving(snap, it.frame.as(gtk.Widget), it.box, it.flight, p, anim.pane_radius);
        self.drawScrollbar(snap);
        if (priv.message.as(gtk.Widget).getVisible() != 0) w.snapshotChild(priv.message.as(gtk.Widget), snap);
        snap.pop();
    }

    // =====================================================================
    // GObject
    // =====================================================================

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.* = .{};
        const w = self.as(gtk.Widget);
        w.setFocusable(1);
        w.setOverflow(.hidden);
        w.setHexpand(1);
        w.setVexpand(1);

        const msg = gtk.Label.new("");
        msg.setWrap(1);
        msg.setJustify(.center);
        msg.as(gtk.Widget).addCssClass("workspace-message");
        msg.as(gtk.Widget).setVisible(0);
        msg.as(gtk.Widget).setCanTarget(0);
        msg.as(gtk.Widget).setParent(w);
        priv.message = msg;

        const sm = adw.StyleManager.getDefault();
        _ = gobject.Object.signals.notify.connect(sm, *Self, schemeChanged, self, .{ .detail = "dark" });
        self.applyScheme();

        const group = ext.actions.addAsGroup(Self, self, iface.actions.pane_group, &command_actions);
        group.unref();

        const cap = gtk.EventControllerScroll.new(.{ .horizontal = true, .vertical = true });
        cap.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerScroll.signals.scroll.connect(cap, *Self, scrollCapture, self, .{});
        w.addController(cap.as(gtk.EventController));
        const bub = gtk.EventControllerScroll.new(.{ .horizontal = true, .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(bub, *Self, scrollBubble, self, .{});
        w.addController(bub.as(gtk.EventController));
        const mot = gtk.EventControllerMotion.new();
        mot.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerMotion.signals.motion.connect(mot, *Self, motion, self, .{});
        _ = gtk.EventControllerMotion.signals.enter.connect(mot, *Self, motion, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(mot, *Self, motionLeave, self, .{});
        w.addController(mot.as(gtk.EventController));
        const sbd = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(sbd, *Self, sbDragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(sbd, *Self, sbDragUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(sbd, *Self, sbDragEnd, self, .{});
        w.addController(sbd.as(gtk.EventController));
    }

    fn schemeChanged(_: *adw.StyleManager, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.applyScheme();
    }

    /// Light/dark follows libadwaita's style manager (the app forces it).
    fn applyScheme(self: *Self) void {
        const w = self.as(gtk.Widget);
        if (frame_mod.isDark()) w.removeCssClass("light") else w.addCssClass("light");
        w.queueDraw();
        for (self.private().items.items) |it| it.frame.as(gtk.Widget).queueDraw();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.disposed) {
            priv.disposed = true;
            _ = gobject.signalHandlersDisconnectMatched(adw.StyleManager.getDefault().as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            // Pending changes reach the file before the panes go.
            if (priv.save_source != 0) self.saveNow();
            iface.settings.unsubscribe(self);
            inline for (.{ "list_retry", "cell_poll" }) |f| {
                if (@field(priv, f) != 0) {
                    _ = glib.Source.remove(@field(priv, f));
                    @field(priv, f) = 0;
                }
            }
            if (priv.tick_id != 0) {
                self.as(gtk.Widget).removeTickCallback(priv.tick_id);
                priv.tick_id = 0;
            }
            if (priv.anim) |a| if (a.timeout != 0) {
                _ = glib.Source.remove(a.timeout);
            };
            priv.anim = null;
            for (priv.ghosts.items) |g| {
                g.widget.unparent();
                alloc.destroy(g);
            }
            priv.ghosts.deinit(alloc);
            for (priv.leaving.items) |l| {
                self.destroyItem(l.item);
                alloc.destroy(l);
            }
            priv.leaving.deinit(alloc);
            for (priv.items.items) |it| self.destroyItem(it);
            priv.items.deinit(alloc);
            for (priv.dividers.items) |d| {
                d.widget.unparent();
                alloc.destroy(d);
            }
            priv.dividers.deinit(alloc);
            priv.message.as(gtk.Widget).unparent();
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.geom) |*g| g.deinit(alloc);
        priv.model.deinit();
        alloc.free(priv.socket_path);
        alloc.free(priv.slug);
        alloc.free(priv.name);
        if (priv.layout_path) |p| alloc.free(p);
        if (priv.saved_text) |t| alloc.free(t);
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        pub const as = C.Class.as;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(PaneFrame);
            const wc = class.as(gtk.Widget.Class);
            gtk.Widget.Class.setCssName(wc, "workspace-strip");
            gtk.Widget.virtual_methods.measure.implement(class, &measure);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };

    // =====================================================================
    // Introspection (control socket)
    // =====================================================================

    pub const Dump = struct {
        name: []const u8,
        loaded: bool,
        front: bool,
        focused: ?[]const u8,
        has_keyboard_focus_in: ?[]const u8,
        scroll: f64,
        scroll_target: ?f64,
        max_scroll: f64,
        keeper: ?f64,
        viewport: struct { w: c_int, h: c_int },
        cell_px: f64,
        fit: usize,
        col_min: f64,
        col_max: f64,
        animating: bool,
        chasing: bool,
        reduced_motion: bool,
        pending_creates: u32,
        offline: bool,
        pane_count: usize,
        saves: u32,
        message: ?[]const u8,
        layout_file: ?[]const u8,
        leaving: []const []const u8,
        ghosts: usize,
        /// The strip's scrollbar (widget coordinates), null when the strip
        /// does not overflow.
        scrollbar: ?struct { thumb: DumpBox, hover: bool, dragging: bool },
        columns: []const DumpColumn,
    };
    pub const DumpColumn = struct {
        x: f64,
        width: f64,
        full: bool,
        active: []const u8,
        panes: []const DumpPane,
        dividers: []const DumpBox,
    };
    pub const DumpBox = struct { x: f64, y: f64, w: f64, h: f64 };
    pub const DumpPane = struct {
        id: []const u8,
        kind: []const u8,
        title: []const u8,
        weight: f64,
        box: DumpBox,
        /// On screen right now (mid-flight box when animating).
        visual: DumpBox,
        focused: bool,
        fade: f64,
        bar_height: c_int,
        placeholder: bool,
        link_down: bool,
        has_flight: bool,
    };

    fn dumpBox(b: Box) DumpBox {
        return .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
    }

    pub fn dump(self: *Self, a: Allocator) !Dump {
        const priv = self.private();
        const p = self.progress();
        var cols: std.ArrayList(DumpColumn) = .empty;
        const fid = priv.model.focusedId();
        for (priv.model.columns.items, 0..) |col, ci| {
            var panes: std.ArrayList(DumpPane) = .empty;
            for (col.panes.items, 0..) |mp, row| {
                const it = self.itemById(mp.id) orelse continue;
                try panes.append(a, .{
                    .id = it.id,
                    .kind = @tagName(it.kind),
                    .title = try a.dupe(u8, it.frame.title()),
                    .weight = col.sizes.items[row],
                    .box = dumpBox(it.box),
                    .visual = dumpBox(if (it.flight) |f| f.at(p) else it.box),
                    .focused = fid != null and std.mem.eql(u8, fid.?, it.id),
                    .fade = it.frame.fadeNow(),
                    .bar_height = it.frame.barHeight(),
                    .placeholder = it.pane == null,
                    .link_down = it.link_down,
                    .has_flight = it.flight != null,
                });
            }
            var divs: std.ArrayList(DumpBox) = .empty;
            for (priv.dividers.items) |d| if (d.col == ci) try divs.append(a, dumpBox(d.box));
            const cb: width.ColumnBox = if (priv.geom) |g| (if (ci < g.strip.columns.len) g.strip.columns[ci] else .{ .x = 0, .width = 0 }) else .{ .x = 0, .width = 0 };
            try cols.append(a, .{
                .x = cb.x,
                .width = cb.width,
                .full = col.full,
                .active = col.active.id,
                .panes = panes.items,
                .dividers = divs.items,
            });
        }
        var leaving: std.ArrayList([]const u8) = .empty;
        for (priv.leaving.items) |l| try leaving.append(a, l.item.id);
        const offline = priv.link_offline;
        var kb: ?[]const u8 = null;
        if (self.as(gtk.Widget).getRoot()) |root| if (gobject.ext.cast(gtk.Window, root)) |win| if (win.getFocus()) |fw| {
            for (priv.items.items) |it| if (fw.isAncestor(it.frame.as(gtk.Widget)) != 0) {
                kb = it.id;
            };
            if (kb == null and fw == self.as(gtk.Widget)) kb = "(workspace)";
        };
        const msgw = priv.message.as(gtk.Widget);
        return .{
            .name = priv.name,
            .loaded = priv.loaded,
            .front = priv.front,
            .focused = fid,
            .has_keyboard_focus_in = kb,
            .scroll = priv.scroll,
            .scroll_target = if (priv.chase) |c| c.target else null,
            .max_scroll = self.maxScroll(),
            .keeper = priv.keeper,
            .viewport = .{ .w = priv.vw, .h = priv.vh },
            .cell_px = priv.cell_px,
            .fit = if (priv.geom) |g| g.strip.widths.fit else 0,
            .col_min = if (priv.geom) |g| g.strip.widths.min else 0,
            .col_max = if (priv.geom) |g| g.strip.widths.max else 0,
            .animating = priv.anim != null,
            .chasing = priv.chase != null,
            .reduced_motion = self.reducedMotion(),
            .pending_creates = priv.pending_creates,
            .offline = offline,
            .pane_count = priv.model.paneCount(),
            .saves = priv.saves,
            .message = if (msgw.getVisible() != 0) try a.dupe(u8, std.mem.span(priv.message.getText())) else null,
            .layout_file = priv.layout_path,
            .leaving = leaving.items,
            .ghosts = priv.ghosts.items.len,
            .scrollbar = if (self.scrollbarGeom()) |sb| .{ .thumb = dumpBox(sb.thumb), .hover = priv.sb_hover, .dragging = priv.sb_drag != null } else null,
            .columns = cols.items,
        };
    }

    /// Settled: no layout animation, no scroll chase, no session create or
    /// list in flight, and the session list has been read.
    pub fn settled(self: *Self) bool {
        const priv = self.private();
        return priv.loaded and priv.anim == null and priv.chase == null and priv.pending_creates == 0 and !priv.list_inflight;
    }

    pub fn paneFrame(self: *Self, id: []const u8) ?*PaneFrame {
        const it = self.itemById(id) orelse return null;
        return it.frame;
    }

    pub fn scrollOver(self: *Self, id: ?[]const u8) ?layout.Kind {
        const i = id orelse return null;
        const it = self.itemById(i) orelse return null;
        return it.kind;
    }
};

/// Every workspace widget in a widget tree (for the control socket).
pub fn collect(widget: *gtk.Widget, buf: []*Workspace, n: *usize) void {
    if (n.* >= buf.len) return;
    if (gobject.ext.cast(Workspace, widget)) |ws| {
        buf[n.*] = ws;
        n.* += 1;
        return;
    }
    var child = widget.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) collect(c, buf, n);
}

