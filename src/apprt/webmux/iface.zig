//! The seams between the shell's feature areas. Written by the lead; every
//! feature codes against this file so the areas can be built in parallel
//! and wired together afterwards. Changing it needs the lead: describe the
//! change you need in your report instead of editing it.
//!
//! Everything here is main-thread only unless it says otherwise.
//!
//!   chrome (window, header, connection page)
//!     └─ per connection: a workspace (the strip of columns)
//!          └─ panes, created through a PaneFactory:
//!               terminal panes (TerminalPane + termio.Webmux)
//!               file-browser panes
//!
//! The chrome owns connections and hands each workspace a `Conn`. The
//! workspace owns layout, sessions (create/delete/list) and pane chrome
//! (title bar, close button, focus border, fade, dividers). A pane owns
//! only what is inside its rectangle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gtk = @import("gtk");
const conn = @import("../../webmux/conn.zig");
const layout = @import("../../webmux/layout.zig");

/// What a feature needs to know about the connection it lives in. The
/// strings stay valid for as long as the workspace built for this
/// connection exists.
pub const Conn = struct {
    /// Local unix socket of the host's HTTP server: the ssh tunnel's local
    /// end, or a directly reachable socket in dev mode. Everything (HTTP
    /// API, session WebSockets, SSE) connects here.
    socket_path: [:0]const u8,
    /// `conn.hostSlug` of the profile's host+instance: the key for
    /// per-host state (`layout.persist.statePath`).
    slug: []const u8,
    /// Profile name, for log lines and messages.
    name: []const u8,
};

pub const PaneKind = layout.Kind;

/// Calls from a pane up to its container.
pub const PaneHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The pane's title changed; read it with `Pane.title`.
        titleChanged: *const fn (ctx: *anyopaque, id: []const u8) void,
        /// The pane asks to be removed (its session exited or no longer
        /// exists). The container removes it from an idle callback, never
        /// from inside this call.
        closeRequested: *const fn (ctx: *anyopaque, id: []const u8) void,
        /// The pane's persistable state changed (`Pane.saveState`); the
        /// container schedules a save of the layout file.
        stateChanged: *const fn (ctx: *anyopaque, id: []const u8) void,
        /// Keyboard focus entered the pane (click, tab, programmatic).
        focusEntered: *const fn (ctx: *anyopaque, id: []const u8) void,
        /// The pane's link to the host went down (`false`) or came back
        /// (`true`). Terminal panes only.
        linkChanged: *const fn (ctx: *anyopaque, id: []const u8, up: bool) void,
    };

    pub fn titleChanged(self: PaneHost, id: []const u8) void {
        self.vtable.titleChanged(self.ctx, id);
    }
    pub fn closeRequested(self: PaneHost, id: []const u8) void {
        self.vtable.closeRequested(self.ctx, id);
    }
    pub fn stateChanged(self: PaneHost, id: []const u8) void {
        self.vtable.stateChanged(self.ctx, id);
    }
    pub fn focusEntered(self: PaneHost, id: []const u8) void {
        self.vtable.focusEntered(self.ctx, id);
    }
    pub fn linkChanged(self: PaneHost, id: []const u8, up: bool) void {
        self.vtable.linkChanged(self.ctx, id, up);
    }
};

