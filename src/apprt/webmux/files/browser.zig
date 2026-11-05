//! `WebmuxFilesBrowser`: the file-browser pane, a Finder-style Miller
//! columns view of the host's filesystem. The native port of
//! electron/ui/files-widget.js; the PARITY ids (F-nn) in comments point at
//! the behaviour each part implements.
//!
//!   columns   the chain from '/' down to `dir`, plus one column for the
//!             cursor entry: its listing (a directory) or its preview.
//!   render    `rerender` asks for every listing it needs (4 s cache,
//!             fetched on worker threads) and patches the column strip
//!             when they are all there; superseded renders are dropped.
//!   preview   text, rendered markdown, images, zip trees, stat-only.
//!   live      one watch stream for the cursor's directory and one for the
//!             directory under the cursor; focus re-lists everything shown.
//!   mutate    rename (inline entry), delete (confirmation over the pane),
//!             upload (drop, paste), download (save dialog).
//!
//! Everything here runs on the main thread. Host calls go through
//! `jobs.Task`; their results come back through `jobs.Shared.browser`,
//! which `dispose` clears.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const iface = @import("../iface.zig");
const global = @import("../../../global.zig");
const net = @import("../../../webmux/net.zig");
const api = @import("api.zig");
const wire = @import("wire.zig");
const paths = @import("paths.zig");
const zip = @import("zip.zig");
const md = @import("markdown.zig");
const scrolling = @import("scrolling.zig");
const md_view = @import("md_view.zig");
const jobs = @import("jobs.zig");
const uploads = @import("uploads.zig");
const savefile = @import("savefile.zig");
const Clip = @import("clip.zig").Clip;

const log = std.log.scoped(.webmux_files);
const alloc = std.heap.c_allocator;


// Geometry and timing from index.html / files-widget.js.
const col_min = 200; // F-08
const col_max = 420;
const col_chrome = 72;
const preview_wide = 600; // F-30
const preview_narrow = 280;
const list_ttl_ms = 4000; // F-12
const scroll_step = 48; // F-44
const enter_ms = 180; // F-62
const swap_ms = 140;
const follow_ms = 300; // F-63

/// An animation's duration, 1 ms under reduced motion.
fn motionMs(ms: i64) i64 {
    return if (Browser.reducedMotion()) 1 else ms;
}

fn nowMs() i64 {
    return @divTrunc(glib.getMonotonicTime(), 1000);
}

fn dupeZ(s: []const u8) [:0]u8 {
    return alloc.dupeSentinel(u8, s, 0) catch @panic("OOM");
}

fn dupe(s: []const u8) []u8 {
    return alloc.dupe(u8, s) catch @panic("OOM");
}

/// A directory listing in the cache. Reference counted: columns keep the
/// one they show while the cache moves on.
pub const Listing = struct {
    rc: u32 = 1,
    arena: std.heap.ArenaAllocator,
    /// The host's error code (or the transport error); entries empty.
    err: ?[]const u8 = null,
    path: []const u8 = "",
    entries: []Entry = &.{},
    truncated: bool = false,
    /// Fitted column width, measured on first use (F-08).
    width: ?f64 = null,

    pub const Entry = struct {
        name: [:0]const u8,
        dir: bool,
        symlink: bool,
    };

    fn fromResult(result: wire.Result(wire.Listing)) *Listing {
        const self = alloc.create(Listing) catch @panic("OOM");
        self.* = .{ .arena = .init(alloc) };
        const a = self.arena.allocator();
        switch (result) {
            .err => |e| self.err = a.dupe(u8, e) catch @panic("OOM"),
            .ok => |l| {
                self.path = a.dupe(u8, l.path) catch @panic("OOM");
                self.truncated = l.truncated;
                self.entries = a.alloc(Entry, l.entries.len) catch @panic("OOM");
                for (l.entries, self.entries) |src, *dst| dst.* = .{
                    .name = a.dupeSentinel(u8, src.name, 0) catch @panic("OOM"),
                    .dir = src.dir,
                    .symlink = src.symlink,
                };
            },
        }
        return self;
    }

    fn ref(self: *Listing) *Listing {
        self.rc += 1;
        return self;
    }

    fn unref(self: *Listing) void {
        self.rc -= 1;
        if (self.rc > 0) return;
        self.arena.deinit();
        alloc.destroy(self);
    }

    pub fn find(self: *const Listing, name: []const u8) ?usize {
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }
};

const CacheEntry = struct { t: i64, l: *Listing };

/// One column in the strip.
pub const Col = struct {
    kind: Kind,
    /// Directory path (listings) or "preview".
    key: []u8,
    clip: *Clip,
    /// The clip's child: `.files-col`, carries the drop target.
    frame: *gtk.Box,
    browser: *Browser,
    leaving: bool = false,

    // listing
    listing: ?*Listing = null,
    scroller: ?*gtk.ScrolledWindow = null,
    rows_box: ?*gtk.Box = null,
    rows: std.ArrayList(*gtk.Box) = .empty,
    hl: ?usize = null,
    cursor_col: bool = false,
    acts: ?*gtk.Box = null,
    restore_scroll: ?f64 = null,
    /// Every entry of `listing` has its row (they are built in chunks).
    rows_done: bool = true,

    // preview
    pv: Pv = .{},

    pub const Kind = enum { listing, preview };

    const Pv = struct {
        path: ?[]u8 = null,
        narrow: bool = false,
        /// The stat for the current path has arrived.
        loaded: bool = false,
        arena: ?std.heap.ArenaAllocator = null,
        info: ?wire.Preview = null,
        err: ?[]u8 = null,
        failed: bool = false,
        body: ?*gtk.ScrolledWindow = null,
        content: ?*gtk.Widget = null,
        /// Bumped whenever the content is rebuilt (stale image loads).
        load: u64 = 0,
        doc: ?md.Doc = null,
        image: ?struct { w: c_int, h: c_int } = null,
        image_failed: bool = false,
        toggle: [2]?*gtk.ToggleButton = .{ null, null },
        download: ?*gtk.Button = null,
        restore_scroll: ?f64 = null,
        /// `restore_scroll` belongs to a body rebuilt since it was saved.
        restore_rebuilt: bool = false,
        rendered_md: bool = false,
        md_images: u32 = 0,
        md_images_loaded: u32 = 0,
        md_images_failed: u32 = 0,
    };

    fn clearPreviewData(self: *Col) void {
        if (self.pv.doc) |*d| d.deinit();
        self.pv.doc = null;
        if (self.pv.arena) |*a| a.deinit();
        self.pv.arena = null;
        self.pv.info = null;
        if (self.pv.err) |e| alloc.free(e);
        self.pv.err = null;
        self.pv.failed = false;
        self.pv.image = null;
        self.pv.image_failed = false;
    }

    fn destroy(self: *Col) void {
        if (self.listing) |l| l.unref();
        self.rows.deinit(alloc);
        self.clearPreviewData();
        if (self.pv.path) |p| alloc.free(p);
        alloc.free(self.key);
        alloc.destroy(self);
    }
};

const Rename = struct {
    entry: *gtk.Entry,
    row: *gtk.Box,
    name_label: *gtk.Widget,
    old: []u8,
    dir: []u8,
    settled: bool = false,
};

const Confirm = struct {
    backdrop: *gtk.Box,
    dialog: *gtk.Box,
    cancel: *gtk.Button,
    delete: *gtk.Button,
    text: [:0]u8,
    name: []u8,
    dir: []u8,
    /// Index of the entry in its listing when asked (cursor after delete).
    entries: []const []const u8,
    index: usize,
};

const Follow = struct {
    active: bool = false,
    t0: i64 = 0,
};