/// A pane as its container sees it. `widget` is a new widget the container
/// parents (and thereby owns); removing it from the container destroys the
/// pane. The container draws everything around it.
pub const Pane = struct {
    widget: *gtk.Widget,
    ctx: *anyopaque,
    vtable: *const VTable,

    /// A rectangle in the pane widget's coordinates.
    pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

    pub const VTable = struct {
        /// Move keyboard focus into the pane.
        grabFocus: *const fn (ctx: *anyopaque) void,
        /// Current title, or null if the pane has none yet (the container
        /// then shows the pane id). Valid until control returns to the
        /// main loop.
        title: *const fn (ctx: *anyopaque) ?[:0]const u8,
        /// The pane's state to persist with the layout, as the text of one
        /// JSON object, or null for none. Caller frees with `alloc`.
        saveState: *const fn (ctx: *anyopaque, alloc: Allocator) Allocator.Error!?[]u8,
        /// The container is hiding (`false`) or showing (`true`) the pane
        /// without unparenting it, e.g. another pane is full-window or
        /// another host is in front. Lets a terminal pause rendering.
        setShown: *const fn (ctx: *anyopaque, shown: bool) void,
        /// Width of one terminal cell in device pixels at the current
        /// font and scale, or null if this pane cannot say (file
        /// browsers). The width rule needs one terminal's answer.
        cellWidthPx: *const fn (ctx: *anyopaque) ?u32,
        /// The container's unfocused fade: every pixel of the pane is to
        /// show as `scale * pixel + add` per colour channel (scale 1, add
        /// 0: no fade). A pane that covers part of its widget with opaque
        /// pixels of its own, and can apply the fade to them for less
        /// than a blended quad on top, does so and returns that part (a
        /// terminal: its texture, faded in the pass that draws it). The
        /// container then draws no background under that part and fades
        /// only the rest. Null: the container paints the background under
        /// the whole pane and fades all of it. Called whenever the fade
        /// changes and on every draw of the container.
        fade: *const fn (ctx: *anyopaque, scale: f32, add: [3]f32) ?Rect,
        /// The container is moving the pane to a new size (`true`) and
        /// has arrived (`false`). The widget is allocated its final size
        /// when the move starts; a pane for which taking a new size is
        /// expensive (a terminal: new buffers, a full re-render, a resize
        /// sent to the host) keeps drawing at its old size until the move
        /// ends and takes the new one then, once, so that work does not
        /// compete with the animation's frames.
        holdResize: *const fn (ctx: *anyopaque, hold: bool) void,
    };

    pub fn grabFocus(self: Pane) void {
        self.vtable.grabFocus(self.ctx);
    }
    pub fn title(self: Pane) ?[:0]const u8 {
        return self.vtable.title(self.ctx);
    }
    pub fn saveState(self: Pane, alloc: Allocator) Allocator.Error!?[]u8 {
        return self.vtable.saveState(self.ctx, alloc);
    }
    pub fn setShown(self: Pane, shown: bool) void {
        self.vtable.setShown(self.ctx, shown);
    }
    pub fn cellWidthPx(self: Pane) ?u32 {
        return self.vtable.cellWidthPx(self.ctx);
    }
    pub fn fade(self: Pane, scale: f32, add: [3]f32) ?Rect {
        return self.vtable.fade(self.ctx, scale, add);
    }
    pub fn holdResize(self: Pane, hold: bool) void {
        self.vtable.holdResize(self.ctx, hold);
    }
};

/// How a workspace gets panes. One factory per pane kind, registered by
/// the feature that implements the kind (see `factories`).
pub const PaneFactory = struct {
    /// Create a pane.
    ///   id     the layout's pane id: for terminals the host's session id
    ///          (the session already exists), for file browsers the
    ///          `files-…` id the layout model generated.
    ///   state  the JSON object text saved by `Pane.saveState` in an
    ///          earlier run, or null. Untrusted input.
    create: *const fn (
        c: *const Conn,
        id: []const u8,
        state: ?[]const u8,
        host: PaneHost,
    ) anyerror!Pane,
};

/// Pane factories by kind. Each pane feature sets its entry from its own
/// `register()` (called at application start, like control commands).
/// A workspace asked for a kind with no factory shows a placeholder.
pub const factories = struct {
    pub var terminal: ?PaneFactory = null;
    pub var files: ?PaneFactory = null;

    pub fn get(kind: PaneKind) ?PaneFactory {
        return switch (kind) {
            .terminal => terminal,
            .files => files,
        };
    }
};

/// How the chrome gets the widget that fills a connection's view. Set by
/// the workspace feature's `register()`.
pub const WorkspaceFactory = struct {
    /// Create the workspace for a connection that just became reachable.
    /// The returned widget is parented by the chrome; destroying it tears
    /// down every pane (sessions keep running on the host).
    create: *const fn (c: *const Conn, host: WorkspaceHost) anyerror!Workspace,
};
pub var workspace_factory: ?WorkspaceFactory = null;

/// Calls from a workspace up to the chrome.
pub const WorkspaceHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Pane count or link health changed: `panes` is the number of
        /// panes of every kind. `offline` (the header pill turns amber) is
        /// set when any terminal's session socket drops and cleared when
        /// any socket opens, as app.js setLinkDown does: it is not "while
        /// any link is down" (one socket reopening clears it even if
        /// another is still retrying).
        summaryChanged: *const fn (ctx: *anyopaque, panes: usize, offline: bool) void,
        /// The workspace's minimap (`Workspace.minimap`) would look
        /// different: its layout, geometry, scroll or focus changed. Called
        /// once per frame while the strip scrolls; the chrome redraws the
        /// host's pill.
        viewportChanged: *const fn (ctx: *anyopaque) void,
    };

    pub fn summaryChanged(self: WorkspaceHost, panes: usize, offline: bool) void {
        self.vtable.summaryChanged(self.ctx, panes, offline);
    }
    pub fn viewportChanged(self: WorkspaceHost) void {
        self.vtable.viewportChanged(self.ctx);
    }
};

/// A workspace's panes as a small block diagram, for its host's pill in
/// the header (deviation 73): one box per pane, columns and stacks roughly
/// to proportion, the focused pane marked, and, while the strip scrolls,
/// the on-screen part outlined. Coordinates are in pixels, y down, from
/// the map's top-left; the workspace computes it, the chrome draws it.
pub const Minimap = struct {
    pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };
    pub const Cell = struct {
        /// The pane id (owned by the map).
        id: []u8,
        rect: Rect,
        focused: bool,
    };

    cells: []Cell,
    /// The on-screen part of the strip; null when every column fits.
    viewport: ?Rect,
    width: f64,
    height: f64,

    pub const empty: Minimap = .{ .cells = &.{}, .viewport = null, .width = 0, .height = 0 };

    pub fn deinit(self: *Minimap, gpa: Allocator) void {
        for (self.cells) |c| gpa.free(c.id);
        gpa.free(self.cells);
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Minimap) bool {
        return self.cells.len == 0;
    }

    /// The pane under a point (with a 1 px halo around each box), or null.
    pub fn paneAt(self: *const Minimap, x: f64, y: f64) ?[]const u8 {
        for (self.cells) |c| {
            const r = c.rect;
            if (x >= r.x - 1 and x <= r.x + r.w + 1 and y >= r.y - 1 and y <= r.y + r.h + 1) return c.id;
        }
        return null;
    }
};

pub const Workspace = struct {
    widget: *gtk.Widget,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The connection's view came to the front (`true`) or went
        /// behind another (`false`).
        setFront: *const fn (ctx: *anyopaque, front: bool) void,
        /// Give keyboard focus to the workspace's focused pane.
        grabFocus: *const fn (ctx: *anyopaque) void,
        /// The host's sessions were restarted (Restart Sessions) or the
        /// tunnel came back after the server was replaced: re-read the
        /// session list and reconcile.
        reload: *const fn (ctx: *anyopaque) void,
        /// The pane map for the host's pill, `height` px tall and at most
        /// `max_width` wide, from the current layout, geometry, scroll and
        /// focus. A workspace that has never been laid out (its host has
        /// not been in front yet) is mapped at a typical window size.
        /// Empty while the layout has no panes. Caller frees with `gpa`.
        minimap: *const fn (ctx: *anyopaque, gpa: Allocator, height: f64, max_width: f64) Allocator.Error!Minimap,
        /// Focus a pane by id, as a click on its title bar would (ring,
        /// fade, reveal, keyboard focus). Unknown ids are ignored.
        focusPane: *const fn (ctx: *anyopaque, id: []const u8) void,
    };

    pub fn setFront(self: Workspace, front: bool) void {
        self.vtable.setFront(self.ctx, front);
    }
    pub fn grabFocus(self: Workspace) void {
        self.vtable.grabFocus(self.ctx);
    }
    pub fn reload(self: Workspace) void {
        self.vtable.reload(self.ctx);
    }
    pub fn minimap(self: Workspace, gpa: Allocator, height: f64, max_width: f64) Allocator.Error!Minimap {
        return self.vtable.minimap(self.ctx, gpa, height, max_width);
    }
    pub fn focusPane(self: Workspace, id: []const u8) void {
        self.vtable.focusPane(self.ctx, id);
    }
};

/// The connection engine (profiles, tunnels, settings store, connection
/// log). Created and owned by the chrome at application start; null before
/// that, and null in dev mode unless something creates one. Read-mostly
/// for other features: the panels read and write settings and tail the log
/// through it; nobody but the chrome connects or edits profiles.
pub var engine: ?*conn.Engine = null;

/// Optional cross-feature hooks. Each is set by the feature that
/// implements it and called by whoever observes the trigger; a null hook
/// is skipped.
pub const hooks = struct {
    /// Mirror the local clipboard's image, if it holds one, into the
    /// host's clipboard slot (`clipboard-sync`). Implemented by the
    /// terminal feature (it needs a live session socket of that
    /// connection); called by the chrome when the window gains focus and
    /// when the front connection changes, with the front connection.
    pub var clipboardSync: ?*const fn (c: *const Conn) void = null;
};