pub const Browser = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxFilesBrowser",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        shared: *jobs.Shared = undefined,
        id: []u8 = &.{},
        conn_name: []u8 = &.{},
        host: ?iface.PaneHost = null,

        // F-02 state
        dir: []u8 = &.{},
        cursor: ?[]u8 = null,
        home: ?[]u8 = null,
        opened: bool = false,
        open_failed: ?[]u8 = null,

        overlay: *gtk.Overlay = undefined,
        scroller: *gtk.ScrolledWindow = undefined,
        strip: *gtk.Box = undefined,
        cols: std.ArrayList(*Col) = .empty,
        leaving: std.ArrayList(*Col) = .empty,

        cache: std.StringHashMapUnmanaged(CacheEntry) = .empty,
        inflight: std.StringHashMapUnmanaged(void) = .empty,
        memory: std.StringHashMapUnmanaged([]u8) = .empty, // F-13

        gen: u64 = 0,
        render_pending: bool = false,
        pending_pick: bool = false,
        rendered_once: bool = false,
        renders: u64 = 0,
        drilled: ?[]u8 = null,
        rightmost: ?[]u8 = null,
        md_source: bool = false, // F-35
        title: ?[:0]u8 = null,

        watchers: std.ArrayList(*jobs.Watch) = .empty,
        watch_timer: c_uint = 0,
        rename: ?*Rename = null,
        confirm: ?*Confirm = null,
        jobs_running: u32 = 0,
        uploading: bool = false,
        downloads: u32 = 0,

        tick_id: c_uint = 0,
        follow: Follow = .{},
        /// Keep the view on the follow target through layout changes.
        pinned: bool = false,
        /// Our own scroll is being applied (not the user's).
        applying: bool = false,
        pin_pending: bool = false,
        last_page: f64 = 0,
        last_upper: f64 = 0,
        reveal_frames: u8 = 0,
        restore_frames: u32 = 0,
        measure: ?*gtk.Label = null,
        name_widths: std.StringHashMapUnmanaged(c_int) = .empty,
        char_widths: std.AutoHashMapUnmanaged(u21, f32) = .empty,
        rows_idle: c_uint = 0,
        /// Duration of the last column animation started (ms), for tests.
        last_anim_ms: i64 = 0,
        /// The folder the last save dialog opened in (for tests).
        last_dialog_folder: ?[]u8 = null,
        scheme_handler: c_ulong = 0,
        drop_highlight: ?*gtk.Widget = null,

        window: ?*gtk.Window = null,
        window_handler: c_ulong = 0,
        last_dialog: ?*gio.Cancellable = null,
        last_status: ?[]u8 = null,

        pub var offset: c_int = 0;
    };

    pub const Options = struct {
        socket_path: []const u8,
        conn_name: []const u8,
        id: []const u8,
        host: ?iface.PaneHost,
        dir: []const u8 = "~",
        cursor: ?[]const u8 = null,
    };

    pub fn new(opts: Options) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.shared = try jobs.Shared.create(opts.socket_path);
        priv.shared.browser = self;
        priv.id = dupe(opts.id);
        priv.conn_name = dupe(opts.conn_name);
        priv.dir = dupe(opts.dir);
        priv.cursor = if (opts.cursor) |c| dupe(c) else null;
        self.updateTitle();
        // The container learns the title through `Pane.title` once it has
        // the pane; nothing is reported during creation.
        priv.host = opts.host;
        self.open();
        return self;
    }

    pub fn from(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    // --- accessors (factory, control) -----------------------------------

    pub fn getTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }

    pub fn dir(self: *Self) []const u8 {
        return self.private().dir;
    }

    pub fn cursor(self: *Self) ?[]const u8 {
        return self.private().cursor;
    }

    pub fn home(self: *Self) ?[]const u8 {
        return self.private().home;
    }

    pub fn columns(self: *Self) []*Col {
        return self.private().cols.items;
    }

    pub fn leavingColumns(self: *Self) []*Col {
        return self.private().leaving.items;
    }

    pub fn drilled(self: *Self) ?[]const u8 {
        return self.private().drilled;
    }

    pub fn rightmostDir(self: *Self) ?[]const u8 {
        return self.private().rightmost;
    }

    pub fn mdSource(self: *Self) bool {
        return self.private().md_source;
    }

    pub fn renameActive(self: *Self) ?*Rename {
        return self.private().rename;
    }

    pub fn confirmWidgets(self: *Self) ?struct { backdrop: *gtk.Widget, dialog: *gtk.Widget, cancel: *gtk.Widget, delete: *gtk.Widget } {
        const c = self.private().confirm orelse return null;
        return .{ .backdrop = c.backdrop.as(gtk.Widget), .dialog = c.dialog.as(gtk.Widget), .cancel = c.cancel.as(gtk.Widget), .delete = c.delete.as(gtk.Widget) };
    }

    pub fn confirmText(self: *Self) ?[]const u8 {
        const c = self.private().confirm orelse return null;
        return c.text;
    }

    pub fn watchedDirs(self: *Self, a: Allocator) ![]const []const u8 {
        const ws = self.private().watchers.items;
        const out = try a.alloc([]const u8, ws.len);
        for (ws, out) |w, *o| o.* = w.dir;
        return out;
    }

    pub fn renderCount(self: *Self) u64 {
        return self.private().renders;
    }

    pub fn scrollerWidget(self: *Self) *gtk.ScrolledWindow {
        return self.private().scroller;
    }

    pub fn dropHighlight(self: *Self) ?*gtk.Widget {
        return self.private().drop_highlight;
    }

    /// Nothing pending: no render waiting, no request, no animation.
    pub fn idle(self: *Self) bool {
        const priv = self.private();
        if (!priv.opened or priv.render_pending or priv.inflight.count() > 0 or priv.jobs_running > 0) return false;
        if (priv.watch_timer != 0 or priv.uploading) return false;
        for (priv.cols.items) |c| {
            if (c.kind == .preview and c.pv.path != null and !c.pv.loaded and !c.pv.failed) return false;
            if (c.clip.animating()) return false;
            if (c.kind == .listing and !c.rows_done and c.rows_box != null) return false;
            if (c.kind == .preview and c.pv.md_images_loaded < c.pv.md_images) return false;
        }
        return priv.leaving.items.len == 0 and !priv.follow.active and !priv.pin_pending;
    }

    /// The persisted state (F-02): `{"type":"files","dir":…,"cursor":…}`.
    pub fn saveState(self: *Self, a: Allocator) Allocator.Error![]u8 {
        const priv = self.private();
        return std.json.Stringify.valueAlloc(a, .{
            .type = "files",
            .dir = priv.dir,
            .cursor = priv.cursor,
        }, .{});
    }

    fn status(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const priv = self.private();
        const text = std.fmt.allocPrint(alloc, fmt, args) catch return;
        if (priv.last_status) |s| alloc.free(s);
        priv.last_status = text;
        iface.services.status(if (priv.conn_name.len == 0) null else priv.conn_name, text);
    }

    pub fn lastStatus(self: *Self) ?[]const u8 {
        return self.private().last_status;
    }

    fn connLog(self: *Self, level: iface.services.LogLevel, msg: []const u8, data: anytype) void {
        const text = std.json.Stringify.valueAlloc(alloc, data, .{}) catch return;
        defer alloc.free(text);
        iface.services.connLog(level, self.private().conn_name, msg, text);
    }

    // --- opening (F-03) ------------------------------------------------

    const OpenJob = struct {
        dir: []const u8,
        listing: wire.Result(wire.Listing) = .{ .err = "OutOfMemory" },
        home: ?[]const u8 = null,
        failed_first: bool = false,

        pub fn work(j: *OpenJob, shared: *jobs.Shared, a: Allocator) void {
            var client = shared.client(a) catch return;
            const h = api.list(&client, a, "~") catch return;
            if (h == .ok and !std.mem.eql(u8, h.ok.path, "/") and h.ok.path.len > 0) j.home = h.ok.path;
            if (std.mem.eql(u8, j.dir, "~")) {
                j.listing = h;
            } else {
                j.listing = api.list(&client, a, j.dir) catch return;
                if (j.listing == .err and h == .ok) {
                    j.failed_first = true;
                    j.listing = h;
                }
            }
        }

        pub fn done(j: *OpenJob, ptr: *anyopaque, _: Allocator) void {
            const self = from(ptr);
            const priv = self.private();
            priv.jobs_running -= 1;
            if (j.home) |h| priv.home = dupe(h);
            if (j.failed_first or j.listing == .err) {
                if (priv.cursor) |c| alloc.free(c);
                priv.cursor = null;
            }
            switch (j.listing) {
                .ok => |l| {
                    alloc.free(priv.dir);
                    priv.dir = dupe(if (l.path.len > 0) l.path else "/");
                    self.storeListing(priv.dir, Listing.fromResult(j.listing));
                },
                .err => |e| {
                    // The host is unreachable: show the error, retry on focus.
                    log.warn("file browser: cannot open {s}: {s}", .{ j.dir, e });
                    priv.open_failed = dupe(e);
                    priv.opened = false;
                    self.showOpenError(e);
                    return;
                },
            }
            priv.opened = true;
            self.rerender();
        }
    };

    fn open(self: *Self) void {
        const priv = self.private();
        if (priv.open_failed) |e| {
            alloc.free(e);
            priv.open_failed = null;
        }
        const task = jobs.Task(OpenJob).create(priv.shared) catch return;
        task.job = .{ .dir = task.arenaAlloc().dupe(u8, priv.dir) catch return };
        priv.jobs_running += 1;
        task.start();
    }

    fn showOpenError(self: *Self, e: []const u8) void {
        const priv = self.private();
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{e}, 0) catch "error";
        const l = gtk.Label.new(text.ptr);
        l.as(gtk.Widget).addCssClass("files-msg");
        l.setXalign(0);
        l.as(gtk.Widget).setValign(.start);
        const frame = gtk.Box.new(.vertical, 0);
        frame.append(l.as(gtk.Widget));
        frame.as(gtk.Widget).addCssClass("files-col");
        self.clearColumns();
        const col = self.newCol(.listing, "error", frame, col_min);
        priv.cols.append(alloc, col) catch {};
        priv.strip.append(col.clip.as(gtk.Widget));
    }

    // --- listings and the cache (F-12) ----------------------------------

    const ListJob = struct {
        dir: []const u8,
        result: wire.Result(wire.Listing) = .{ .err = "OutOfMemory" },

        pub fn work(j: *ListJob, shared: *jobs.Shared, a: Allocator) void {
            var client = shared.client(a) catch return;
            j.result = api.list(&client, a, j.dir) catch .{ .err = "OutOfMemory" };
        }

        pub fn done(j: *ListJob, ptr: *anyopaque, _: Allocator) void {
            const self = from(ptr);
            const priv = self.private();
            if (priv.inflight.fetchRemove(j.dir)) |kv| alloc.free(kv.key);
            self.storeListing(j.dir, Listing.fromResult(j.result));
            self.tryRender();
        }
    };

    fn storeListing(self: *Self, d: []const u8, l: *Listing) void {
        const priv = self.private();
        const gop = priv.cache.getOrPut(alloc, d) catch @panic("OOM");
        if (gop.found_existing) {
            gop.value_ptr.l.unref();
        } else {
            gop.key_ptr.* = dupe(d);
        }
        gop.value_ptr.* = .{ .t = nowMs(), .l = l };
    }

    fn dropCache(self: *Self, d: []const u8) void {
        const priv = self.private();
        if (priv.cache.fetchRemove(d)) |kv| {
            kv.value.l.unref();
            alloc.free(kv.key);
        }
    }

    fn cached(self: *Self, d: []const u8) ?*Listing {
        const e = self.private().cache.get(d) orelse return null;
        return e.l;
    }

    fn fresh(self: *Self, d: []const u8) ?*Listing {
        const e = self.private().cache.get(d) orelse return null;
        return if (nowMs() - e.t < list_ttl_ms) e.l else null;
    }

    /// The listing of `d` if fresh; otherwise starts fetching it.
    fn want(self: *Self, d: []const u8) ?*Listing {
        if (self.fresh(d)) |l| return l;
        const priv = self.private();
        if (priv.inflight.contains(d)) return null;
        const key = dupe(d);
        priv.inflight.put(alloc, key, {}) catch @panic("OOM");
        const task = jobs.Task(ListJob).create(priv.shared) catch return null;
        task.job = .{ .dir = task.arenaAlloc().dupe(u8, d) catch return null };
        task.start();
        return null;
    }

    // --- rendering (F-04) -------------------------------------------------

    pub fn rerender(self: *Self) void {
        const priv = self.private();
        priv.gen +%= 1;
        priv.render_pending = true;
        self.tryRender();
    }

    fn tryRender(self: *Self) void {
        const priv = self.private();
        const t_render = glib.getMonotonicTime();
        defer {
            const dt = glib.getMonotonicTime() - t_render;
            if (dt > 20_000) log.debug("tryRender took {d} us", .{dt});
        }
        if (!priv.opened or !priv.render_pending) return;
        const chain = paths.chain(alloc, priv.dir) catch return;
        defer alloc.free(chain);
        // Every level is asked for at once (files-widget.js: Promise.all).
        const lists = alloc.alloc(*Listing, chain.len) catch return;
        defer alloc.free(lists);
        var ready = true;
        for (chain, lists) |d, *l| {
            if (self.want(d)) |x| l.* = x else ready = false;
        }
        if (!ready) return;
        const cur = lists[lists.len - 1];

        // F-13: entering a directory picks the remembered entry or the first.
        if (priv.pending_pick) {
            priv.pending_pick = false;
            const remembered = priv.memory.get(priv.dir);
            const pick: ?[]const u8 = blk: {
                if (remembered) |r| if (cur.find(r) != null) break :blk r;
                break :blk if (cur.entries.len > 0) cur.entries[0].name else null;
            };
            self.setCursor(pick);
        }
        const ci: ?usize = if (priv.cursor) |c| cur.find(c) else null;
        if (ci == null) self.setCursor(null) else self.remember(priv.dir, priv.cursor.?);
        const centry: ?Listing.Entry = if (ci) |i| cur.entries[i] else null;

        var sub_path: ?[]u8 = null;
        defer if (sub_path) |s| alloc.free(s);
        var preview_path: ?[]u8 = null;
        defer if (preview_path) |p| alloc.free(p);
        if (centry) |e| {
            const full = paths.join(alloc, priv.dir, e.name) catch return;
            if (e.dir) sub_path = full else preview_path = full;
        }
        if (priv.drilled) |d| {
            if (preview_path == null or !std.mem.eql(u8, d, preview_path.?)) self.setDrilled(null);
        }
        var sub: ?*Listing = null;
        if (sub_path) |s| {
            sub = self.want(s) orelse return;
        }
        priv.render_pending = false;

        if (priv.rightmost) |r| alloc.free(r);
        priv.rightmost = dupe(sub_path orelse priv.dir);

        var specs: std.ArrayList(Spec) = .empty;
        defer specs.deinit(alloc);
        for (chain, 0..) |d, i| {
            const last = i == chain.len - 1;
            specs.append(alloc, .{
                .kind = .listing,
                .key = d,
                .listing = lists[i],
                .hl = if (last) priv.cursor else paths.base(chain[i + 1]),
                .cursor_col = last,
            }) catch return;
        }
        if (sub) |l| {
            specs.append(alloc, .{ .kind = .listing, .key = sub_path.?, .listing = l, .hl = null, .cursor_col = false }) catch return;
        } else if (preview_path) |p| {
            specs.append(alloc, .{ .kind = .preview, .key = "preview", .preview = p }) catch return;
        }

        const t_patch = glib.getMonotonicTime();
        const animate = self.patch(specs.items);
        log.debug("render: patch {d} us", .{glib.getMonotonicTime() - t_patch});
        priv.renders += 1;
        self.updateTitle();
        if (priv.host) |h| h.stateChanged(priv.id);
        self.syncWatchers();
        if (animate) self.smoothScrollRight() else self.jumpRight();
        priv.reveal_frames = 60;
        self.ensureTick();
    }

    const Spec = struct {
        kind: Col.Kind,
        key: []const u8,
        listing: ?*Listing = null,
        hl: ?[]const u8 = null,
        cursor_col: bool = false,
        preview: ?[]const u8 = null,
    };

    fn setCursor(self: *Self, name: ?[]const u8) void {
        const priv = self.private();
        if (priv.cursor) |c| {
            if (name != null and std.mem.eql(u8, c, name.?)) return;
            alloc.free(c);
        }
        priv.cursor = if (name) |n| dupe(n) else null;
    }

    fn setDir(self: *Self, d: []const u8) void {
        const priv = self.private();
        const copy = dupe(d);
        alloc.free(priv.dir);
        priv.dir = copy;
    }

    fn remember(self: *Self, d: []const u8, name: []const u8) void {
        const priv = self.private();
        const gop = priv.memory.getOrPut(alloc, d) catch return;
        if (gop.found_existing) {
            if (std.mem.eql(u8, gop.value_ptr.*, name)) return;
            alloc.free(gop.value_ptr.*);
        } else gop.key_ptr.* = dupe(d);
        gop.value_ptr.* = dupe(name);
    }

    // --- the column strip (F-62) -------------------------------------------

    fn newCol(self: *Self, kind: Col.Kind, key: []const u8, frame: *gtk.Box, width: f64) *Col {
        const col = alloc.create(Col) catch @panic("OOM");
        col.* = .{
            .kind = kind,
            .key = dupe(key),
            .clip = Clip.new(frame.as(gtk.Widget), width),
            .frame = frame,
            .browser = self,
        };
        col.clip.as(gtk.Widget).setVexpand(1);
        self.addDropTarget(frame.as(gtk.Widget), .{ .col = col });
        return col;
    }

    fn clearColumns(self: *Self) void {
        const priv = self.private();
        for (priv.cols.items) |c| self.removeCol(c);
        priv.cols.clearRetainingCapacity();
        for (priv.leaving.items) |c| self.removeCol(c);
        priv.leaving.clearRetainingCapacity();
    }

    fn removeCol(self: *Self, c: *Col) void {
        if (self.private().drop_highlight == c.frame.as(gtk.Widget)) self.private().drop_highlight = null;
        self.private().strip.remove(c.clip.as(gtk.Widget));
        c.destroy();
    }

    /// Swap the visible columns for `specs` (files-widget.js patchCols).
    /// Returns whether this was animated (false on the first render).
    fn patch(self: *Self, specs: []const Spec) bool {
        const priv = self.private();
        const animate = priv.cols.items.len > 0 and priv.rendered_once;
        priv.rendered_once = true;
        var old = priv.cols;
        priv.cols = .empty;
        var used = alloc.alloc(bool, old.items.len) catch @panic("OOM");
        defer alloc.free(used);
        @memset(used, false);

        var anchor: ?*gtk.Widget = null;
        for (specs) |spec| {
            var found: ?*Col = null;
            for (old.items, 0..) |c, i| {
                if (!used[i] and c.kind == spec.kind and std.mem.eql(u8, c.key, spec.key)) {
                    used[i] = true;
                    found = c;
                    break;
                }
            }
            const col = if (found) |c| c else blk: {
                // A column dying in this exact slot (cursor moved to a
                // sibling folder): swap in place with a fade (F-62).
                const next = if (anchor) |a| a.getNextSibling() else priv.strip.as(gtk.Widget).getFirstChild();
                var swap: ?*Col = null;
                if (animate and spec.kind == .listing) {
                    if (next) |n| for (old.items, 0..) |c, i| {
                        if (!used[i] and c.clip.as(gtk.Widget) == n and c.kind == .listing) {
                            used[i] = true;
                            swap = c;
                            break;
                        }
                    };
                }
                const c = self.buildCol(spec);
                priv.strip.insertChildAfter(c.clip.as(gtk.Widget), anchor);
                if (swap) |s| {
                    self.removeCol(s);
                    c.clip.fadeIn(c.clip.targetWidth(), motionMs(swap_ms));
                    priv.last_anim_ms = motionMs(swap_ms);
                } else if (animate) {
                    c.clip.enter(c.clip.targetWidth(), motionMs(enter_ms));
                    priv.last_anim_ms = motionMs(enter_ms);
                }
                break :blk c;
            };
            if (found != null) {
                self.updateCol(col, spec);
                priv.strip.reorderChildAfter(col.clip.as(gtk.Widget), anchor);
            }
            priv.cols.append(alloc, col) catch @panic("OOM");
            anchor = col.clip.as(gtk.Widget);
        }
        for (old.items, 0..) |c, i| {
            if (used[i]) continue;
            if (animate) {
                c.leaving = true;
                c.clip.leave(motionMs(enter_ms));
                priv.last_anim_ms = motionMs(enter_ms);
                priv.leaving.append(alloc, c) catch @panic("OOM");
            } else self.removeCol(c);
        }
        old.deinit(alloc);
        self.ensureTick();
        return animate;
    }

    fn buildCol(self: *Self, spec: Spec) *Col {
        const frame = gtk.Box.new(.vertical, 0);
        frame.as(gtk.Widget).addCssClass("files-col");
        switch (spec.kind) {
            .listing => {
                const col = self.newCol(.listing, spec.key, frame, col_min);
                self.updateCol(col, spec);
                return col;
            },
            .preview => {
                frame.as(gtk.Widget).addCssClass("files-preview");
                // A live preview column is reused (fixed key), so a new one
                // starts wide; it settles once the stat arrives (F-30).
                const col = self.newCol(.preview, spec.key, frame, preview_wide);
                const gc = gtk.GestureClick.new();
                _ = gtk.GestureClick.signals.released.connect(gc, *Col, onPreviewClick, col, .{});
                frame.as(gtk.Widget).addController(gc.as(gtk.EventController));
                self.updateCol(col, spec);
                return col;
            },
        }
    }

    fn updateCol(self: *Self, col: *Col, spec: Spec) void {
        switch (col.kind) {
            .listing => {
                const l = spec.listing.?;
                if (col.listing != l) {
                    if (col.listing != null and sameListing(col.listing.?, l)) {
                        // Re-fetched, unchanged (the cache expired, a focus
                        // refresh): keep the rows, adopt the new listing.
                        if (l.width == null) l.width = col.listing.?.width;
                        col.listing.?.unref();
                        col.listing = l.ref();
                    } else self.fillListing(col, l);
                }
                self.setHighlight(col, spec.hl, spec.cursor_col);
            },
            .preview => self.showPreview(col, spec.preview.?),
        }
    }

    // --- listing columns (F-05, F-06, F-08, F-09, F-10) ---------------------

    fn sameListing(a: *const Listing, b: *const Listing) bool {
        if (a.truncated != b.truncated or a.entries.len != b.entries.len) return false;
        if ((a.err == null) != (b.err == null)) return false;
        if (a.err) |e| if (!std.mem.eql(u8, e, b.err.?)) return false;
        for (a.entries, b.entries) |x, y| {
            if (x.dir != y.dir or x.symlink != y.symlink or !std.mem.eql(u8, x.name, y.name)) return false;
        }
        return true;
    }

    fn columnWidth(self: *Self, l: *Listing) f64 {
        if (l.width) |w| return w;
        if (l.entries.len == 0) {
            l.width = col_min;
            return col_min;
        }
        // Measured with a label in the rows' font (`.files-measure`):
        // calling Pango directly would add a library the build does not
        // put on the executable's run path. One text layout per name cost
        // ~35 µs each, 70 ms for a 2000-name directory, even in a release
        // build (it is GTK's work). So every name is first estimated from
        // the widths of its characters (each distinct character measured
        // once per pane), and only the names that could be the widest are
        // measured exactly (remembered per name for the pane's life).
        const priv = self.private();
        const m = self.measureLabel();
        const Est = struct { i: usize, w: f32 };
        var est = alloc.alloc(Est, l.entries.len) catch @panic("OOM");
        defer alloc.free(est);
        var max_est: f32 = 0;
        for (l.entries, 0..) |e, ei| {
            var w: f32 = 0;
            var it = (std.unicode.Utf8View.init(e.name) catch std.unicode.Utf8View.initUnchecked("")).iterator();
            while (it.nextCodepointSlice()) |cs| {
                const cp = std.unicode.utf8Decode(cs) catch 0xFFFD;
                const gop = priv.char_widths.getOrPut(alloc, cp) catch continue;
                if (!gop.found_existing) {
                    var buf: [5]u8 = undefined;
                    @memcpy(buf[0..cs.len], cs);
                    buf[cs.len] = 0;
                    m.setText(@ptrCast(&buf));
                    var nat: c_int = 0;
                    m.as(gtk.Widget).measure(.horizontal, -1, null, &nat, null, null);
                    gop.value_ptr.* = @floatFromInt(nat);
                }
                w += gop.value_ptr.*;
            }
            est[ei] = .{ .i = ei, .w = w };
            max_est = @max(max_est, w);
        }
        std.mem.sort(Est, est, {}, struct {
            fn gt(_: void, a: Est, b: Est) bool {
                return a.w > b.w;
            }
        }.gt);
        var maxw: c_int = 0;
        const cap: c_int = col_max - col_chrome;
        for (est, 0..) |e, k| {
            // Kerning and shaping move a name's width by a few percent of
            // its estimate: beyond 15 % below the widest estimate (and
            // below the widest exact width found) nothing can be wider.
            // At most 32 exact measurements: in a folder of similar names
            // (file-0001 … file-2000) all estimates tie, and the exact
            // widths of tied names differ by kerning only.
            if (k >= 32 or (k >= 8 and (e.w < max_est * 0.85 or e.w * 1.15 < @as(f32, @floatFromInt(maxw))))) break;
            if (maxw >= cap) break;
            const name = l.entries[e.i].name;
            const gop = priv.name_widths.getOrPut(alloc, name) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = dupe(name);
                m.setText(name.ptr);
                var nat: c_int = 0;
                m.as(gtk.Widget).measure(.horizontal, -1, null, &nat, null, null);
                gop.value_ptr.* = nat;
            }
            maxw = @max(maxw, gop.value_ptr.*);
        }
        const w: f64 = @round(@max(@as(f64, col_min), @min(@as(f64, col_max), @as(f64, @floatFromInt(maxw)) + col_chrome)));
        l.width = w;
        return w;
    }

    /// Scroll over the child's natural size, not its minimum (the
    /// viewport's default), so wide content scrolls instead of squeezing.
    pub fn naturalScroll(sw: *gtk.ScrolledWindow) void {
        const child = sw.getChild() orelse return;
        const sc = gobject.ext.cast(gtk.Scrollable, child) orelse return;
        var hp: gtk.PolicyType = .automatic;
        var vp: gtk.PolicyType = .automatic;
        sw.getPolicy(&hp, &vp);
        // A direction that never scrolls must fit the child to the view.
        sc.setHscrollPolicy(if (hp == .never) .minimum else .natural);
        sc.setVscrollPolicy(if (vp == .never) .minimum else .natural);
    }

    fn measureLabel(self: *Self) *gtk.Label {
        const priv = self.private();
        if (priv.measure) |m| return m;
        const m = gtk.Label.new(null);
        _ = m.as(gobject.Object).refSink();
        m.as(gtk.Widget).addCssClass("files-measure");
        m.setSingleLineMode(1);
        priv.measure = m;
        return m;
    }

    fn fillListing(self: *Self, col: *Col, l: *Listing) void {
        // Keep the reader's place when a column is re-listed (F-62).
        if (col.scroller) |sw| {
            const v = sw.getVadjustment().getValue();
            if (v > 0) col.restore_scroll = v;
        }
        if (self.private().rename) |r| {
            // The row holding the rename entry may go away.
            for (col.rows.items) |row| {
                if (row == r.row) self.abortRename();
            }
        }
        const old = col.listing;
        defer if (old) |o| o.unref();
        col.listing = l.ref();

        const t_w = glib.getMonotonicTime();
        col.clip.setWidth(self.columnWidth(l));
        const t_rows = glib.getMonotonicTime();
        defer log.debug("fillListing {s}: {d} entries, width {d} us, rows {d} us", .{ col.key, l.entries.len, t_rows - t_w, glib.getMonotonicTime() - t_rows });

        // A changed listing of a column that already shows rows: keep the
        // row of every entry that is still there (building and styling
        // thousands of rows again is what stalled the main loop).
        if (old != null and col.rows_box != null and old.?.err == null and l.err == null and l.entries.len > 0 and col.rows.items.len == old.?.entries.len) {
            self.patchRows(col, old.?, l);
            return;
        }

        col.rows.clearRetainingCapacity();
        col.hl = null;
        col.acts = null;
        var child = col.frame.as(gtk.Widget).getFirstChild();
        while (child) |c| {
            child = c.getNextSibling();
            col.frame.remove(c);
        }
        if (l.err) |e| {
            col.frame.append(msgLabel(e));
            col.scroller = null;
            col.rows_box = null;
            return;
        }
        if (l.entries.len == 0) {
            col.frame.append(msgLabel("(empty)"));
            col.scroller = null;
            col.rows_box = null;
            return;
        }
        const sw = gtk.ScrolledWindow.new();
        scrolling.install(sw, false);
        sw.setPolicy(.never, .automatic);
        sw.setOverlayScrolling(0);
        sw.as(gtk.Widget).setVexpand(1);
        const box = gtk.Box.new(.vertical, 0);
        box.as(gtk.Widget).addCssClass("files-rows");
        sw.setChild(box.as(gtk.Widget));
        scrolling.noScrollToFocus(sw);
        col.rows_box = box;
        // The first screenful now, the rest in idle time (D8: creating and
        // styling 2000 rows at once blocked the main loop ~100–200 ms even
        // in a release build). setHighlight builds through the cursor.
        col.rows_done = false;
        self.ensureRows(col, first_rows);
        if (!col.rows_done) self.scheduleRows();
        col.frame.append(sw.as(gtk.Widget));
        col.scroller = sw;

        const gc = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.released.connect(gc, *Col, onRowClick, col, .{});
        box.as(gtk.Widget).addController(gc.as(gtk.EventController));
        if (col.restore_scroll != null) self.ensureTick();
    }

    /// Bring the rows of `col` from listing `old` to `new` in place.
    fn patchRows(self: *Self, col: *Col, old: *const Listing, fresh_l: *const Listing) void {
        _ = self;
        const box = col.rows_box.?;
        // Drop the highlight and the row buttons; setHighlight redoes them.
        if (col.hl) |h| if (h < col.rows.items.len) {
            const w = col.rows.items[h].as(gtk.Widget);
            w.removeCssClass("cursor");
            w.removeCssClass("on-path");
        };
        if (col.acts) |a| {
            if (a.as(gtk.Widget).getParent()) |p| {
                if (gobject.ext.cast(gtk.Box, p)) |pb| pb.remove(a.as(gtk.Widget));
            }
        }
        col.hl = null;
        col.acts = null;

        const Key = struct { name: []const u8, dir: bool, symlink: bool };
        const Ctx = struct {
            pub fn hash(_: @This(), k: Key) u64 {
                var h = std.hash.Wyhash.init(@intFromBool(k.dir) | (@as(u64, @intFromBool(k.symlink)) << 1));
                h.update(k.name);
                return h.final();
            }
            pub fn eql(_: @This(), a: Key, b: Key) bool {
                return a.dir == b.dir and a.symlink == b.symlink and std.mem.eql(u8, a.name, b.name);
            }
        };
        var by_name: std.HashMapUnmanaged(Key, *gtk.Box, Ctx, 80) = .empty;
        defer by_name.deinit(alloc);
        by_name.ensureTotalCapacity(alloc, @intCast(old.entries.len)) catch @panic("OOM");
        for (old.entries, col.rows.items) |e, row| {
            by_name.putAssumeCapacity(.{ .name = e.name, .dir = e.dir, .symlink = e.symlink }, row);
        }
        // Messages ("(list truncated)") go; they are re-added at the end.
        var child = box.as(gtk.Widget).getFirstChild();
        while (child) |c| {
            child = c.getNextSibling();
            if (gobject.ext.cast(gtk.Label, c) != null) box.remove(c);
        }
        var rows: std.ArrayList(*gtk.Box) = .empty;
        rows.ensureTotalCapacity(alloc, fresh_l.entries.len) catch @panic("OOM");
        var prev: ?*gtk.Widget = null;
        for (fresh_l.entries) |e| {
            const row = if (by_name.fetchRemove(.{ .name = e.name, .dir = e.dir, .symlink = e.symlink })) |kv| kv.value else makeRow(e);
            const w = row.as(gtk.Widget);
            if (w.getParent() == null) {
                box.insertChildAfter(w, prev);
            } else if (w.getPrevSibling() != prev) {
                box.reorderChildAfter(w, prev);
            }
            rows.appendAssumeCapacity(row);
            prev = w;
        }
        var leftover = by_name.valueIterator();
        while (leftover.next()) |row| box.remove(row.*.as(gtk.Widget));
        if (fresh_l.truncated) box.append(msgLabel("(list truncated)"));
        col.rows.deinit(alloc);
        col.rows = rows;
        col.rows_done = true;
    }

    const first_rows = 80;
    const rows_per_idle = 100;

    /// Make sure rows exist for entries [0, upto) of the column's listing.
    fn ensureRows(self: *Self, col: *Col, upto: usize) void {
        _ = self;
        const l = col.listing orelse return;
        const box = col.rows_box orelse return;
        if (col.rows_done) return;
        const end = @min(upto, l.entries.len);
        while (col.rows.items.len < end) {
            const row = makeRow(l.entries[col.rows.items.len]);
            box.append(row.as(gtk.Widget));
            col.rows.append(alloc, row) catch @panic("OOM");
        }
        if (col.rows.items.len == l.entries.len) {
            col.rows_done = true;
            if (l.truncated) box.append(msgLabel("(list truncated)"));
        }
    }

    fn scheduleRows(self: *Self) void {
        const priv = self.private();
        if (priv.rows_idle != 0) return;
        priv.rows_idle = glib.idleAdd(rowsIdle, self);
    }

    fn rowsIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const priv = self.private();
        var budget: usize = rows_per_idle;
        for (priv.cols.items) |c| {
            if (c.kind != .listing or c.rows_done or budget == 0) continue;
            const before = c.rows.items.len;
            self.ensureRows(c, before + budget);
            budget -|= c.rows.items.len - before;
        }
        for (priv.cols.items) |c| {
            if (c.kind == .listing and !c.rows_done and c.rows_box != null) return 1;
        }
        priv.rows_idle = 0;
        return 0;
    }

    fn makeRow(e: Listing.Entry) *gtk.Box {
        const row = gtk.Box.new(.horizontal, 0);
        row.as(gtk.Widget).addCssClass("files-entry");
        if (e.name.len > 0 and e.name[0] == '.') row.as(gtk.Widget).addCssClass("hidden-file");
        const name = gtk.Label.new(e.name.ptr);
        name.setXalign(0);
        name.setEllipsize(.end);
        name.setSingleLineMode(1);
        name.as(gtk.Widget).setHexpand(1);
        name.as(gtk.Widget).addCssClass("files-name");
        if (e.symlink) name.as(gtk.Widget).addCssClass("symlink");
        row.append(name.as(gtk.Widget));
        if (e.dir) {
            const arrow = gtk.Label.new("›");
            arrow.as(gtk.Widget).addCssClass("files-arrow");
            row.append(arrow.as(gtk.Widget));
        }
        return row;
    }

    fn setHighlight(self: *Self, col: *Col, name: ?[]const u8, cursor_col: bool) void {
        const l = col.listing orelse return;
        const idx: ?usize = if (name) |n| l.find(n) else null;
        if (idx) |i| if (i >= col.rows.items.len) self.ensureRows(col, i + first_rows);
        if (col.hl == idx and col.cursor_col == cursor_col and (col.acts != null) == (cursor_col and idx != null)) return;
        if (col.hl) |old| if (old < col.rows.items.len) {
            const w = col.rows.items[old].as(gtk.Widget);
            w.removeCssClass("cursor");
            w.removeCssClass("on-path");
        };
        if (col.acts) |a| {
            if (a.as(gtk.Widget).getParent()) |p| {
                if (gobject.ext.cast(gtk.Box, p)) |pb| pb.remove(a.as(gtk.Widget));
            }
            col.acts = null;
        }
        col.hl = idx;
        col.cursor_col = cursor_col;
        const i = idx orelse return;
        if (i >= col.rows.items.len) return;
        const row = col.rows.items[i];
        row.as(gtk.Widget).addCssClass(if (cursor_col) "cursor" else "on-path");
        if (cursor_col) {
            // F-10: the selected row's ✎ / ✕ buttons.
            const acts = gtk.Box.new(.horizontal, 0);
            acts.as(gtk.Widget).addCssClass("files-acts");
            acts.append(self.actButton("✎", "Rename (r)", .rename).as(gtk.Widget));
            acts.append(self.actButton("✕", "Delete (d)", .delete).as(gtk.Widget));
            const name_w = row.as(gtk.Widget).getFirstChild();
            row.insertChildAfter(acts.as(gtk.Widget), name_w);
            col.acts = acts;
        }
    }

    const Act = enum { rename, delete };

    fn actButton(self: *Self, text: [:0]const u8, tip: [:0]const u8, act: Act) *gtk.Button {
        const b = gtk.Button.newWithLabel(text.ptr);
        b.as(gtk.Widget).addCssClass("files-act");
        b.as(gtk.Widget).setTooltipText(tip.ptr);
        b.as(gtk.Widget).setFocusable(0);
        b.as(gtk.Widget).setFocusOnClick(0);
        b.as(gtk.Widget).setValign(.center);
        switch (act) {
            .rename => _ = gtk.Button.signals.clicked.connect(b, *Self, onRenameClicked, self, .{}),
            .delete => _ = gtk.Button.signals.clicked.connect(b, *Self, onDeleteClicked, self, .{}),
        }
        return b;
    }

    fn onRenameClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.startRename();
    }

    fn onDeleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.deleteCursor();
    }

    fn msgLabel(text: []const u8) *gtk.Widget {
        const z = dupeZ(text);
        defer alloc.free(z);
        const l = gtk.Label.new(null);
        md_view.setPlainText(l, z.ptr);
        l.as(gtk.Widget).addCssClass("files-msg");
        l.setXalign(0);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.as(gtk.Widget).setValign(.start);
        return l.as(gtk.Widget);
    }

    /// F-11: a click on a row moves the cursor there.
    fn onRowClick(gc: *gtk.GestureClick, _: c_int, x: f64, y: f64, col: *Col) callconv(.c) void {
        const box = col.rows_box orelse return;
        const picked = box.as(gtk.Widget).pick(x, y, .{}) orelse return;
        if (isInside(picked, gtk.Button) or isInside(picked, gtk.Entry) or isInside(picked, gtk.Text)) return;
        _ = gc;
        for (col.rows.items, 0..) |row, i| {
            const rw = row.as(gtk.Widget);
            if (picked == rw or picked.isAncestor(rw) != 0) {
                col.browser.clickRow(col, i);
                return;
            }
        }
    }

    fn isInside(w: *gtk.Widget, comptime T: type) bool {
        var cur: ?*gtk.Widget = w;
        while (cur) |c| : (cur = c.getParent()) {
            if (gobject.ext.cast(T, c) != null) return true;
            if (gobject.ext.cast(Browser, c) != null) return false;
        }
        return false;
    }

    /// Row click (also the control socket's entry point).
    pub fn clickRow(self: *Self, col: *Col, index: usize) void {
        const l = col.listing orelse return;
        if (index >= l.entries.len or col.leaving) return;
        if (self.private().confirm != null) return;
        self.abortRename();
        self.setDir(col.key);
        self.setCursor(l.entries[index].name);
        self.setDrilled(null);
        self.rerender();
        _ = self.as(gtk.Widget).grabFocus(); // F-11
    }

    // --- previews (F-30…F-42) ----------------------------------------------

    const PreviewJob = struct {
        path: []const u8,
        gen: u64,
        result: wire.Result(wire.Preview) = .{ .err = "preview failed" },
        transport_failed: bool = false,

        pub fn work(j: *PreviewJob, shared: *jobs.Shared, a: Allocator) void {
            var client = shared.client(a) catch return;
            j.result = api.preview(&client, a, j.path) catch .{ .err = "OutOfMemory" };
        }

        pub fn done(j: *PreviewJob, ptr: *anyopaque, a: Allocator) void {
            _ = a;
            from(ptr).onPreview(j);
        }
    };

    fn previewCol(self: *Self) ?*Col {
        for (self.private().cols.items) |c| {
            if (c.kind == .preview) return c;
        }
        return null;
    }

    fn showPreview(self: *Self, col: *Col, path: []const u8) void {
        const priv = self.private();
        const same = if (col.pv.path) |p| std.mem.eql(u8, p, path) else false;
        if (!same) {
            if (col.pv.path) |p| alloc.free(p);
            col.pv.path = dupe(path);
            col.pv.loaded = false;
            col.clearPreviewData();
            col.pv.restore_scroll = null;
            col.pv.restore_rebuilt = false;
            self.setPreviewContent(col, msgLabel("…"), false);
        } else if (col.pv.body) |body| {
            // F-42: a re-render of the same file keeps its scroll position
            // (a restore still pending from a rebuild a moment ago wins
            // over the freshly built body's 0).
            if (!col.pv.restore_rebuilt) {
                const v = body.getVadjustment().getValue();
                col.pv.restore_scroll = if (v > 0) v else null;
                log.debug("pv-scroll: save {d}", .{v});
            }
        }
        const task = jobs.Task(PreviewJob).create(priv.shared) catch return;
        task.job = .{ .path = task.arenaAlloc().dupe(u8, path) catch return, .gen = priv.gen };
        priv.jobs_running += 1;
        task.start();
    }

    fn onPreview(self: *Self, j: *PreviewJob) void {
        const priv = self.private();
        priv.jobs_running -= 1;
        if (j.gen != priv.gen) return; // superseded by a newer render
        const col = self.previewCol() orelse return;
        const path = col.pv.path orelse return;
        if (!std.mem.eql(u8, path, j.path)) return;
        // The same file, unchanged: keep what is on screen as it is (its
        // scroll position, images, markdown) instead of rebuilding it.
        if (col.pv.loaded and col.pv.content != null and col.pv.err == null and j.result == .ok and col.pv.info != null and
            samePreview(col.pv.info.?, j.result.ok))
        {
            // A restore still pending from a rebuild a moment ago stays
            // pending; with none, the body was never touched.
            if (!col.pv.restore_rebuilt) col.pv.restore_scroll = null;
            log.debug("pv-scroll: unchanged, pending {?d}", .{col.pv.restore_scroll});
            return;
        }
        col.clearPreviewData();
        col.pv.loaded = true;
        var narrow = true;
        switch (j.result) {
            .err => |e| {
                col.pv.err = dupe(e);
                // A host error (an errno code such as ENOENT, or its
                // message) shows as it is; a failed fetch (a transport
                // error, CamelCase Zig error names) as "preview failed".
                col.pv.failed = !isHostError(e);
            },
            .ok => |info| {
                var arena: std.heap.ArenaAllocator = .init(alloc);
                col.pv.info = deepCopyPreview(arena.allocator(), info) catch null;
                col.pv.arena = arena;
                narrow = switch (info.kind) {
                    .image, .text, .zip => false,
                    else => true,
                };
            },
        }
        const resized = narrow != col.pv.narrow;
        col.pv.narrow = narrow;
        if (resized) col.clip.animateWidth(if (narrow) preview_narrow else preview_wide, motionMs(enter_ms));
        self.buildPreview(col);
        if (narrow) {
            if (priv.drilled) |d| if (std.mem.eql(u8, d, path)) self.setDrilled(null);
        }
        if (resized) self.smoothScrollRight();
        self.ensureTick();
    }

    fn samePreview(a: wire.Preview, b: wire.Preview) bool {
        if (a.kind != b.kind or a.size != b.size or a.mtime != b.mtime or a.truncated != b.truncated or a.count != b.count) return false;
        if (!std.mem.eql(u8, a.content, b.content) or a.entries.len != b.entries.len) return false;
        for (a.entries, b.entries) |x, y| {
            if (x.size != y.size or x.dir != y.dir or !std.mem.eql(u8, x.name, y.name)) return false;
        }
        return true;
    }

    fn isHostError(e: []const u8) bool {
        if (std.mem.eql(u8, e, "preview failed")) return false;
        if (std.mem.indexOfScalar(u8, e, ' ') != null) return true;
        for (e) |c| {
            if (std.ascii.isLower(c)) return false;
        }
        return true;
    }

    fn deepCopyPreview(a: Allocator, p: wire.Preview) !wire.Preview {
        var out = p;
        out.content = try a.dupe(u8, p.content);
        const entries = try a.alloc(zip.Entry, p.entries.len);
        for (p.entries, entries) |e, *d| d.* = .{ .name = try a.dupe(u8, e.name), .size = e.size, .dir = e.dir };
        out.entries = entries;
        return out;
    }

    fn setPreviewContent(self: *Self, col: *Col, w: *gtk.Widget, fade: bool) void {
        _ = self;
        if (col.pv.content) |old| col.frame.remove(old);
        col.pv.content = w;
        col.pv.body = null;
        col.pv.toggle = .{ null, null };
        col.pv.download = null;
        w.setVexpand(1);
        col.frame.append(w);
        col.pv.load +%= 1;
        if (fade) {
            // F-62: preview content fades in over 140 ms.
            w.setOpacity(0);
            fadeWidget(w, motionMs(swap_ms));
        }
    }

    fn buildPreview(self: *Self, col: *Col) void {
        const path = col.pv.path.?;
        if (col.pv.err) |e| {
            self.setPreviewContent(col, msgLabel(if (col.pv.failed) "preview failed" else e), true);
            return;
        }
        const info = col.pv.info orelse {
            self.setPreviewContent(col, msgLabel("preview failed"), true);
            return;
        };
        const wrap = gtk.Box.new(.vertical, 0);
        wrap.as(gtk.Widget).addCssClass("files-preview-inner");

        // F-31: header.
        const head = gtk.Box.new(.horizontal, 0);
        head.as(gtk.Widget).addCssClass("files-preview-head");
        const ftext = gtk.Box.new(.vertical, 0);
        ftext.as(gtk.Widget).setHexpand(1);
        const name_z = dupeZ(paths.base(path));
        defer alloc.free(name_z);
        const fname = gtk.Label.new(null);
        md_view.setPlainText(fname, name_z.ptr);
        fname.as(gtk.Widget).addCssClass("fname");
        fname.setXalign(0);
        fname.setWrap(1);
        fname.setWrapMode(.char);
        ftext.append(fname.as(gtk.Widget));
        const meta = metaLine(info);
        defer alloc.free(meta);
        const fmeta = gtk.Label.new(null);
        md_view.setPlainText(fmeta, meta.ptr);
        fmeta.as(gtk.Widget).addCssClass("fmeta");
        fmeta.setXalign(0);
        fmeta.setWrap(1);
        ftext.append(fmeta.as(gtk.Widget));
        head.append(ftext.as(gtk.Widget));

        const is_md = info.kind == .text and paths.isMarkdownName(path);
        if (is_md) {
            // F-35: Rendered / Source toggle.
            const tg = gtk.Box.new(.horizontal, 0);
            tg.as(gtk.Widget).addCssClass("files-view-toggle");
            tg.as(gtk.Widget).setValign(.start);
            const r = gtk.ToggleButton.newWithLabel("Rendered");
            const s = gtk.ToggleButton.newWithLabel("Source");
            s.setGroup(r);
            for ([_]*gtk.ToggleButton{ r, s }) |b| {
                b.as(gtk.Widget).setFocusable(0);
                b.as(gtk.Widget).setFocusOnClick(0);
                tg.append(b.as(gtk.Widget));
            }
            const src = self.private().md_source;
            r.setActive(@intFromBool(!src));
            s.setActive(@intFromBool(src));
            _ = gtk.ToggleButton.signals.toggled.connect(s, *Col, onSourceToggled, col, .{});
            head.append(tg.as(gtk.Widget));
            col.pv.toggle = .{ r, s };
        }
        if (info.kind != .other) {
            // F-32: ⤓ download.
            const dl = gtk.Button.newWithLabel("⤓");
            dl.as(gtk.Widget).addCssClass("files-act");
            dl.as(gtk.Widget).addCssClass("files-download");
            dl.as(gtk.Widget).setTooltipText("Download (D)");
            dl.as(gtk.Widget).setFocusable(0);
            dl.as(gtk.Widget).setFocusOnClick(0);
            dl.as(gtk.Widget).setValign(.start);
            _ = gtk.Button.signals.clicked.connect(dl, *Col, onDownloadClicked, col, .{});
            head.append(dl.as(gtk.Widget));
            col.pv.download = dl;
        }
        wrap.append(head.as(gtk.Widget));

        const body = gtk.ScrolledWindow.new();

        scrolling.install(body, false);
        body.as(gtk.Widget).addCssClass("files-preview-body");
        body.as(gtk.Widget).setVexpand(1);
        wrap.append(body.as(gtk.Widget));

        // Content is built after `setPreviewContent` resets the per-content
        // fields (toggle, body), so keep them.
        const keep_toggle = col.pv.toggle;
        const keep_download = col.pv.download;
        self.setPreviewContent(col, wrap.as(gtk.Widget), true);
        col.pv.toggle = keep_toggle;
        col.pv.download = keep_download;
        col.pv.body = body;
        self.fillPreviewBody(col);
        col.pv.restore_rebuilt = col.pv.restore_scroll != null;
        log.debug("pv-scroll: rebuilt, pending {?d}", .{col.pv.restore_scroll});
        if (col.pv.restore_scroll != null) self.ensureTick();
    }

    fn metaLine(info: wire.Preview) [:0]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        const w = &aw.writer;
        var sbuf: [32]u8 = undefined;
        w.writeAll(paths.formatSize(&sbuf, info.size)) catch {};
        if (info.kind == .zip) {
            const n: u64 = if (std.math.isFinite(info.count) and info.count > 0) @intFromFloat(@min(info.count, 9e15)) else 0;
            w.print(" · {d} {s}", .{ n, if (n == 1) "entry" else "entries" }) catch {};
        }
        w.writeAll(" · ") catch {};
        localTime(w, info.mtime) catch {};
        return alloc.dupeSentinel(u8, aw.written(), 0) catch @panic("OOM");
    }

    /// `toLocaleString()` of the mtime, in the local time zone (en-US style
    /// as Chromium formats it by default: 1/2/2026, 3:04:05 PM).
    fn localTime(w: *std.Io.Writer, mtime_ms: f64) !void {
        if (!std.math.isFinite(mtime_ms) or @abs(mtime_ms) > 8.64e15) return w.writeAll("?");
        const secs: i64 = @intFromFloat(@floor(mtime_ms / 1000));
        const dt = glib.DateTime.newFromUnixLocal(secs) orelse return w.writeAll("?");
        defer dt.unref();
        var hour = dt.getHour();
        const pm = hour >= 12;
        hour = @mod(hour, 12);
        if (hour == 0) hour = 12;
        try w.print("{d}/{d}/{d}, {d}:{d:0>2}:{d:0>2} {s}", .{
            dt.getMonth(), dt.getDayOfMonth(), dt.getYear(), hour, @as(u32, @intCast(dt.getMinute())), @as(u32, @intCast(dt.getSecond())), if (pm) "PM" else "AM",
        });
    }

    fn fillPreviewBody(self: *Self, col: *Col) void {
        const body = col.pv.body orelse return;
        const info = col.pv.info orelse return;
        const path = col.pv.path.?;
        const inner = gtk.Box.new(.vertical, 0);
        inner.as(gtk.Widget).addCssClass("files-body-inner");
        body.setPolicy(.automatic, .automatic);
        // Wrapping content (markdown, zip trees) is laid out at the body's
        // width and scrolls sideways only when its minimum is wider (deep
        // nesting, wide tables), so the header never moves.
        var fit_width = false;
        col.pv.load +%= 1;
        col.pv.rendered_md = false;
        col.pv.md_images = 0;
        col.pv.md_images_loaded = 0;
        col.pv.md_images_failed = 0;
        switch (info.kind) {
            .image => {
                // F-33: scaled down to the column width.
                body.setPolicy(.never, .automatic);
                const pic = gtk.Picture.new();
                pic.setCanShrink(1);
                pic.setContentFit(.scale_down);
                pic.as(gtk.Widget).setHalign(.start);
                pic.as(gtk.Widget).setValign(.start);
                const alt = dupeZ(paths.base(path));
                defer alloc.free(alt);
                pic.setAlternativeText(alt.ptr);
                inner.append(pic.as(gtk.Widget));
                self.loadImage(path, pic, col, .preview);
            },
            .text => {
                if (paths.isMarkdownName(path) and !self.private().md_source and info.content.len > 0) {
                    if (self.renderMarkdown(col, info.content, paths.parent(path))) |w| {
                        body.setPolicy(.automatic, .automatic);
                        fit_width = true;
                        inner.append(w);
                        col.pv.rendered_md = true;
                    } else self.sourceView(inner, info);
                } else self.sourceView(inner, info);
                if (info.truncated) inner.append(msgLabel("(preview truncated)"));
            },
            .zip => {
                // F-40: the table of contents as a tree.
                body.setPolicy(.automatic, .automatic);
                fit_width = true;
                var arena: std.heap.ArenaAllocator = .init(alloc);
                defer arena.deinit();
                const rows = zip.rows(arena.allocator(), info.entries) catch &.{};
                const list = gtk.Box.new(.vertical, 0);
                list.as(gtk.Widget).addCssClass("files-zip");
                for (rows) |r| list.append(zipRow(r));
                inner.append(list.as(gtk.Widget));
                if (info.entries.len == 0) inner.append(msgLabel("(empty archive)"));
                if (info.truncated) inner.append(msgLabel("(list truncated)"));
            },
            .binary => inner.append(msgLabel("binary file")),
            .other => inner.append(msgLabel("no preview")),
        }
        body.setChild(inner.as(gtk.Widget));
        scrolling.noScrollToFocus(body);
        if (fit_width) {
            if (body.getChild()) |vp| if (gobject.ext.cast(gtk.Scrollable, vp)) |sc| {
                sc.setHscrollPolicy(.minimum);
                sc.setVscrollPolicy(.natural);
            };
        } else naturalScroll(body);
    }

    fn sourceView(self: *Self, inner: *gtk.Box, info: wire.Preview) void {
        _ = self;
        const text = dupeZ(if (info.content.len > 0) info.content else "(empty file)");
        defer alloc.free(text);
        const l = gtk.Label.new(text.ptr);
        l.as(gtk.Widget).addCssClass("files-pre");
        l.setXalign(0);
        l.setYalign(0);
        l.as(gtk.Widget).setHalign(.start);
        l.as(gtk.Widget).setValign(.start);
        inner.append(l.as(gtk.Widget));
    }

    fn zipRow(r: zip.Row) *gtk.Widget {
        const row = gtk.Box.new(.horizontal, 0);
        row.as(gtk.Widget).addCssClass("files-zip-entry");
        if (r.dir) row.as(gtk.Widget).addCssClass("dir");
        const prefix = dupeZ(r.prefix);
        defer alloc.free(prefix);
        const tree = gtk.Label.new(prefix.ptr);
        tree.as(gtk.Widget).addCssClass("files-zip-tree");
        tree.as(gtk.Widget).setValign(.start);
        row.append(tree.as(gtk.Widget));
        const name = dupeZ(r.name);
        defer alloc.free(name);
        const nl = gtk.Label.new(null);
        md_view.setPlainText(nl, name.ptr);
        nl.as(gtk.Widget).addCssClass("files-zip-name");
        nl.setXalign(0);
        nl.setWrap(1);
        nl.setWrapMode(.char);
        nl.as(gtk.Widget).setHexpand(1);
        row.append(nl.as(gtk.Widget));
        if (!r.dir) {
            var sbuf: [32]u8 = undefined;
            const s = dupeZ(paths.formatSize(&sbuf, r.size));
            defer alloc.free(s);
            const sl = gtk.Label.new(s.ptr);
            sl.as(gtk.Widget).addCssClass("files-zip-size");
            sl.as(gtk.Widget).setValign(.start);
            row.append(sl.as(gtk.Widget));
        }
        return row.as(gtk.Widget);
    }

    fn renderMarkdown(self: *Self, col: *Col, content: []const u8, file_dir: []const u8) ?*gtk.Widget {
        if (col.pv.doc) |*d| d.deinit();
        col.pv.doc = md.parse(alloc, content) catch return null;
        const dark = adw.StyleManager.getDefault().getDark() != 0;
        return md_view.build(alloc, &col.pv.doc.?, file_dir, .{
            .ctx = self,
            .loadImage = mdLoadImage,
            .activateLink = mdActivateLink,
        }, dark) catch null;
    }

    fn onSourceToggled(b: *gtk.ToggleButton, col: *Col) callconv(.c) void {
        const self = col.browser;
        const src = b.getActive() != 0;
        if (self.private().md_source == src) return;
        self.private().md_source = src;
        self.applyMdView(col);
        _ = self.as(gtk.Widget).grabFocus();
    }

    /// Re-show the markdown preview in the current mode (the toggle).
    pub fn applyMdView(self: *Self, col: *Col) void {
        if (col.pv.toggle[0]) |r| {
            const src = self.private().md_source;
            if ((r.getActive() != 0) == src) r.setActive(@intFromBool(!src));
            if (col.pv.toggle[1]) |s| if ((s.getActive() != 0) != src) s.setActive(@intFromBool(src));
        }
        self.fillPreviewBody(col);
    }

    pub fn setMdSource(self: *Self, src: bool) void {
        self.private().md_source = src;
        if (self.previewCol()) |col| {
            if (col.pv.toggle[0] != null) self.applyMdView(col);
        }
    }

    fn onDownloadClicked(_: *gtk.Button, col: *Col) callconv(.c) void {
        const self = col.browser;
        if (col.pv.path) |p| self.download(p, .dialog);
        _ = self.as(gtk.Widget).grabFocus(); // keep keyboard navigation on the columns
    }

    /// F-43: a click on a wide preview (not on its links or buttons) drills in.
    fn onPreviewClick(gc: *gtk.GestureClick, _: c_int, x: f64, y: f64, col: *Col) callconv(.c) void {
        const picked = col.frame.as(gtk.Widget).pick(x, y, .{});
        _ = gc;
        if (picked) |p| {
            if (isInside(p, gtk.Button) or isInside(p, gtk.CheckButton)) return;
            if (gobject.ext.cast(gtk.Label, p)) |l| if (l.getCurrentUri() != null) return;
            if (gobject.Object.getData(p.as(gobject.Object), "md-href") != null) return;
        }
        col.browser.clickPreview();
    }

    pub fn clickPreview(self: *Self) void {
        const col = self.previewCol() orelse return;
        if (col.pv.narrow) return;
        if (col.pv.path) |p| self.setDrilled(p);
        _ = self.as(gtk.Widget).grabFocus();
    }

    // --- images -----------------------------------------------------------

    const ImageTarget = enum { preview, markdown };

    const ImageJob = struct {
        path: []const u8,
        picture: *gtk.Picture,
        col: *Col,
        load: u64,
        target: ImageTarget,
        texture: ?*gdk.Texture = null,
        svg: ?[]const u8 = null,
        err: ?[]const u8 = null,

        pub fn work(j: *ImageJob, shared: *jobs.Shared, a: Allocator) void {
            var client = shared.client(a) catch return;
            const r = api.raw(&client, a, j.path, 64 * 1024 * 1024) catch return;
            switch (r) {
                .err => |e| j.err = e,
                .ok => |bytes| {
                    // SVG: GTK's own renderer (GtkSvg), on the main thread;
                    // gdk-pixbuf's SVG loader is not always registered.
                    if (std.ascii.endsWithIgnoreCase(j.path, ".svg")) {
                        j.svg = bytes;
                        return;
                    }
                    // gdk_texture_new_from_bytes is documented thread-safe.
                    const gb = glib.Bytes.new(bytes.ptr, bytes.len);
                    defer gb.unref();
                    var gerr: ?*glib.Error = null;
                    j.texture = gdk.Texture.newFromBytes(gb, &gerr);
                    if (gerr) |e| {
                        j.err = a.dupe(u8, std.mem.span(e.f_message orelse "decode failed")) catch "decode failed";
                        e.free();
                    }
                },
            }
        }

        pub fn done(j: *ImageJob, ptr: *anyopaque, _: Allocator) void {
            const self = from(ptr);
            defer j.picture.unref();
            defer if (j.texture) |t| t.unref();
            self.private().jobs_running -= 1;
            // Is the column still showing what asked for this image?
            var alive = false;
            for (self.private().cols.items) |c| {
                if (c == j.col and c.pv.load == j.load) alive = true;
            }
            if (!alive) return;
            if (j.target == .markdown) j.col.pv.md_images_loaded += 1;
            if (j.svg) |bytes| {
                const gb = glib.Bytes.new(bytes.ptr, bytes.len);
                defer gb.unref();
                const svg = gtk.Svg.newFromBytes(gb);
                defer svg.unref();
                const p = svg.as(gdk.Paintable);
                const w = p.getIntrinsicWidth();
                const h = p.getIntrinsicHeight();
                if (w > 0 and h > 0) {
                    j.picture.setPaintable(p);
                    if (j.target == .preview) j.col.pv.image = .{ .w = w, .h = h };
                    return;
                }
                j.err = "SVG not rendered";
            }
            if (j.texture) |t| {
                j.picture.setPaintable(t.as(gdk.Paintable));
                if (j.target == .preview) j.col.pv.image = .{ .w = t.getWidth(), .h = t.getHeight() };
            } else {
                log.info("image {s}: {s}", .{ j.path, j.err orelse "failed" });
                if (j.target == .preview) {
                    j.col.pv.image_failed = true;
                    if (j.picture.as(gtk.Widget).getParent()) |p| {
                        if (gobject.ext.cast(gtk.Box, p)) |box| box.append(msgLabel("preview failed"));
                    }
                } else {
                    j.col.pv.md_images_failed += 1;
                    md_view.imageFailed(j.picture);
                }
            }
        }
    };

    fn loadImage(self: *Self, path: []const u8, pic: *gtk.Picture, col: *Col, target: ImageTarget) void {
        const priv = self.private();
        const task = jobs.Task(ImageJob).create(priv.shared) catch return;
        task.job = .{
            .path = task.arenaAlloc().dupe(u8, path) catch return,
            .picture = @ptrCast(pic.as(gobject.Object).ref()),
            .col = col,
            .load = col.pv.load,
            .target = target,
        };
        if (target == .markdown) col.pv.md_images += 1;
        priv.jobs_running += 1;
        task.start();
    }

    fn mdLoadImage(ctx: *anyopaque, path: []const u8, pic: *gtk.Picture) void {
        const self = from(ctx);
        const col = self.previewCol() orelse return;
        self.loadImage(path, pic, col, .markdown);
    }

    /// F-38: markdown link activation.
    fn mdActivateLink(ctx: *anyopaque, href: []const u8, shift: bool) void {
        from(ctx).activateLink(href, shift);
    }

    pub fn activateLink(self: *Self, href: []const u8, shift: bool) void {
        if (href.len == 0 or href[0] == '#') return;
        const widget = self.as(gtk.Widget);
        if (paths.startsWithIgnoreCase(href, "http:") or paths.startsWithIgnoreCase(href, "https:")) {
            iface.services.url(href, if (shift) .copy else .open, widget);
            return;
        }
        if (paths.startsWithIgnoreCase(href, "mailto:")) {
            iface.services.url(href, .choose, widget);
            return;
        }
        const col = self.previewCol() orelse return;
        const file = col.pv.path orelse return;
        const cut = std.mem.indexOfAny(u8, href, "#?") orelse href.len;
        const decoded = paths.percentDecode(alloc, href[0..cut]) catch return;
        defer alloc.free(decoded);
        const local = (paths.resolveRelative(alloc, paths.parent(file), decoded) catch return) orelse {
            self.status("can't open {s}", .{href});
            return;
        };
        defer alloc.free(local);
        self.setDir(paths.parent(local));
        self.setCursor(paths.base(local));
        self.rerender();
    }

    /// Put the cursor on `path` (its parent becomes the directory).
    pub fn navigate(self: *Self, path: []const u8) void {
        const p = dupe(path);
        defer alloc.free(p);
        if (std.mem.eql(u8, p, "/")) {
            self.setDir("/");
            self.setCursor(null);
        } else {
            self.setDir(paths.parent(p));
            self.setCursor(paths.base(p));
        }
        self.setDrilled(null);
        self.rerender();
    }

    /// The window regained focus (notify::is-active).
    pub fn windowRegainedFocus(self: *Self) void {
        if (self.containsFocus()) self.refreshAll();
    }

    /// A horizontal wheel gesture over the strip.
    pub fn wheel(self: *Self, dx: f64) void {
        const priv = self.private();
        priv.follow.active = false;
        priv.pinned = false;
        const adj = priv.scroller.getHadjustment();
        adj.setValue(adj.getValue() + dx);
    }

    // --- drilled preview (F-43…F-45) ----------------------------------------

    pub fn setDrilled(self: *Self, path: ?[]const u8) void {
        const priv = self.private();
        if (priv.drilled == null and path == null) return;
        if (priv.drilled != null and path != null and std.mem.eql(u8, priv.drilled.?, path.?)) return;
        if (priv.drilled) |d| alloc.free(d);
        priv.drilled = if (path) |p| dupe(p) else null;
        if (path != null) self.as(gtk.Widget).addCssClass("drilled") else self.as(gtk.Widget).removeCssClass("drilled");
        self.smoothScrollRight();
    }

    fn previewBody(self: *Self) ?*gtk.ScrolledWindow {
        const col = self.previewCol() orelse return null;
        return col.pv.body;
    }

    // --- horizontal follow and row reveal (F-63, F-64) -----------------------

    // F-63 / F-65. The horizontal follow eases toward "rightmost column at
    // the right edge, cursor column not pushed off the left edge". Its
    // target comes from the column model (the clips' widths as this
    // frame lays them out), never from the scroll adjustment, whose upper
    // bound is only updated by the next layout: a follow that ended on a
    // frame right after a long one used to settle on the old extent and
    // leave a new column off-screen. When the follow ends the view stays
    // pinned to the right: every later change of the scroll extent or of
    // the browser's width (columns still growing, a layout change, a
    // window resize) puts it back on the target, until the user scrolls
    // it away (wheel, scrollbar).

    fn smoothScrollRight(self: *Self) void {
        const priv = self.private();
        if (reducedMotion()) return self.jumpRight();
        priv.follow = .{ .active = true, .t0 = 0 };
        priv.pinned = true;
        self.ensureTick();
    }

    fn jumpRight(self: *Self) void {
        const priv = self.private();
        priv.follow = .{};
        priv.pinned = true;
        self.applyScroll(self.followTarget());
    }

    /// The target scroll offset, from the strip's columns in order.
    pub fn followTarget(self: *Self) f64 {
        const priv = self.private();
        var cursor_clip: ?*Clip = null;
        if (priv.drilled == null) {
            // The cursor's column is the last of the directory chain.
            for (priv.cols.items) |c| {
                if (c.kind == .listing and c.cursor_col) cursor_clip = c.clip;
            }
        }
        var total: f64 = 0;
        var cursor_x: ?f64 = null;
        var child = priv.strip.as(gtk.Widget).getFirstChild();
        while (child) |w| : (child = w.getNextSibling()) {
            const clip = gobject.ext.cast(Clip, w) orelse continue;
            if (cursor_clip == clip) cursor_x = total;
            total += @round(clip.currentWidth());
        }
        const page: f64 = @floatFromInt(priv.scroller.as(gtk.Widget).getWidth());
        var t = total - page;
        if (cursor_x) |x| t = @min(t, x);
        return @max(0, t);
    }

    pub fn lastAnimationMs(self: *Self) i64 {
        return self.private().last_anim_ms;
    }

    pub fn pinnedRight(self: *Self) bool {
        return self.private().pinned;
    }

    fn applyScroll(self: *Self, v: f64) void {
        const priv = self.private();
        const adj = priv.scroller.getHadjustment();
        priv.applying = true;
        defer priv.applying = false;
        adj.setValue(v);
    }

    fn stepFollow(self: *Self, now: i64) void {
        const priv = self.private();
        if (!priv.follow.active) return;
        const adj = priv.scroller.getHadjustment();
        const target = self.followTarget();
        if (priv.follow.t0 == 0) priv.follow.t0 = now;
        const d = target - adj.getValue();
        if (now - priv.follow.t0 >= follow_ms * 1000) {
            // Settle exactly; if the extent is not laid out yet the pin
            // finishes the move when it is (onHadjChanged).
            self.applyScroll(target);
            priv.follow.active = false;
            return;
        }
        self.applyScroll(adj.getValue() + d * 0.25);
    }

    /// The scroll extent or the viewport changed (a layout happened).
    fn onHadjChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        const page = adj.getPageSize();
        // A different width (layout change, window resize, re-attach):
        // back to the right edge, as the Electron client's re-attach does.
        if (page != priv.last_page and priv.last_page != 0 and priv.rendered_once) priv.pinned = true;
        priv.last_page = page;
        priv.last_upper = adj.getUpper();
        // Not from in here: this runs inside the scrolled window's
        // allocation, where a new value does not reach the viewport. The
        // next frame's tick applies it before that frame's layout.
        if (priv.pinned and !priv.follow.active) {
            priv.pin_pending = true;
            self.ensureTick();
        }
    }

    /// The offset changed: if neither we nor a layout moved it, the user
    /// did (scrollbar), which ends the pin.
    fn onHadjValue(_: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.applying) return;
        // Only real user input ends the pin (wheel and touchpad in
        // onScroll, the scrollbar in onScrollbarPress, files-scroll); any
        // other change of a pinned view (focus changes, GTK's own
        // adjustments) is undone on the next frame.
        if (priv.pinned and !priv.follow.active) {
            priv.pin_pending = true;
            self.ensureTick();
        }
    }

    fn onScrollbarPress(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Self) callconv(.c) void {
        self.private().pinned = false;
        self.private().follow.active = false;
    }

    fn onScrollBegin(_: *gtk.EventControllerScroll, self: *Self) callconv(.c) void {
        // A wheel or touchpad gesture cancels the easing (files-widget.js).
        self.private().follow.active = false;
    }

    fn onScroll(_: *gtk.EventControllerScroll, dx: f64, dy: f64, self: *Self) callconv(.c) c_int {
        self.private().follow.active = false;
        // Scrolling sideways is the user moving the strip away from its
        // right edge; scrolling a column or the preview vertically is not.
        if (@abs(dx) > @abs(dy)) self.private().pinned = false;
        return 0;
    }

    /// Keep the cursor row vertically in view (F-64). Returns false while
    /// the row is not laid out yet (try again next frame).
    fn revealCursorRow(self: *Self) bool {
        const priv = self.private();
        for (priv.cols.items) |c| {
            if (c.kind != .listing or !c.cursor_col) continue;
            const i = c.hl orelse return true;
            const sw = c.scroller orelse return true;
            const box = c.rows_box orelse return true;
            if (i >= c.rows.items.len) return true;
            var b: graphene.Rect = undefined;
            if (c.rows.items[i].as(gtk.Widget).computeBounds(box.as(gtk.Widget), &b) == 0) return false;
            if (b.f_size.f_height <= 0) return false;
            const adj = sw.getVadjustment();
            // Bounds relative to the rows box start at its content box,
            // inside its 4 px top padding, while the scroll adjustment
            // counts from the padding's edge: add that offset (measured
            // against the column's viewport at the laid-out scroll value),
            // or the cursor row ends up 4 px under the bottom edge (N11).
            var offset: f64 = 0;
            if (sw.getChild()) |vp| {
                var p: graphene.Point = undefined;
                if (box.as(gtk.Widget).computePoint(vp, &graphene.Point{ .f_x = 0, .f_y = 0 }, &p) != 0)
                    offset = p.f_y + adj.getValue();
            }
            const top: f64 = b.f_origin.f_y + offset;
            const bottom: f64 = top + b.f_size.f_height;
            if (adj.getUpper() < bottom or adj.getPageSize() <= 0) return false;
            if (top < adj.getValue()) {
                adj.setValue(top);
            } else if (bottom > adj.getValue() + adj.getPageSize()) {
                adj.setValue(bottom - adj.getPageSize());
            }
            return true;
        }
        return true;
    }

    fn restoreScrolls(self: *Self) bool {
        var pending = false;
        for (self.private().cols.items) |c| {
            if (c.restore_scroll) |v| {
                if (c.scroller) |sw| {
                    const adj = sw.getVadjustment();
                    if (adj.getUpper() - adj.getPageSize() >= v) {
                        adj.setValue(v);
                        c.restore_scroll = null;
                    } else pending = true;
                } else c.restore_scroll = null;
            }
            // A saved position waits for the rebuilt body it belongs to
            // (applying it to the old body would lose it, F-42).
            if (c.pv.restore_scroll != null and !c.pv.restore_rebuilt) continue;
            if (c.pv.restore_scroll) |v| {
                if (c.pv.body) |body| {
                    const adj = body.getVadjustment();
                    if (adj.getUpper() - adj.getPageSize() >= v) {
                        adj.setValue(v);
                        log.debug("pv-scroll: restored {d} (upper {d})", .{ v, adj.getUpper() });
                        c.pv.restore_scroll = null;
                        c.pv.restore_rebuilt = false;
                    } else pending = true;
                } else {
                    c.pv.restore_scroll = null;
                    c.pv.restore_rebuilt = false;
                }
            }
        }
        return pending;
    }

    /// GTK's "reduce motion" settings (gtk-enable-animations off, or
    /// gtk-interface-reduced-motion): animations finish at once, as the
    /// Electron client's prefers-reduced-motion rules make them 1 ms.
    pub fn reducedMotion() bool {
        const settings = gtk.Settings.getDefault() orelse return false;
        var v = std.mem.zeroes(gobject.Value);
        _ = v.init(gobject.ext.types.boolean);
        defer v.unset();
        settings.as(gobject.Object).getProperty("gtk-enable-animations", &v);
        if (v.getBoolean() == 0) return true;
        var e = std.mem.zeroes(gobject.Value);
        _ = e.init(gtk.ReducedMotion.getGObjectType());
        defer e.unset();
        settings.as(gobject.Object).getProperty("gtk-interface-reduced-motion", &e);
        return e.getEnum() == @intFromEnum(gtk.ReducedMotion.reduce);
    }

    fn ensureTick(self: *Self) void {
        const priv = self.private();
        if (priv.tick_id != 0) return;
        priv.tick_id = self.as(gtk.Widget).addTickCallback(onTick, null, null);
    }

    fn onTick(widget: *gtk.Widget, clock: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
        const self = gobject.ext.cast(Self, widget) orelse return 0;
        const priv = self.private();
        const now = clock.getFrameTime();
        var running = false;
        for (priv.cols.items) |c| {
            if (c.clip.tick(now)) running = true;
        }
        var i: usize = 0;
        while (i < priv.leaving.items.len) {
            const c = priv.leaving.items[i];
            if (c.clip.tick(now)) {
                running = true;
                i += 1;
            } else {
                _ = priv.leaving.orderedRemove(i);
                self.removeCol(c);
            }
        }
        self.stepFollow(now);
        if (priv.pin_pending) {
            priv.pin_pending = false;
            if (priv.pinned and !priv.follow.active) self.applyScroll(self.followTarget());
        }
        if (priv.reveal_frames > 0) {
            // Until the row is laid out (a fresh 2000-row column takes a
            // few frames), at most ~1 s.
            priv.reveal_frames = if (self.revealCursorRow()) 0 else priv.reveal_frames - 1;
        }
        const restoring = self.restoreScrolls();
        if (restoring) priv.restore_frames += 1 else priv.restore_frames = 0;
        if (priv.restore_frames > 30) {
            // The content no longer reaches the old position (it got
            // shorter): go as far as it allows (F-42).
            for (priv.cols.items) |c| {
                if (c.restore_scroll != null) if (c.scroller) |sw| {
                    const adj = sw.getVadjustment();
                    adj.setValue(adj.getUpper() - adj.getPageSize());
                };
                if (c.pv.restore_scroll != null and c.pv.restore_rebuilt) if (c.pv.body) |body| {
                    const adj = body.getVadjustment();
                    adj.setValue(adj.getUpper() - adj.getPageSize());
                };
                c.restore_scroll = null;
                if (c.pv.restore_rebuilt) c.pv.restore_scroll = null;
                c.pv.restore_rebuilt = false;
            }
            priv.restore_frames = 0;
        }
        if (running or priv.follow.active or priv.reveal_frames > 0 or restoring or priv.pin_pending) return 1;
        priv.tick_id = 0;
        return 0;
    }

    fn fadeWidget(w: *gtk.Widget, ms: i64) void {
        const Fade = struct {
            t0: i64 = 0,
            dur: i64,
            fn tick(widget: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
                const f: *@This() = @ptrCast(@alignCast(data.?));
                const now = clock.getFrameTime();
                if (f.t0 == 0) f.t0 = now;
                const p = @min(1.0, @as(f64, @floatFromInt(now - f.t0)) / @as(f64, @floatFromInt(f.dur)));
                widget.setOpacity(@import("clip.zig").ease(.out, p));
                return if (p >= 1) 0 else 1;
            }
            fn free(data: ?*anyopaque) callconv(.c) void {
                alloc.destroy(@as(*@This(), @ptrCast(@alignCast(data.?))));
            }
        };
        const f = alloc.create(Fade) catch {
            w.setOpacity(1);
            return;
        };
        f.* = .{ .dur = ms * 1000 };
        _ = w.addTickCallback(Fade.tick, f, Fade.free);
    }

    // --- title (F-14) --------------------------------------------------------

    fn updateTitle(self: *Self) void {
        const priv = self.private();
        const sel = if (priv.cursor) |c| paths.join(alloc, priv.dir, c) catch return else dupe(priv.dir);
        defer alloc.free(sel);
        const t = paths.tilde(alloc, priv.home, sel) catch return;
        defer alloc.free(t);
        if (priv.title) |old| {
            if (std.mem.eql(u8, old, t)) return;
            alloc.free(old);
        }
        priv.title = dupeZ(t);
        if (priv.host) |h| h.titleChanged(priv.id);
    }

    // --- watch streams (F-59) ------------------------------------------------

    fn syncWatchers(self: *Self) void {
        const priv = self.private();
        var wanted: [2]?[]const u8 = .{ priv.dir, priv.rightmost };
        for (&wanted) |*w| {
            if (w.*) |d| {
                if (self.cached(d)) |l| if (l.err != null) {
                    w.* = null;
                };
            }
        }
        if (wanted[0] != null and wanted[1] != null and std.mem.eql(u8, wanted[0].?, wanted[1].?)) wanted[1] = null;
        var i: usize = 0;
        while (i < priv.watchers.items.len) {
            const w = priv.watchers.items[i];
            var keep = false;
            for (wanted) |d| {
                if (d != null and std.mem.eql(u8, d.?, w.dir)) keep = true;
            }
            if (keep) {
                i += 1;
            } else {
                _ = priv.watchers.orderedRemove(i);
                w.stop();
            }
        }
        for (wanted) |maybe| {
            const d = maybe orelse continue;
            var have = false;
            for (priv.watchers.items) |w| {
                if (std.mem.eql(u8, w.dir, d)) have = true;
            }
            if (have) continue;
            const w = jobs.Watch.start(priv.shared, d, onWatchEvent) catch continue;
            if (w.stopped) {
                w.stop();
                continue;
            }
            priv.watchers.append(alloc, w) catch {
                w.stop();
            };
        }
    }

    fn removeWatcher(self: *Self, w: *jobs.Watch) void {
        const priv = self.private();
        for (priv.watchers.items, 0..) |x, i| {
            if (x == w) {
                _ = priv.watchers.orderedRemove(i);
                w.stop();
                return;
            }
        }
    }

    fn onWatchEvent(ptr: *anyopaque, w: *jobs.Watch, ev: jobs.WatchEvent) void {
        const self = from(ptr);
        log.debug("watch {s}: {t}", .{ w.dir, ev });
        switch (ev) {
            .change, .reopened => self.changed(w.dir),
            .gone => {
                const d = dupe(w.dir);
                defer alloc.free(d);
                self.removeWatcher(w);
                self.changed(d);
            },
            .closed => self.removeWatcher(w),
        }
    }

    fn changed(self: *Self, d: []const u8) void {
        const priv = self.private();
        self.dropCache(d);
        if (priv.rename != null) return; // F-51
        if (priv.watch_timer != 0) _ = glib.Source.remove(priv.watch_timer);
        priv.watch_timer = glib.timeoutAdd(50, onWatchTimer, self);
    }

    fn onWatchTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        self.private().watch_timer = 0;
        self.rerender();
        return 0;
    }

    // --- focus refresh (F-61) --------------------------------------------------

    pub fn refreshAll(self: *Self) void {
        const priv = self.private();
        if (!priv.opened) {
            if (priv.open_failed != null) self.open();
            return;
        }
        const now = nowMs();
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(alloc);
        var it = priv.cache.iterator();
        while (it.next()) |kv| {
            if (now - kv.value_ptr.t > 1000) stale.append(alloc, kv.key_ptr.*) catch {};
        }
        for (stale.items) |k| self.dropCache(k);
        if (priv.rename != null) return;
        self.rerender();
    }

    /// Focus left the pane: an open delete confirmation is dismissed (it
    /// must never be left behind in an unfocused pane).
    fn onFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        if (self.private().confirm != null) {
            // Deferred: focus is still moving.
            _ = glib.idleAdd(confirmBlurIdle, self.ref());
        }
    }

    fn confirmBlurIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        defer self.unref();
        if (self.private().confirm != null and !self.containsFocus()) self.finishConfirmNoFocus();
        return 0;
    }

    /// The container hides or shows the pane (Pane.setShown).
    pub fn setShown(self: *Self, shown: bool) void {
        if (!shown and self.private().confirm != null) self.finishConfirmNoFocus();
    }

    fn onFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        const priv = self.private();
        self.refreshAll();
        if (priv.host) |h| h.focusEntered(priv.id);
    }

    fn onWindowActive(win: *gtk.Window, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (win.isActive() == 0) return;
        self.windowRegainedFocus();
    }

    pub fn containsFocus(self: *Self) bool {
        const root = self.as(gtk.Widget).getRoot() orelse return false;
        const f = root.getFocus() orelse return false;
        return f == self.as(gtk.Widget) or f.isAncestor(self.as(gtk.Widget)) != 0;
    }

    fn onMap(widget: *gtk.Widget, self: *Self) callconv(.c) void {
        const priv = self.private();
        // F-65: re-attached after a layout change: back to the right edge.
        if (priv.rendered_once) self.jumpRight();
        if (priv.window == null) {
            const root = widget.getRoot() orelse return;
            const win = gobject.ext.cast(gtk.Window, root) orelse return;
            priv.window = win;
            priv.window_handler = gobject.Object.signals.notify.connect(win, *Self, onWindowActive, self, .{ .detail = "is-active" });
        }
    }

    fn onUnmap(_: *gtk.Widget, self: *Self) callconv(.c) void {
        self.disconnectWindow();
        if (self.private().confirm != null) self.finishConfirmNoFocus();
    }

    fn disconnectWindow(self: *Self) void {
        const priv = self.private();
        if (priv.window) |w| {
            gobject.signalHandlerDisconnect(w.as(gobject.Object), priv.window_handler);
            priv.window = null;
            priv.window_handler = 0;
        }
    }

    // --- keyboard (F-20…F-26, F-44) ----------------------------------------------

    fn onKeyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, self: *Self) callconv(.c) c_int {
        return @intFromBool(self.handleKey(keyval, state));
    }

    /// One key press. Returns whether the browser consumed it. The GTK key
    /// controller and the control socket both enter here.
    pub fn handleKey(self: *Self, keyval: c_uint, state: gdk.ModifierType) bool {
        const priv = self.private();
        if (priv.rename != null) return false; // typed keys belong to the entry
        if (priv.confirm) |c| {
            switch (keyval) {
                gdk.KEY_Escape => self.finishConfirm(false),
                // Focus stays inside the confirmation (D5): Tab and the
                // arrows move between its two buttons.
                gdk.KEY_Tab, gdk.KEY_ISO_Left_Tab, gdk.KEY_KP_Tab, gdk.KEY_Left, gdk.KEY_Right => {
                    const on_delete = c.delete.as(gtk.Widget).hasFocus() != 0;
                    _ = (if (on_delete) c.cancel else c.delete).as(gtk.Widget).grabFocus();
                },
                gdk.KEY_Return, gdk.KEY_KP_Enter, gdk.KEY_space => return false, // the focused button
                // Nothing else reaches the columns under the modal.
                else => {},
            }
            return true;
        }
        const ctrl = state.control_mask;
        const alt = state.alt_mask;
        const meta = state.meta_mask or state.super_mask;
        // Paste (Ctrl+V / Ctrl+Shift+V): the Electron page's paste event.
        if (ctrl and !alt and !meta and (keyval == gdk.KEY_v or keyval == gdk.KEY_V)) {
            self.paste();
            return true;
        }
        if (ctrl or alt or meta) return false; // F-26: pane chords pass through

        if (priv.drilled != null) {
            const body = self.previewBody();
            var by: ?f64 = null;
            switch (keyval) {
                gdk.KEY_Up, gdk.KEY_k => by = -scroll_step,
                gdk.KEY_Down, gdk.KEY_j => by = scroll_step,
                gdk.KEY_Page_Up, gdk.KEY_KP_Page_Up => if (body) |b| {
                    by = -pageOf(b);
                },
                gdk.KEY_Page_Down, gdk.KEY_KP_Page_Down, gdk.KEY_space => if (body) |b| {
                    by = pageOf(b);
                },
                else => {},
            }
            if (by) |dy| {
                if (body) |b| {
                    const adj = b.getVadjustment();
                    adj.setValue(adj.getValue() + dy);
                }
                return true;
            }
            switch (keyval) {
                gdk.KEY_Home, gdk.KEY_End => {
                    if (body) |b| {
                        const adj = b.getVadjustment();
                        adj.setValue(if (keyval == gdk.KEY_Home) 0 else adj.getUpper());
                    }
                    return true;
                },
                gdk.KEY_Left, gdk.KEY_h, gdk.KEY_Escape => {
                    self.setDrilled(null);
                    return true;
                },
                gdk.KEY_Right, gdk.KEY_l, gdk.KEY_Return, gdk.KEY_KP_Enter => return true,
                else => {},
            }
        }

        const listing = self.cached(priv.dir);
        const entries: []const Listing.Entry = if (listing) |l| l.entries else &.{};
        const ci: ?usize = if (priv.cursor) |c| (if (listing) |l| l.find(c) else null) else null;
        switch (keyval) {
            gdk.KEY_Up, gdk.KEY_k, gdk.KEY_Down, gdk.KEY_j => {
                // Nothing to move over (an error such as a host timeout,
                // or an empty directory): list again once the cache entry
                // has expired, as files-widget.js's key handler does by
                // calling list() on every key (D9).
                if (entries.len == 0) {
                    if (self.fresh(priv.dir) == null) {
                        priv.pending_pick = true;
                        self.rerender();
                    }
                    return true;
                }
                const down = keyval == gdk.KEY_Down or keyval == gdk.KEY_j;
                const next: usize = if (ci) |i|
                    (if (down) @min(entries.len - 1, i + 1) else i -| 1)
                else if (down) 0 else entries.len - 1;
                self.setCursor(entries[next].name);
                self.rerender();
                return true;
            },
            gdk.KEY_Right, gdk.KEY_l, gdk.KEY_Return, gdk.KEY_KP_Enter => {
                const i = ci orelse return false;
                const e = entries[i];
                if (!e.dir) {
                    // F-21: drill into the preview once it has content.
                    if (self.previewCol()) |col| {
                        if (col.pv.body != null and !col.pv.narrow and col.pv.loaded) {
                            const p = paths.join(alloc, priv.dir, e.name) catch return true;
                            defer alloc.free(p);
                            self.setDrilled(p);
                        }
                    }
                    return true;
                }
                const sub = paths.join(alloc, priv.dir, e.name) catch return true;
                defer alloc.free(sub);
                self.setDir(sub);
                self.setCursor(null);
                priv.pending_pick = true;
                self.rerender();
                return true;
            },
            gdk.KEY_Left, gdk.KEY_h => {
                if (std.mem.eql(u8, priv.dir, "/")) return false;
                const name = dupe(paths.base(priv.dir));
                defer alloc.free(name);
                const parent = dupe(paths.parent(priv.dir));
                defer alloc.free(parent);
                self.setCursor(name);
                self.setDir(parent);
                self.rerender();
                return true;
            },
            gdk.KEY_r, gdk.KEY_F2 => {
                if (priv.cursor == null) return false;
                self.startRename();
                return true;
            },
            // A-17: Backspace stays a delete key.
            gdk.KEY_d, gdk.KEY_Delete, gdk.KEY_KP_Delete, gdk.KEY_BackSpace => {
                if (priv.cursor == null) return false;
                self.deleteCursor();
                return true;
            },
            gdk.KEY_D => {
                if (priv.cursor == null) return false;
                const i = ci orelse return true;
                if (entries[i].dir) {
                    self.status("select a file to download", .{});
                    return true;
                }
                const p = paths.join(alloc, priv.dir, entries[i].name) catch return true;
                defer alloc.free(p);
                self.download(p, .dialog);
                return true;
            },
            else => return false,
        }
    }

    fn pageOf(b: *gtk.ScrolledWindow) f64 {
        return b.getVadjustment().getPageSize() * 0.9;
    }

    // --- rename (F-50, F-51) ---------------------------------------------------

    const RenameJob = struct {
        path: []const u8,
        name: []const u8,
        old: []const u8,
        result: wire.Result([]const u8) = .{ .err = "OutOfMemory" },

        pub fn work(j: *RenameJob, shared: *jobs.Shared, a: Allocator) void {
            var client = shared.client(a) catch return;
            j.result = api.rename(&client, a, j.path, j.name) catch .{ .err = "OutOfMemory" };
        }

        pub fn done(j: *RenameJob, ptr: *anyopaque, _: Allocator) void {
            const self = from(ptr);
            self.private().jobs_running -= 1;
            switch (j.result) {
                .ok => |n| {
                    self.setCursor(n);
                    self.status("renamed {s} → {s}", .{ j.old, n });
                },
                .err => |e| self.status("rename failed: {s}", .{e}),
            }
            self.dropCache(paths.parent(j.path));
            self.rerender();
            self.takeFocusBack();
        }
    };

    pub fn startRename(self: *Self) void {
        const priv = self.private();
        if (priv.rename != null or priv.confirm != null) return;
        const name = priv.cursor orelse return;
        var col: ?*Col = null;
        for (priv.cols.items) |c| {
            if (c.kind == .listing and c.cursor_col) col = c;
        }
        const c = col orelse return;
        const i = c.hl orelse return;
        if (i >= c.rows.items.len) return;
        const row = c.rows.items[i];
        const name_label = row.as(gtk.Widget).getFirstChild() orelse return;

        const entry = gtk.Entry.new();
        entry.as(gtk.Widget).addCssClass("files-rename");
        entry.as(gtk.Widget).setHexpand(1);
        const z = dupeZ(name);
        defer alloc.free(z);
        entry.as(gtk.Editable).setText(z.ptr);
        name_label.setVisible(0);
        row.insertChildAfter(entry.as(gtk.Widget), name_label);

        const r = alloc.create(Rename) catch return;
        _ = entry.as(gobject.Object).ref();
        _ = row.as(gobject.Object).ref();
        r.* = .{ .entry = entry, .row = row, .name_label = name_label, .old = dupe(name), .dir = dupe(priv.dir) };
        priv.rename = r;

        _ = gtk.Entry.signals.activate.connect(entry, *Self, onRenameActivate, self, .{});
        const ec = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(ec, *Self, onRenameKey, self, .{});
        entry.as(gtk.Widget).addController(ec.as(gtk.EventController));
        const fc = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.leave.connect(fc, *Self, onRenameFocusLeave, self, .{});
        entry.as(gtk.Widget).addController(fc.as(gtk.EventController));

        _ = entry.as(gtk.Widget).grabFocus();
        // The stem is preselected, like Finder's rename.
        const stem = paths.charCount(name[0..paths.renameStemLen(name)]);
        entry.as(gtk.Editable).selectRegion(0, @intCast(stem));
    }

    fn onRenameActivate(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.finishRename(true);
    }

    fn onRenameKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Self) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            self.finishRename(false);
            return 1;
        }
        return 0;
    }

    fn onRenameFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        // Losing focus cancels; deferred so a click that moves focus is
        // handled first and the entry is not removed under GTK's feet.
        _ = glib.idleAdd(renameBlurIdle, self.ref());
    }

    fn renameBlurIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        defer self.unref();
        if (self.private().rename) |r| {
            if (r.entry.as(gtk.Widget).hasFocus() == 0 and !r.settled) self.finishRename(false);
        }
        return 0;
    }

    /// Enter (commit) or Escape / focus loss (cancel). Also the control
    /// socket's entry point, after it set the entry's text.
    pub fn finishRename(self: *Self, commit: bool) void {
        const priv = self.private();
        const r = priv.rename orelse return;
        if (r.settled) return;
        r.settled = true;
        const text = std.mem.span(r.entry.as(gtk.Editable).getText());
        const new_name = dupe(std.mem.trim(u8, text, " \t\r\n"));
        defer alloc.free(new_name);
        priv.rename = null;
        defer freeRename(r);
        // Put the row back as it was (the re-render replaces it anyway).
        r.row.remove(r.entry.as(gtk.Widget));
        r.name_label.setVisible(1);
        if (commit and new_name.len > 0 and !std.mem.eql(u8, new_name, r.old)) {
            const task = jobs.Task(RenameJob).create(priv.shared) catch return;
            const a = task.arenaAlloc();
            task.job = .{
                .path = paths.join(a, r.dir, r.old) catch return,
                .name = a.dupe(u8, new_name) catch return,
                .old = a.dupe(u8, r.old) catch return,
            };
            priv.jobs_running += 1;
            task.start();
            return;
        }
        self.rerender();
        self.takeFocusBack();
    }

    fn freeRename(r: *Rename) void {
        r.entry.as(gobject.Object).unref();
        r.row.as(gobject.Object).unref();
        alloc.free(r.old);
        alloc.free(r.dir);
        alloc.destroy(r);
    }

    /// Drop an open rename without committing or re-rendering (its row is
    /// about to be replaced, or a click elsewhere takes over).
    fn abortRename(self: *Self) void {
        const priv = self.private();
        const r = priv.rename orelse return;
        r.settled = true;
        priv.rename = null;
        r.row.remove(r.entry.as(gtk.Widget));
        r.name_label.setVisible(1);
        freeRename(r);
        self.takeFocusBack();
    }

    /// Return keyboard focus to the browser after the rename field closes,
    /// but only if focus is still in the browser (or nowhere, after the
    /// focused field was removed): a rename cancelled because the user
    /// clicked or switched to another pane must not pull focus back.
    fn takeFocusBack(self: *Self) void {
        const root = self.as(gtk.Widget).getRoot() orelse return;
        if (root.getFocus()) |f| {
            if (f != self.as(gtk.Widget) and f.isAncestor(self.as(gtk.Widget)) == 0) return;
        }
        _ = self.as(gtk.Widget).grabFocus();
    }

    pub fn renameEntry(self: *Self) ?*gtk.Entry {
        const r = self.private().rename orelse return null;
        return r.entry;
    }

    // --- delete (F-52, F-53) -----------------------------------------------------

    const DeleteJob = struct {
        path: []const u8,
        name: []const u8,
        dir: []const u8,
        rest: []const []const u8,
        index: usize,
        result: wire.Result(void) = .{ .err = "OutOfMemory" },

        pub fn work(j: *DeleteJob, shared: *jobs.Shared, a: Allocator) void {
            var client = shared.client(a) catch return;
            j.result = api.delete(&client, a, j.path) catch .{ .err = "OutOfMemory" };
        }

        pub fn done(j: *DeleteJob, ptr: *anyopaque, _: Allocator) void {
            const self = from(ptr);
            self.private().jobs_running -= 1;
            switch (j.result) {
                .err => |e| {
                    self.status("delete failed: {s}", .{e});
                    return;
                },
                .ok => {},
            }
            self.status("deleted {s}", .{j.name});
            // The entry that took its index, else the new last one.
            if (std.mem.eql(u8, self.private().dir, j.dir)) {
                self.setCursor(if (j.rest.len == 0) null else j.rest[@min(j.index, j.rest.len - 1)]);
            }
            self.dropCache(j.dir);
            self.rerender();
        }
    };

    pub fn deleteCursor(self: *Self) void {
        const priv = self.private();
        if (priv.confirm != null or priv.rename != null) return;
        const name = priv.cursor orelse return;
        const l = self.cached(priv.dir) orelse return;
        const i = l.find(name) orelse return;
        const e = l.entries[i];
        const text = if (e.dir)
            std.fmt.allocPrintSentinel(alloc, "Delete folder “{s}” and everything in it?", .{name}, 0) catch return
        else
            std.fmt.allocPrintSentinel(alloc, "Delete “{s}”?", .{name}, 0) catch return;

        var rest: std.ArrayList([]const u8) = .empty;
        for (l.entries) |x| {
            if (!std.mem.eql(u8, x.name, name)) rest.append(alloc, dupe(x.name)) catch {};
        }

        const backdrop = gtk.Box.new(.vertical, 0);
        backdrop.as(gtk.Widget).addCssClass("files-modal-overlay");
        // Pane chords do not run while this is up (K-18, shortcuts.zig).
        backdrop.as(gtk.Widget).addCssClass("wm-modal");
        backdrop.as(gtk.Widget).setHexpand(1);
        backdrop.as(gtk.Widget).setVexpand(1);
        const dialog = gtk.Box.new(.vertical, 0);
        dialog.as(gtk.Widget).addCssClass("files-confirm");
        dialog.as(gtk.Widget).setHalign(.center);
        dialog.as(gtk.Widget).setValign(.center);
        dialog.as(gtk.Widget).setVexpand(1);
        const label = gtk.Label.new(null);
        md_view.setPlainText(label, text.ptr);
        label.as(gtk.Widget).addCssClass("files-confirm-text");
        label.setWrap(1);
        label.setWrapMode(.word_char);
        label.setMaxWidthChars(48);
        label.setXalign(0);
        dialog.append(label.as(gtk.Widget));
        const actions = gtk.Box.new(.horizontal, 0);
        actions.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel("Cancel");
        const del = gtk.Button.newWithLabel("Delete");
        del.as(gtk.Widget).addCssClass("danger");
        actions.append(cancel.as(gtk.Widget));
        actions.append(del.as(gtk.Widget));
        dialog.append(actions.as(gtk.Widget));
        backdrop.append(dialog.as(gtk.Widget));

        const c = alloc.create(Confirm) catch return;
        c.* = .{
            .backdrop = backdrop,
            .dialog = dialog,
            .cancel = cancel,
            .delete = del,
            .text = text,
            .name = dupe(name),
            .dir = dupe(priv.dir),
            .entries = rest.toOwnedSlice(alloc) catch &.{},
            .index = i,
        };
        priv.confirm = c;
        _ = gtk.Button.signals.clicked.connect(cancel, *Self, onConfirmCancel, self, .{});
        _ = gtk.Button.signals.clicked.connect(del, *Self, onConfirmDelete, self, .{});
        const gc = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.released.connect(gc, *Self, onBackdropClick, self, .{});
        backdrop.as(gtk.Widget).addController(gc.as(gtk.EventController));
        priv.overlay.addOverlay(backdrop.as(gtk.Widget));
        _ = del.as(gtk.Widget).grabFocus(); // Delete has initial focus
    }

    fn onConfirmCancel(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.finishConfirm(false);
    }

    fn onConfirmDelete(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.finishConfirm(true);
    }

    fn onBackdropClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Self) callconv(.c) void {
        const c = self.private().confirm orelse return;
        const picked = c.backdrop.as(gtk.Widget).pick(x, y, .{}) orelse return;
        if (picked == c.backdrop.as(gtk.Widget)) self.finishConfirm(false);
    }

    /// Answer the confirmation (buttons, Escape, backdrop, control socket).
    pub fn finishConfirm(self: *Self, ok: bool) void {
        self.finishConfirmImpl(ok, true);
    }

    /// Cancel without taking focus (focus went elsewhere, or the pane is
    /// being hidden).
    fn finishConfirmNoFocus(self: *Self) void {
        self.finishConfirmImpl(false, false);
    }

    fn finishConfirmImpl(self: *Self, ok: bool, take_focus: bool) void {
        const priv = self.private();
        const c = priv.confirm orelse return;
        priv.confirm = null;
        // Removing the focused button would move focus out of the pane.
        if (take_focus) _ = self.as(gtk.Widget).grabFocus();
        priv.overlay.removeOverlay(c.backdrop.as(gtk.Widget));
        defer {
            alloc.free(c.text);
            alloc.free(c.name);
            alloc.free(c.dir);
            for (c.entries) |e| alloc.free(e);
            alloc.free(c.entries);
            alloc.destroy(c);
        }
        if (!ok) return;
        const task = jobs.Task(DeleteJob).create(priv.shared) catch return;
        const a = task.arenaAlloc();
        const rest = a.alloc([]const u8, c.entries.len) catch return;
        for (c.entries, rest) |e, *r| r.* = a.dupe(u8, e) catch return;
        task.job = .{
            .path = paths.join(a, c.dir, c.name) catch return,
            .name = a.dupe(u8, c.name) catch return,
            .dir = a.dupe(u8, c.dir) catch return,
            .rest = rest,
            .index = c.index,
        };
        priv.jobs_running += 1;
        task.start();
    }

    // --- uploads (F-54, F-56, F-57) ---------------------------------------------

    pub const DropTarget = union(enum) {
        col: *Col,
        browser,
    };

    /// The directory a drop on `target` uploads into (F-54).
    pub fn dropDir(self: *Self, target: DropTarget) []const u8 {
        const priv = self.private();
        switch (target) {
            .col => |c| {
                if (c.kind == .listing) return c.key;
                if (c.pv.path) |p| return paths.parent(p);
                return priv.dir;
            },
            .browser => return priv.rightmost orelse priv.dir,
        }
    }

    fn addDropTarget(self: *Self, widget: *gtk.Widget, target: DropTarget) void {
        const dt = gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true });
        const box = alloc.create(DropBox) catch return;
        box.* = .{ .browser = self, .target = target, .widget = widget };
        _ = gtk.DropTarget.signals.drop.connect(dt, *DropBox, onDrop, box, .{});
        _ = gtk.DropTarget.signals.enter.connect(dt, *DropBox, onDropEnter, box, .{});
        _ = gtk.DropTarget.signals.leave.connect(dt, *DropBox, onDropLeave, box, .{});
        widget.addController(dt.as(gtk.EventController));
        gobject.Object.weakRef(widget.as(gobject.Object), DropBox.free, box);
    }

    const DropBox = struct {
        browser: *Self,
        target: DropTarget,
        widget: *gtk.Widget,
        fn free(data: ?*anyopaque, _: *gobject.Object) callconv(.c) void {
            alloc.destroy(@as(*DropBox, @ptrCast(@alignCast(data.?))));
        }
    };

    fn onDropEnter(_: *gtk.DropTarget, _: f64, _: f64, box: *DropBox) callconv(.c) gdk.DragAction {
        box.browser.setDropHighlight(box.widget);
        return .{ .copy = true };
    }

    fn onDropLeave(_: *gtk.DropTarget, box: *DropBox) callconv(.c) void {
        if (box.browser.private().drop_highlight == box.widget) box.browser.setDropHighlight(null);
    }

    /// The 2px accent ring and wash over a valid drop target.
    pub fn setDropHighlight(self: *Self, w: ?*gtk.Widget) void {
        const priv = self.private();
        if (priv.drop_highlight) |old| old.removeCssClass("drop-target");
        priv.drop_highlight = w;
        if (w) |x| x.addCssClass("drop-target");
    }

    fn onDrop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, box: *DropBox) callconv(.c) c_int {
        const self = box.browser;
        self.setDropHighlight(null);
        const list: *gdk.FileList = @ptrCast(@alignCast(value.getBoxed() orelse return 0));
        var local: std.ArrayList([]const u8) = .empty;
        defer {
            for (local.items) |p| alloc.free(p);
            local.deinit(alloc);
        }
        var node: ?*glib.SList = list.getFiles();
        const head = node;
        defer if (head) |h| h.free();
        while (node) |n| : (node = n.f_next) {
            const file: *gio.File = @ptrCast(@alignCast(n.f_data orelse continue));
            const p = file.getPath() orelse continue;
            defer glib.free(p);
            local.append(alloc, dupe(std.mem.span(p))) catch {};
        }
        self.dropFiles(box.target, local.items);
        return 1;
    }

    /// A drop of local `files` on `target` (GTK's drop handler and the
    /// control socket's `files-drop` both enter here).
    pub fn dropFiles(self: *Self, target: DropTarget, files: []const []const u8) void {
        const d = self.dropDir(target); // captured before the walk
        self.uploadPaths(d, files);
    }

    const UploadJob = struct {
        dir: []const u8,
        roots: []const []const u8,
        /// In-memory files (a pasted image).
        blobs: []const Blob = &.{},
        count: usize = 0,
        last: ?[]const u8 = null,
        err: ?[]const u8 = null,

        const Blob = struct { name: []const u8, bytes: []const u8 };

        pub fn work(j: *UploadJob, shared: *jobs.Shared, a: Allocator) void {
            const io = global.io();
            var client = shared.client(a) catch return;
            const files = uploads.collect(a, io, j.roots) catch {
                j.err = "OutOfMemory";
                return;
            };
            j.count = files.len + j.blobs.len;
            if (j.count == 0) return;
            // Tell the main thread how many (the status line), then upload
            // one file at a time and stop at the first failure.
            mainloop.post(Started{ .shared = shared.retain(), .n = j.count }, Started.run);
            for (files) |f| {
                const file = std.Io.Dir.cwd().openFile(io, f.path, .{}) catch |e| {
                    j.err = @errorName(e);
                    return;
                };
                defer file.close(io);
                var buf: [64 * 1024]u8 = undefined;
                var reader = file.reader(io, &buf);
                const r = api.upload(&client, a, j.dir, f.name, &reader.interface, f.size) catch {
                    j.err = "OutOfMemory";
                    return;
                };
                switch (r) {
                    .ok => |n| j.last = api_topLevel(n),
                    .err => |e| {
                        j.err = e;
                        return;
                    },
                }
            }
            for (j.blobs) |b| {
                var reader: std.Io.Reader = .fixed(b.bytes);
                const r = api.upload(&client, a, j.dir, b.name, &reader, b.bytes.len) catch {
                    j.err = "OutOfMemory";
                    return;
                };
                switch (r) {
                    .ok => |n| j.last = api_topLevel(n),
                    .err => |e| {
                        j.err = e;
                        return;
                    },
                }
            }
        }

        pub fn done(j: *UploadJob, ptr: *anyopaque, _: Allocator) void {
            const self = from(ptr);
            const priv = self.private();
            priv.jobs_running -= 1;
            priv.uploading = false;
            if (j.err) |e| {
                self.status("upload failed: {s}", .{e});
                return;
            }
            if (j.count == 0) {
                self.status("nothing to upload", .{});
                return;
            }
            self.status("uploaded {d} file(s) → {s}", .{ j.count, j.dir });
            self.dropCache(j.dir);
            self.setDir(j.dir);
            self.setCursor(j.last);
            self.rerender();
        }

        const Started = struct {
            shared: *jobs.Shared,
            n: usize,
            fn run(s: *Started) void {
                defer s.shared.release();
                const b = s.shared.browser orelse return;
                from(b).status("uploading {d} file(s)…", .{s.n});
            }
        };
    };

    fn api_topLevel(n: []const u8) []const u8 {
        return wire.topLevel(n);
    }

    pub fn uploadPaths(self: *Self, d: []const u8, files: []const []const u8) void {
        self.startUpload(d, files, &.{});
    }

    fn startUpload(self: *Self, d: []const u8, files: []const []const u8, blobs: []const UploadJob.Blob) void {
        const priv = self.private();
        const task = jobs.Task(UploadJob).create(priv.shared) catch return;
        const a = task.arenaAlloc();
        const roots = a.alloc([]const u8, files.len) catch return;
        for (files, roots) |f, *r| r.* = a.dupe(u8, f) catch return;
        const bl = a.alloc(UploadJob.Blob, blobs.len) catch return;
        for (blobs, bl) |b, *o| o.* = .{ .name = a.dupe(u8, b.name) catch return, .bytes = a.dupe(u8, b.bytes) catch return };
        task.job = .{ .dir = a.dupe(u8, d) catch return, .roots = roots, .blobs = bl };
        priv.jobs_running += 1;
        priv.uploading = true;
        task.start();
    }

    /// F-56: files or an image on the clipboard upload into the rightmost
    /// directory shown; text is ignored.
    pub fn paste(self: *Self) void {
        const cb = self.as(gtk.Widget).getClipboard();
        const formats = cb.getFormats();
        if (formats.containGtype(gdk.FileList.getGObjectType()) != 0) {
            cb.readValueAsync(gdk.FileList.getGObjectType(), glib.PRIORITY_DEFAULT, null, onPasteFiles, self.ref());
        } else if (formats.containGtype(gdk.Texture.getGObjectType()) != 0) {
            cb.readTextureAsync(null, onPasteTexture, self.ref());
        } else {
            log.debug("paste: nothing to upload on the clipboard", .{});
        }
    }

    fn onPasteFiles(src: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        defer self.unref();
        const cb: *gdk.Clipboard = @ptrCast(src.?);
        var gerr: ?*glib.Error = null;
        const value = cb.readValueFinish(res, &gerr) orelse {
            if (gerr) |e| e.free();
            return;
        };
        const list: *gdk.FileList = @ptrCast(@alignCast(value.getBoxed() orelse return));
        var local: std.ArrayList([]const u8) = .empty;
        defer {
            for (local.items) |p| alloc.free(p);
            local.deinit(alloc);
        }
        var node: ?*glib.SList = list.getFiles();
        const head = node;
        defer if (head) |h| h.free();
        while (node) |n| : (node = n.f_next) {
            const file: *gio.File = @ptrCast(@alignCast(n.f_data orelse continue));
            const p = file.getPath() orelse continue;
            defer glib.free(p);
            local.append(alloc, dupe(std.mem.span(p))) catch {};
        }
        if (local.items.len == 0) return;
        if (self.private().shared.browser == null) return;
        self.uploadPaths(self.dropDir(.browser), local.items);
    }

    fn onPasteTexture(src: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        defer self.unref();
        const cb: *gdk.Clipboard = @ptrCast(src.?);
        var gerr: ?*glib.Error = null;
        const tex = cb.readTextureFinish(res, &gerr) orelse {
            if (gerr) |e| e.free();
            return;
        };
        defer tex.unref();
        if (self.private().shared.browser == null) return;
        const png = tex.saveToPngBytes();
        defer png.unref();
        var size: usize = 0;
        const ptr = png.getData(&size) orelse return;
        // Chromium names a pasted clipboard image "image.png".
        self.startUpload(self.dropDir(.browser), &.{}, &.{.{ .name = "image.png", .bytes = ptr[0..size] }});
    }

    // --- download (F-55) ---------------------------------------------------------

    pub const SaveChoice = union(enum) {
        /// The native save dialog.
        dialog,
        /// Skip the dialog: save to this path (null: as if cancelled).
        /// The control socket's way in; the rest is the same code.
        path: ?[]const u8,
    };

    const Download = struct {
        browser_shared: *jobs.Shared,
        file: []u8,
        remote: []u8,
        stream: ?*net.http.Stream = null,
        bytes: ?u64 = null,
        opened: bool = false,
        open_err: ?[]u8 = null,
        dest: ?[]u8 = null,
        decided: bool = false,
        cancelled: bool = false,
        /// Why streaming to the local file failed (a static string).
        fail: ?[]const u8 = null,

        fn destroy(d: *Download) void {
            if (d.stream) |s| s.close();
            d.browser_shared.release();
            alloc.free(d.file);
            alloc.free(d.remote);
            if (d.open_err) |e| alloc.free(e);
            if (d.dest) |x| alloc.free(x);
            alloc.destroy(d);
        }
    };

    pub fn download(self: *Self, path: []const u8, choice: SaveChoice) void {
        const priv = self.private();
        const name = paths.base(path);
        self.status("downloading {s}", .{name});
        const d = alloc.create(Download) catch return;
        d.* = .{ .browser_shared = priv.shared.retain(), .file = dupe(name), .remote = dupe(path) };
        priv.downloads += 1;
        // The request starts right away (the log's "download started"
        // carries the size), as Chromium's does behind its save dialog.
        const t = std.Thread.spawn(.{}, downloadOpen, .{d}) catch {
            priv.downloads -= 1;
            d.destroy();
            return;
        };
        t.detach();
        switch (choice) {
            .dialog => self.saveDialog(d),
            .path => |p| {
                d.decided = true;
                if (p) |x| d.dest = dupe(x) else d.cancelled = true;
            },
        }
    }

    fn downloadOpen(d: *Download) void {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var client = d.browser_shared.client(a) catch return;
        const target = wire.downloadTarget(a, d.remote) catch return;
        const s = client.open(alloc, .{ .target = target, .timeout_ms = 30_000, .idle_timeout_ms = 60_000 }) catch |e| {
            d.open_err = std.fmt.allocPrint(alloc, "cannot reach the host ({t})", .{e}) catch dupe("cannot reach the host");
            mainloop.post(DlOpened{ .d = d }, DlOpened.run);
            return;
        };
        if (s.head.status != 200) {
            var body: [1024]u8 = undefined;
            const n = s.read(&body) catch 0;
            d.open_err = dupe(wire.hostError(a, s.head.status, body[0..n]));
            s.close();
        } else {
            d.stream = s;
            if (s.head.header("content-length")) |v| d.bytes = std.fmt.parseInt(u64, std.mem.trim(u8, v, " "), 10) catch null;
        }
        mainloop.post(DlOpened{ .d = d }, DlOpened.run);
    }

    const DlOpened = struct {
        d: *Download,
        fn run(p: *DlOpened) void {
            const d = p.d;
            d.opened = true;
            const b = d.browser_shared.browser;
            if (b) |ptr| {
                const self = from(ptr);
                if (d.open_err) |e| {
                    self.connLog(.warn, "download interrupted", .{ .file = d.file, .@"error" = e });
                    self.status("download failed: {s}: {s}", .{ d.file, e });
                } else {
                    self.connLog(.info, "download started", .{ .file = d.file, .bytes = d.bytes });
                }
            }
            downloadProgress(d);
        }
    };

    /// Both halves (the response head and the user's choice) are in:
    /// stream to the chosen file, or finish.
    fn downloadProgress(d: *Download) void {
        if (!d.opened or !d.decided) return;
        const b = d.browser_shared.browser;
        const self: ?*Self = if (b) |ptr| from(ptr) else null;
        if (d.open_err != null) {
            if (self) |s| s.private().downloads -= 1;
            d.destroy();
            return;
        }
        if (d.cancelled or d.dest == null) {
            if (self) |s| {
                s.connLog(.warn, "download cancelled", .{ .file = d.file });
                s.status("download cancelled: {s}", .{d.file});
                s.private().downloads -= 1;
            }
            d.destroy();
            return;
        }
        const t = std.Thread.spawn(.{}, downloadStream, .{d}) catch {
            if (self) |s| s.private().downloads -= 1;
            d.destroy();
            return;
        };
        t.detach();
    }

    fn downloadStream(d: *Download) void {
        const io = global.io();
        const dest = d.dest.?;
        var ok = false;
        blk: {
            // An exclusive temporary file next to the destination; nothing
            // that already exists is opened, truncated or replaced, except
            // the destination itself once the download is complete
            // (savefile.zig).
            var tmp = savefile.create(alloc, io, dest) catch |err| {
                d.fail = savefile.reason(err);
                break :blk;
            };
            var buf: [64 * 1024]u8 = undefined;
            var w = tmp.file.writer(io, &buf);
            const n = d.stream.?.streamTo(&w.interface) catch |err| {
                // A write error is the local disk's; anything else is the
                // connection to the host.
                d.fail = if (err == error.WriteFailed)
                    (if (w.err) |we| savefile.reason(we) else "write failed")
                else
                    "connection lost";
                tmp.discard(alloc, io);
                break :blk;
            };
            if (d.bytes) |want_n| if (n != want_n) {
                d.fail = "connection lost";
                tmp.discard(alloc, io);
                break :blk;
            };
            tmp.commit(alloc, io, dest) catch |err| {
                d.fail = savefile.reason(err);
                break :blk;
            };
            ok = true;
        }
        mainloop.post(DlDone{ .d = d, .ok = ok }, DlDone.run);
    }

    const DlDone = struct {
        d: *Download,
        ok: bool,
        fn run(p: *DlDone) void {
            const d = p.d;
            defer d.destroy();
            const b = d.browser_shared.browser orelse return;
            const self = from(b);
            self.private().downloads -= 1;
            if (p.ok) {
                self.connLog(.info, "download saved", .{ .file = d.file, .path = d.dest.? });
                iface.services.setDownloadDir(self.private().conn_name, std.fs.path.dirname(d.dest.?) orelse "/");
            } else {
                const why = d.fail orelse "unknown error";
                self.connLog(.warn, "download interrupted", .{ .file = d.file, .@"error" = why });
                self.status("download failed: {s}: {s}", .{ d.file, why });
            }
        }
    };

    fn saveDialog(self: *Self, d: *Download) void {
        const priv = self.private();
        // The application name the chooser needs (D7) is set at startup.
        const dialog = gtk.FileDialog.new();
        defer dialog.unref();
        dialog.setTitle("Save file");
        dialog.setModal(1);
        const name_z = dupeZ(d.file);
        defer alloc.free(name_z);
        dialog.setInitialName(name_z.ptr);
        // The folder this connection last saved to, if it still exists;
        // else, as the Electron client's first save, the user's download
        // folder (XDG, else ~/Downloads), else the home folder. Never the
        // process's working directory (GTK's default).
        var folder_buf: [4096]u8 = undefined;
        const folder_path: ?[]const u8 = blk: {
            if (iface.services.downloadDir(priv.conn_name)) |last| if (isDir(last)) break :blk last;
            if (glib.getUserSpecialDir(.directory_download)) |xdg| if (isDir(std.mem.span(xdg))) break :blk std.mem.span(xdg);
            const home_dir = std.mem.span(glib.getHomeDir());
            if (std.fmt.bufPrint(&folder_buf, "{s}/Downloads", .{home_dir})) |dl| {
                if (isDir(dl)) break :blk dl;
            } else |_| {}
            if (isDir(home_dir)) break :blk home_dir;
            break :blk null;
        };
        if (folder_path) |fp| {
            const fz = dupeZ(fp);
            defer alloc.free(fz);
            const folder = gio.File.newForPath(fz.ptr);
            defer folder.unref();
            dialog.setInitialFolder(folder);
            if (priv.last_dialog_folder) |old| alloc.free(old);
            priv.last_dialog_folder = dupe(fp);
        }
        const cancellable = gio.Cancellable.new();
        if (priv.last_dialog) |old| old.unref();
        priv.last_dialog = cancellable;
        _ = cancellable.ref();
        const win: ?*gtk.Window = if (self.as(gtk.Widget).getRoot()) |r| gobject.ext.cast(gtk.Window, r) else null;
        const ctx = alloc.create(DialogCtx) catch return;
        ctx.* = .{ .d = d, .cancellable = cancellable };
        dialog.save(win, cancellable, onSaveDone, ctx);
    }

    fn isDir(p: []const u8) bool {
        const st = std.Io.Dir.cwd().statFile(global.io(), p, .{}) catch return false;
        return st.kind == .directory;
    }

    pub fn lastDialogFolder(self: *Self) ?[]const u8 {
        return self.private().last_dialog_folder;
    }

    const DialogCtx = struct { d: *Download, cancellable: *gio.Cancellable };

    fn onSaveDone(src: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const ctx: *DialogCtx = @ptrCast(@alignCast(data.?));
        defer {
            ctx.cancellable.unref();
            alloc.destroy(ctx);
        }
        const d = ctx.d;
        const dialog: *gtk.FileDialog = @ptrCast(src.?);
        var gerr: ?*glib.Error = null;
        const file = dialog.saveFinish(res, &gerr);
        if (gerr) |e| e.free();
        d.decided = true;
        if (file) |f| {
            defer f.unref();
            if (f.getPath()) |p| {
                defer glib.free(p);
                d.dest = dupe(std.mem.span(p));
            } else d.cancelled = true;
        } else d.cancelled = true;
        downloadProgress(d);
    }

    /// Cancel an open save dialog (control socket).
    pub fn cancelDialog(self: *Self) bool {
        const c = self.private().last_dialog orelse return false;
        c.cancel();
        return true;
    }

    pub fn pendingDownloads(self: *Self) u32 {
        return self.private().downloads;
    }

    // --- GObject ------------------------------------------------------------------

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.* = .{};
        const widget = self.as(gtk.Widget);
        widget.setFocusable(1);
        widget.setOverflow(.hidden);

        priv.overlay = gtk.Overlay.new();
        priv.scroller = gtk.ScrolledWindow.new();
        priv.scroller.setPolicy(.automatic, .never);
        // Scrollbars take their own space, as the Electron client's do;
        // overlay indicators sat on the last row (re-check N11).
        priv.scroller.setOverlayScrolling(0);
        scrolling.install(priv.scroller, true);
        const hadj = priv.scroller.getHadjustment();
        _ = gtk.Adjustment.signals.changed.connect(hadj, *Self, onHadjChanged, self, .{});
        _ = gtk.Adjustment.signals.value_changed.connect(hadj, *Self, onHadjValue, self, .{});
        // Dragging or clicking the strip's scrollbar is the user scrolling.
        {
            const bar = priv.scroller.getHscrollbar();
            const sg = gtk.GestureClick.new();
            sg.as(gtk.EventController).setPropagationPhase(.capture);
            _ = gtk.GestureClick.signals.pressed.connect(sg, *Self, onScrollbarPress, self, .{});
            bar.addController(sg.as(gtk.EventController));
        }
        priv.strip = gtk.Box.new(.horizontal, 0);
        priv.strip.as(gtk.Widget).setHalign(.start);
        priv.scroller.setChild(priv.strip.as(gtk.Widget));
        naturalScroll(priv.scroller);
        scrolling.noScrollToFocus(priv.scroller);
        priv.overlay.setChild(priv.scroller.as(gtk.Widget));
        priv.overlay.as(gtk.Widget).setParent(widget);

        const ec = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(ec, *Self, onKeyPressed, self, .{});
        widget.addController(ec.as(gtk.EventController));

        const fc = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(fc, *Self, onFocusEnter, self, .{});
        _ = gtk.EventControllerFocus.signals.leave.connect(fc, *Self, onFocusLeave, self, .{});
        widget.addController(fc.as(gtk.EventController));

        const sc = gtk.EventControllerScroll.new(.{ .vertical = true, .horizontal = true });
        sc.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerScroll.signals.scroll_begin.connect(sc, *Self, onScrollBegin, self, .{});
        _ = gtk.EventControllerScroll.signals.scroll.connect(sc, *Self, onScroll, self, .{});
        priv.scroller.as(gtk.Widget).addController(sc.as(gtk.EventController));

        // A click on empty space focuses the browser.
        const gc = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(gc, *Self, onAnyPress, self, .{});
        widget.addController(gc.as(gtk.EventController));

        // Light/dark palette: a CSS class following libadwaita's scheme.
        const sm = adw.StyleManager.getDefault();
        priv.scheme_handler = gobject.Object.signals.notify.connect(sm, *Self, onDarkChanged, self, .{ .detail = "dark" });
        self.applyScheme();

        _ = gtk.Widget.signals.map.connect(widget, *Self, onMap, self, .{});
        _ = gtk.Widget.signals.unmap.connect(widget, *Self, onUnmap, self, .{});

        // Debug aid: WEBMUX_FILES_FRAME_PROBE=1 logs frames that took long.
        if (std.c.getenv("WEBMUX_FILES_FRAME_PROBE") != null) _ = widget.addTickCallback(probeTick, null, null);

        // F-54: anywhere else in the browser: the rightmost directory.
        self.addDropTarget(priv.scroller.as(gtk.Widget), .browser);
    }

    fn applyScheme(self: *Self) void {
        const dark = adw.StyleManager.getDefault().getDark() != 0;
        if (dark) self.as(gtk.Widget).removeCssClass("light") else self.as(gtk.Widget).addCssClass("light");
    }

    fn onDarkChanged(_: *adw.StyleManager, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.applyScheme();
        // Inline-code colours in rendered markdown are baked in at build time.
        if (self.previewCol()) |col| {
            if (col.pv.rendered_md) self.fillPreviewBody(col);
        }
    }

    var probe_last: i64 = 0;
    fn probeTick(_: *gtk.Widget, clock: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
        const now = glib.getMonotonicTime();
        if (probe_last != 0 and now - probe_last > 50_000) log.debug("frame gap {d} ms (frame time {d})", .{ @divTrunc(now - probe_last, 1000), clock.getFrameTime() });
        probe_last = now;
        return 1;
    }

    fn onAnyPress(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Self) callconv(.c) void {
        if (self.private().rename != null or self.private().confirm != null) return;
        if (!self.containsFocus()) _ = self.as(gtk.Widget).grabFocus();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        // F-60: close every watch stream; in-flight results are dropped.
        priv.shared.browser = null;
        if (priv.scheme_handler != 0) {
            gobject.signalHandlerDisconnect(adw.StyleManager.getDefault().as(gobject.Object), priv.scheme_handler);
            priv.scheme_handler = 0;
        }
        for (priv.watchers.items) |w| w.stop();
        priv.watchers.clearRetainingCapacity();
        if (priv.watch_timer != 0) {
            _ = glib.Source.remove(priv.watch_timer);
            priv.watch_timer = 0;
        }
        if (priv.rows_idle != 0) {
            _ = glib.Source.remove(priv.rows_idle);
            priv.rows_idle = 0;
        }
        if (priv.tick_id != 0) {
            self.as(gtk.Widget).removeTickCallback(priv.tick_id);
            priv.tick_id = 0;
        }
        self.disconnectWindow();
        if (priv.last_dialog) |c| {
            c.cancel();
            c.unref();
            priv.last_dialog = null;
        }
        if (priv.confirm) |c| {
            priv.confirm = null;
            alloc.free(c.text);
            alloc.free(c.name);
            alloc.free(c.dir);
            for (c.entries) |e| alloc.free(e);
            alloc.free(c.entries);
            alloc.destroy(c);
        }
        if (priv.rename) |r| {
            priv.rename = null;
            freeRename(r);
        }
        for (priv.cols.items) |c| c.destroy();
        priv.cols.clearRetainingCapacity();
        for (priv.leaving.items) |c| c.destroy();
        priv.leaving.clearRetainingCapacity();
        priv.overlay.as(gtk.Widget).unparent();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.shared.release();
        priv.cols.deinit(alloc);
        priv.leaving.deinit(alloc);
        priv.watchers.deinit(alloc);
        var it = priv.cache.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.l.unref();
            alloc.free(kv.key_ptr.*);
        }
        priv.cache.deinit(alloc);
        var fi = priv.inflight.keyIterator();
        while (fi.next()) |k| alloc.free(k.*);
        priv.inflight.deinit(alloc);
        var mi = priv.memory.iterator();
        while (mi.next()) |kv| {
            alloc.free(kv.key_ptr.*);
            alloc.free(kv.value_ptr.*);
        }
        priv.memory.deinit(alloc);
        alloc.free(priv.id);
        alloc.free(priv.conn_name);
        alloc.free(priv.dir);
        if (priv.cursor) |c| alloc.free(c);
        if (priv.home) |h| alloc.free(h);
        if (priv.drilled) |d| alloc.free(d);
        if (priv.rightmost) |r| alloc.free(r);
        if (priv.title) |t| alloc.free(t);
        if (priv.open_failed) |e| alloc.free(e);
        if (priv.last_status) |s| alloc.free(s);
        if (priv.last_dialog_folder) |s| alloc.free(s);
        if (priv.measure) |m| m.unref();
        var nw = priv.name_widths.keyIterator();
        while (nw.next()) |k| alloc.free(k.*);
        priv.name_widths.deinit(alloc);
        priv.char_widths.deinit(alloc);
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
            gtk.Widget.Class.setCssName(class.as(gtk.Widget.Class), "filesbrowser");
            gtk.Widget.Class.setLayoutManagerType(class.as(gtk.Widget.Class), gtk.BinLayout.getGObjectType());
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gobject.ext.ensureType(Clip);
        }
    };
};

const mainloop = @import("../mainloop.zig");