/// Action names that cross feature boundaries. The owner registers the
/// GAction; others activate it by name (activating a missing action does
/// nothing, so areas can be developed apart).
///
///   pane.<command>   on the workspace widget: one action per
///                    `layout.Command` name (`pane.new-terminal`,
///                    `pane.close-pane`, …), activated by the workspace's own
///                    shortcuts and by the chrome's header buttons and
///                    Pane menu on the front workspace.
///   app.show-settings, app.show-log
///                    registered by the panels; activated by the chrome's
///                    menu and shortcuts.
///   app.show-connections, app.reconnect, app.host-<n>, app.host-next,
///   app.host-prev    registered by the chrome.
pub const actions = struct {
    pub const pane_group = "pane";
    pub const show_settings = "app.show-settings";
    pub const show_log = "app.show-log";
    pub const show_connections = "app.show-connections";
};

/// Client-wide settings (colour scheme, unfocused fade, column widths).
/// The chrome's settings panel owns writes (and persists them through the
/// conn engine); everything else reads and subscribes.
pub const settings = struct {
    pub const Listener = struct {
        ctx: *anyopaque,
        changed: *const fn (ctx: *anyopaque, new: *const conn.Settings) void,
    };

    var current: conn.Settings = .{};
    var listeners: [32]?Listener = @splat(null);

    pub fn get() conn.Settings {
        return current;
    }

    /// Replace the settings and notify every subscriber. Chrome only.
    pub fn set(new: conn.Settings) void {
        current = new;
        for (listeners) |maybe| {
            if (maybe) |l| l.changed(l.ctx, &current);
        }
    }

    /// Returns false if the table is full (a bug: raise the size).
    pub fn subscribe(l: Listener) bool {
        for (&listeners) |*slot| {
            if (slot.* == null) {
                slot.* = l;
                return true;
            }
        }
        return false;
    }

    pub fn unsubscribe(ctx: *anyopaque) void {
        for (&listeners) |*slot| {
            if (slot.*) |l| {
                if (l.ctx == ctx) slot.* = null;
            }
        }
    }
};

/// Shell-wide services the chrome provides and any feature may call. The
/// defaults only log, so a feature can be developed before the chrome
/// exists.
pub const services = struct {
    const log = std.log.scoped(.webmux_services);

    pub const UrlAction = enum {
        /// Open in the default browser (a plain click on a link).
        open,
        /// Copy to the clipboard (shift-click).
        copy,
        /// Ask with the open/copy chooser (a program on the host asked
        /// for a browser; nobody clicked).
        choose,
    };

    pub const LogLevel = enum { debug, info, warn, @"error" };

    /// Show a transient status message (the Electron client's status
    /// line: clipboard syncs, upload progress, errors). `conn_name` is the
    /// profile name of the connection it comes from (a host's message
    /// shows while that host is in front, as each Electron host page has
    /// its own status line), or null for an app-wide message (always
    /// shown). Same argument order as `connLog`.
    pub var status: *const fn (conn_name: ?[]const u8, text: []const u8) void = defaultStatus;

    /// Act on a URL. `parent` is the widget the chooser is centred on.
    pub var url: *const fn (target: []const u8, action: UrlAction, parent: ?*gtk.Widget) void = defaultUrl;

    /// Append to the connection log, as the Electron pages do with
    /// `POST /log`. `conn_name` is the profile name; `data` is the text of
    /// a JSON object with extra fields, or null.
    pub var connLog: *const fn (level: LogLevel, conn_name: ?[]const u8, msg: []const u8, data: ?[]const u8) void = defaultConnLog;

    /// The folder the last download for this connection was saved to (the
    /// next save dialog opens there), or null. The slice is valid until
    /// control returns to the main loop.
    pub var downloadDir: *const fn (conn_name: []const u8) ?[]const u8 = defaultDownloadDir;

    /// Remember the folder a download for this connection was saved to.
    pub var setDownloadDir: *const fn (conn_name: []const u8, dir: []const u8) void = defaultSetDownloadDir;

    fn defaultDownloadDir(conn_name: []const u8) ?[]const u8 {
        _ = conn_name;
        return null;
    }
    fn defaultSetDownloadDir(conn_name: []const u8, dir: []const u8) void {
        log.info("download dir [{s}]: {s}", .{ conn_name, dir });
    }

    fn defaultStatus(conn_name: ?[]const u8, text: []const u8) void {
        _ = conn_name;
        log.info("status: {s}", .{text});
    }
    fn defaultUrl(target: []const u8, action: UrlAction, parent: ?*gtk.Widget) void {
        _ = parent;
        log.info("url {t}: {s}", .{ action, target });
    }
    fn defaultConnLog(level: LogLevel, conn_name: ?[]const u8, msg: []const u8, data: ?[]const u8) void {
        log.info("connlog {t} [{s}] {s} {s}", .{ level, conn_name orelse "-", msg, data orelse "" });
    }
};
