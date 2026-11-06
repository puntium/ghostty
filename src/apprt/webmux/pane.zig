//! `WebmuxTerminalPane`: one terminal, backed by one Ghostty core surface.
//!
//! Adapted from src/apprt/gtk/class/surface.zig (Ghostty f54340ad): the
//! input, IME, mouse, scroll, focus, resize/scale, clipboard and cursor
//! handling are that file's, re-plumbed without its Blueprint template.
//! Dropped: splits/tabs/drag-and-drop, overlays (search, resize, key
//! state, URL hover, progress bar, read-only, child-exited), context menu,
//! title dialog, inspector, desktop notifications, scrollable interface,
//! clipboard confirmation dialog, error page.
//!
//! The widget tree:
//!
//!     WebmuxTerminalPane (adw.Bin; holds all event controllers)
//!       gtk.Overlay   (`overlay()`: put pane-local overlays here)
//!         [gtk.GraphicsOffload, only with WEBMUX_GTK_OFFLOAD=1]
//!           WebmuxRenderSurface (focusable; shows the renderer's frames)
//!       gtk.Box       (the 10 px scrollbar column) > gtk.Scrollbar
//!
//! The pane paints its own background: the render surface where its
//! texture does not reach, the scrollbar column through CSS. Nothing
//! needs to be drawn under it.
//!
//! Event coordinates are taken relative to the pane and handed to the core
//! as surface pixels, so the render surface must fill the pane: put chrome
//! (borders, headers) around the pane, not inside it.
//!
//! The core surface is created lazily on the first size allocation (the
//! pty/remote must start with the right grid size) and destroyed when the
//! pane is finalized. See WEBMUX.md › Embedding a pane.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const graphene = @import("graphene");

const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const build_options = @import("build_options");
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const global = @import("../../global.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const Common = @import("class.zig").Common;
const ApprtSurface = @import("Surface.zig");
const Application = @import("application.zig").Application;
const ConfigObject = @import("config_object.zig").Config;
const render_surface_mod = @import("render_surface.zig");
const RenderSurface = render_surface_mod.RenderSurface;
const KeyEvent = @import("key_event.zig").KeyEvent;
const gsettings = @import("gsettings.zig");
const gtk_key = @import("key.zig");
const remote = @import("terminal/remote.zig");
const links = @import("terminal/links.zig");
const xterm_keys = @import("terminal/xterm_keys.zig");
const xterm_sel = @import("terminal/selection.zig");
const terminal_clipboard = @import("terminal/clipboard.zig");
const iface = @import("iface.zig");
const alloc_c = std.heap.c_allocator;
const termio = @import("../../termio.zig");
const scale_util = @import("scale.zig");

const log = std.log.scoped(.webmux_pane);

pub const TerminalPane = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxTerminalPane",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The terminal title (OSC 0/2), or null before the first one.
        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };

        /// The working directory reported by the terminal (OSC 7).
        pub const pwd = struct {
            pub const name = "pwd";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("pwd"),
                },
            );
        };

        /// True while keyboard focus is inside the pane.
        pub const focused = struct {
            pub const name = "focused";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "focused",
                    ),
                },
            );
        };

        /// The URL under the mouse (link hover), or null.
        pub const @"mouse-hover-url" = struct {
            pub const name = "mouse-hover-url";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("mouse_hover_url"),
                },
            );
        };
    };

    pub const signals = struct {
        /// The pane wants to go away: the terminal closed (process exited,
        /// `exit`/`close_surface` binding). The container removes the pane;
        /// the pane never removes itself.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        /// BEL was received.
        pub const bell = struct {
            pub const name = "bell";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        /// A remote pane's link went up (1) or down (0). Not emitted for
        /// the initial connecting state.
        pub const @"link-changed" = struct {
            pub const name = "link-changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{c_int}, void);
        };

        /// The core surface exists (after the first size allocation).
        pub const ready = struct {
            pub const name = "ready";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };
    };

    /// Construction parameters.
    pub const Options = struct {
        /// Ghostty configuration; null uses the application's.
        config: ?*ConfigObject = null,
        /// Attach to this webmux session (termio.Webmux: no local
        /// process). Null runs a local shell (termio.Exec), the
        /// skeleton's placeholder.
        remote: ?remote.Target = null,
    };

    const Private = struct {
        config: ?*ConfigObject = null,

        overlay: *gtk.Overlay = undefined,
        render_surface: *RenderSurface = undefined,
        /// See `holdResize`.
        hold_resize: bool = false,
        pending_size: ?apprt.SurfaceSize = null,
        im_context: *gtk.IMMulticontext = undefined,

        rt_surface: ApprtSurface = undefined,
        core_surface: ?*CoreSurface = null,

        /// Cached metrics for libghostty callbacks.
        size: apprt.SurfaceSize = .{ .width = 0, .height = 0 },
        cursor_pos: apprt.CursorPos = .{ .x = 0, .y = 0 },

        title: ?[:0]const u8 = null,
        pwd: ?[:0]const u8 = null,
        mouse_hover_url: ?[:0]const u8 = null,
        mouse_shape: terminal.MouseShape = .text,
        mouse_hidden: bool = false,

        focused: bool = false,
        mapped: bool = false,

        /// Input method state, see `handleKey`.
        in_keyevent: IMKeyEvent = .false,
        im_composing: bool = false,
        im_buf: [128]u8 = undefined,
        im_len: u7 = 0,

        precision_scroll: bool = false,
        /// Touchpad scrolling of the viewport (`scroll`): CSS-pixel
        /// position since the viewport last moved otherwise, the lines
        /// already applied for it, and the scrollbar offset that left.
        touch_px: f64 = 0,
        touch_start: usize = 0,
        touch_offset: ?usize = null,
        /// Touchpad lines not yet sent as arrow keys or wheel reports
        /// (xterm `_wheelPartialScroll`), signed.
        touch_partial: f64 = 0,
        /// D-06: the cell boundary of the last plain left click (screen
        /// coordinates), for an xterm-style Shift+click with no selection;
        /// and whether the release of such a Shift+click is ours.
        click_anchor: ?xterm_sel.Boundary = null,
        shift_click_release: bool = false,
        /// O2: text pastes whose clipboard read is still in flight, and
        /// the typed input held back until they land (so a key typed
        /// right after Ctrl+V reaches the session after the pasted text,
        /// as in the browser, where the paste event carries the text).
        pastes_pending: u32 = 0,
        paste_generation: u32 = 0,
        paste_timeout_generation: u32 = 0,
        held_input: std.ArrayList(u8) = .empty,
        gtk_enable_primary_paste: bool = true,
        suppress_left_mouse_release: bool = false,

        /// Last values reported by the core, for embedders and `dump`.
        cell_size: apprt.action.CellSize = .{ .width = 0, .height = 0 },
        scrollbar: terminal.Scrollbar = .{ .total = 0, .offset = 0, .len = 0 },
        renderer_health: renderer.Health = .healthy,
        child_exited: bool = false,

        /// Set for panes attached to a webmux session.
        remote: ?*remote.State = null,
        /// False while the container hides the pane (`setShown`).
        shown: bool = true,

        /// The http(s) OSC 8 hyperlink under the pointer (owned).
        link_osc8: ?[:0]u8 = null,
        /// A left press on a link, waiting for its release (see
        /// `mouseMotion`).
        pending_link: ?PendingLink = null,
        /// Where the left button went down (for Alt+click).
        left_press: ?apprt.CursorPos = null,

        /// T-10: the 10px scrollbar column right of the terminal.
        scrollbar_widget: *gtk.Scrollbar = undefined,
        scrollbar_adj: *gtk.Adjustment = undefined,
        /// True while we update the adjustment from the core.
        scrollbar_syncing: bool = false,
        /// The dragged row a scrollbar snap jumped away from (see
        /// `scrollbarValueChanged`).
        scrollbar_snapped_from: ?usize = null,

        pub var offset: c_int = 0;
    };

    pub fn new(opts: Options) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        if (opts.config) |c| {
            if (priv.config) |old| old.unref();
            priv.config = c.ref();
        }
        if (opts.remote) |target| {
            priv.remote = remote.State.create(self, target) catch |err| r: {
                // Without it the pane falls back to nothing useful; make
                // that visible rather than silently running a local shell.
                log.err("cannot set up remote pane: {t}", .{err});
                break :r null;
            };
        }
        return self;
    }

    //---------------------------------------------------------------
    // Remote (webmux session) state

    /// Null for a local pane.
    pub fn remoteState(self: *Self) ?*remote.State {
        return self.private().remote;
    }

    /// The session this pane is attached to, or null for a local pane.
    pub fn sessionId(self: *Self) ?[:0]const u8 {
        const st = self.private().remote orelse return null;
        return st.session_id;
    }

    /// The profile name of the connection this pane's session is on, or
    /// null (no remote session).
    pub fn connName(self: *Self) ?[]const u8 {
        const st = self.private().remote orelse return null;
        return st.connName();
    }

    pub fn getLink(self: *Self) ?remote.Link {
        const st = self.private().remote orelse return null;
        return st.link;
    }

    /// Main thread (remote.zig). Emits `link-changed` on up/down changes.
    pub fn setLink(self: *Self, link: remote.Link) void {
        const st = self.private().remote orelse return;
        if (st.link == link) return;
        st.link = link;
        signals.@"link-changed".impl.emit(self, null, .{@as(c_int, @intFromBool(link == .up))}, null);
    }

    /// For Surface.termioBackend: the backend config of a remote pane.
    pub fn termioBackend(self: *Self) ?termio.Webmux.Config {
        const st = self.private().remote orelse return null;
        return st.backendConfig();
    }

    /// The container is hiding (false) or showing (true) the pane without
    /// unparenting it; a hidden terminal stops rendering.
    pub fn setShown(self: *Self, shown: bool) void {
        self.private().shown = shown;
        self.updateOcclusion();
    }

    //---------------------------------------------------------------
    // Public API (for containers and the control socket)

    pub fn core(self: *Self) ?*CoreSurface {
        return self.private().core_surface;
    }

    pub fn rt(self: *Self) *ApprtSurface {
        return &self.private().rt_surface;
    }

    /// The overlay wrapping the terminal, for pane-local overlays.
    pub fn overlay(self: *Self) *gtk.Overlay {
        return self.private().overlay;
    }

    pub fn renderSurface(self: *Self) *RenderSurface {
        return self.private().render_surface;
    }

    pub fn getTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }

    pub fn getPwd(self: *Self) ?[:0]const u8 {
        return self.private().pwd;
    }

    pub fn getFocused(self: *Self) bool {
        return self.private().focused;
    }

    pub fn getCellSize(self: *Self) apprt.action.CellSize {
        return self.private().cell_size;
    }

    pub fn getScrollbar(self: *Self) terminal.Scrollbar {
        return self.private().scrollbar;
    }

    pub fn getRendererHealth(self: *Self) renderer.Health {
        return self.private().renderer_health;
    }

    /// The grid size the shell last told the core (columns x rows).
    pub fn gridSize(self: *Self) ?renderer.GridSize {
        const surface = self.core() orelse return null;
        return surface.size.grid();
    }

    /// The centre of grid cell (col, row) in CSS px relative to the pane.
    pub fn cellCenter(self: *Self, col: u32, row: u32) ?struct { x: f64, y: f64 } {
        const surface = self.core() orelse return null;
        const scale = scale_util.widgetSurfaceScale(self.private().render_surface.as(gtk.Widget));
        const s = surface.size;
        const x = @as(f64, @floatFromInt(s.padding.left)) +
            (@as(f64, @floatFromInt(col)) + 0.5) * @as(f64, @floatFromInt(s.cell.width));
        const y = @as(f64, @floatFromInt(s.padding.top)) +
            (@as(f64, @floatFromInt(row)) + 0.5) * @as(f64, @floatFromInt(s.cell.height));
        return .{ .x = x / scale, .y = y / scale };
    }

    /// The render surface's top-left in its window (CSS px).
    pub fn windowOrigin(self: *Self) struct { x: f64, y: f64 } {
        const rs = self.private().render_surface.as(gtk.Widget);
        const root = rs.getNative() orelse return .{ .x = 0, .y = 0 };
        const root_w = gobject.ext.cast(gtk.Widget, root) orelse return .{ .x = 0, .y = 0 };
        var out: graphene.Point = undefined;
        if (rs.computePoint(root_w, &.{ .f_x = 0, .f_y = 0 }, &out) == 0) return .{ .x = 0, .y = 0 };
        return .{ .x = out.f_x, .y = out.f_y };
    }

    /// Move keyboard focus into the terminal.
    pub fn grabFocus(self: *Self) void {
        _ = self.private().render_surface.as(gtk.Widget).grabFocus();
    }

    /// Force a redraw (e.g. after the pane moved to another parent).
    pub fn redraw(self: *Self) void {
        self.private().render_surface.as(gtk.Widget).queueDraw();
    }

    /// Ask the core to close this terminal; ends in `close-request`.
    pub fn requestClose(self: *Self) void {
        const surface = self.core() orelse {
            signals.@"close-request".impl.emit(self, null, .{}, null);
            return;
        };
        surface.close();
    }

    /// The visible screen as text (one line per row, trailing blanks kept
    /// as the terminal has them). Caller frees.
    pub fn visibleText(self: *Self, alloc: Allocator) !?[]const u8 {
        const surface = self.core() orelse return null;
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        return try surface.io.terminal.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    }

    pub const TerminalState = struct {
        columns: usize,
        rows: usize,
        cursor_x: usize,
        cursor_y: usize,
    };

    /// The terminal's own grid and cursor (as the io thread has applied
    /// them; can lag `gridSize` briefly after a resize).
    pub fn terminalState(self: *Self) ?TerminalState {
        const surface = self.core() orelse return null;
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        const t = &surface.io.terminal;
        return .{
            .columns = t.cols,
            .rows = t.rows,
            .cursor_x = t.screens.active.cursor.x,
            .cursor_y = t.screens.active.cursor.y,
        };
    }

    //---------------------------------------------------------------
    // Keyboard

    /// Process a key event: input method first (real events only), then
    /// Ghostty's key encoding. Returns true if consumed. Shortcuts have
    /// already been matched by the window's capture-phase controller.
    ///
    /// The input-method dance below is the stock shell's; read the long
    /// comment on `keyEvent` in src/apprt/gtk/class/surface.zig before
    /// changing it.
    pub fn handleKey(self: *Self, ev: KeyEvent) bool {
        const priv = self.private();
        // Never log keyvals here: they are the user's keystrokes (passwords).

        // The pane's own keys (copy, paste variants, T-13) come before the
        // input method and the encoder.
        if (!priv.im_composing and self.paneKey(ev)) return true;

        if (ev.event) |event| {
            self.updateImePosition();
            priv.in_keyevent = if (priv.im_composing) .composing else .not_composing;
            defer priv.in_keyevent = .false;

            const im_handled = priv.im_context.as(gtk.IMContext).filterKeypress(event) != 0;
            if (im_handled) log.debug("key handled by input method composing={} im_len={d}", .{
                priv.im_composing, priv.im_len,
            });
            if (im_handled) {
                // Composing (dead key, preedit): no encoding.
                if (priv.im_composing) return true;
                // Composition just committed: the commit carried the text.
                if (priv.in_keyevent == .composing) return true;
                // Handled without text (e.g. emoji chooser opened).
                if (priv.im_len == 0) return true;
            }
        }

        defer priv.im_len = 0;

        const widget = priv.render_surface.as(gtk.Widget);
        const keyval_unicode = gdk.keyvalToUnicode(ev.keyval);
        const keyval_unicode_unshifted: u21 = if (ev.keycode != 0)
            gtk_key.keyvalUnicodeUnshiftedForLayout(widget, ev.layout, ev.keycode)
        else
            0;

        // The physical key, for physical keybinds and the encoder.
        const physical_key = keycode: {
            const w3c_key: input.Key = w3c: for (input.keycodes.entries) |entry| {
                if (entry.native == ev.keycode) break :w3c entry.key;
            } else .unidentified;

            break :keycode gtk_key.remapKey(w3c_key, ev.keyval, ev.is_modifier);
        };

        const mods: input.Mods = if (ev.event) |event|
            gtk_key.eventMods(event, physical_key, ev.state, ev.action)
        else
            gtk_key.eventModsFromState(physical_key, ev.state, ev.action);

        const consumed_mods: input.Mods = consumed: {
            const T = @typeInfo(gdk.ModifierType);
            std.debug.assert(T.@"struct".layout == .@"packed");
            const I = T.@"struct".backing_integer.?;
            const masked = @as(I, @bitCast(ev.consumed)) & @as(I, gdk.MODIFIER_MASK);
            break :consumed gtk_key.translateMods(@bitCast(masked));
        };

        // No IM text: derive it from the keyval (GTK gives none for e.g.
        // Ctrl+Shift+1); control characters are the encoder's job.
        if (priv.im_len == 0 and keyval_unicode > 0) im: {
            if (std.math.cast(u21, keyval_unicode)) |cp| {
                if (cp < 0x20) break :im;
                if (std.unicode.utf8Encode(cp, &priv.im_buf)) |len| {
                    priv.im_len = len;
                } else |_| {}
            }
        }

        // No Kitty keyboard protocol: xterm.js's bytes (ruling, T-12).
        if (!priv.im_composing) {
            if (self.encodeKey(ev, physical_key, priv.im_buf[0..priv.im_len])) |handled| return handled;
        }

        const surface = priv.core_surface orelse return false;
        const effect = surface.keyCallback(.{
            .action = ev.action,
            .key = physical_key,
            .mods = mods,
            .consumed_mods = consumed_mods,
            .composing = priv.im_composing,
            .utf8 = priv.im_buf[0..priv.im_len],
            .unshifted_codepoint = keyval_unicode_unshifted,
        }) catch |err| {
            log.err("error in key callback err={}", .{err});
            return false;
        };

        switch (effect) {
            .closed => return true,
            .ignored => {},
            .consumed => if (ev.action == .press or ev.action == .repeat) {
                if (priv.im_composing) {
                    priv.im_context.as(gtk.IMContext).reset();
                    surface.preeditCallback(null) catch {};
                }
                return true;
            },
        }

        return false;
    }

    /// Clipboard keys the pane handles itself, before the input method
    /// (after the window's shortcuts), as the Electron client does:
    ///   Ctrl+V         clipboard image → image paste; text → paste;
    ///                  nothing → a literal ^V (C-04)
    ///   Ctrl+Shift+V   paste, image included (C-05, ruling A-04)
    ///   Ctrl+Alt+V     always a literal ^V (T-16)
    ///   Shift+Insert   paste (Chromium's textarea pastes on it, D-02)
    ///   Ctrl+Shift+C, Ctrl+Insert   copy the selection (ruling A-03, D-02)
    /// Everything else is encoded after the input method (`encodeKey`).
    /// Press and release are both swallowed; the action runs on press.
    fn paneKey(self: *Self, ev: KeyEvent) bool {
        if (ev.is_modifier) return false;
        const st = ev.state;
        if (st.super_mask) return false;
        const press = ev.action != .release;
        const shift = st.shift_mask;
        const alt = st.alt_mask;
        const ctrl = st.control_mask;

        // Insert, by keysym (also KP_Insert with NumLock off).
        if (ev.keyval == 0xff63 or ev.keyval == 0xff9e) {
            if (shift and !ctrl and !alt) {
                if (press) {
                    terminal_clipboard.paste(self, .paste);
                    self.scrollToBottomOnInput();
                }
                return true;
            }
            if (ctrl and !shift and !alt) {
                if (press) _ = terminal_clipboard.copySelection(self);
                return true;
            }
            return false;
        }

        if (!ctrl) return false;
        const base = ev.baseKeyval(self.as(gtk.Widget).getDisplay());
        if (base == 'v') {
            if (!press) return true;
            if (alt and !shift) {
                terminal_clipboard.literalCtrlV(self);
            } else if (shift and !alt) {
                terminal_clipboard.paste(self, .paste);
            } else if (!shift and !alt) {
                terminal_clipboard.paste(self, .ctrl_v);
            } else return false;
            self.scrollToBottomOnInput();
            return true;
        }
        if (base == 'c' and shift and !alt) {
            if (press) _ = terminal_clipboard.copySelection(self);
            return true;
        }
        return false;
    }

    /// Copy the selection to CLIPBOARD (Ctrl+Shift+C, Edit › Copy).
    /// Returns false without a selection.
    pub fn copyToClipboard(self: *Self) bool {
        return terminal_clipboard.copySelection(self);
    }

    /// Paste as Ctrl+Shift+V does (Edit › Paste): an image on the
    /// clipboard takes the image-paste flow (C-06), text is pasted.
    pub fn pasteFromClipboard(self: *Self) void {
        terminal_clipboard.paste(self, .paste);
        self.scrollToBottomOnInput();
    }

    /// The xterm.js encoding of a key press when the app has not enabled
    /// the Kitty keyboard protocol (terminal/xterm_keys.zig). Returns null
    /// when Ghostty's encoder should handle it (Kitty protocol on, or a
    /// release).
    fn encodeKey(self: *Self, ev: KeyEvent, physical: input.Key, text: []const u8) ?bool {
        if (ev.action == .release) return null;
        const surface = self.core() orelse return null;
        const app_cursor = app: {
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());
            const t = surface.renderer_state.terminal;
            const flags = t.screens.active.kitty_keyboard.current();
            if (@as(u5, @bitCast(flags)) != 0) return null;
            break :app t.modes.get(.cursor_keys);
        };
        const base = ev.baseKeyval(self.as(gtk.Widget).getDisplay());
        const xev: xterm_keys.Event = .{
            .key_code = xterm_keys.keyCode(ev.keyval, base, physical),
            .key = text,
            .shift = ev.state.shift_mask,
            .alt = ev.state.alt_mask,
            .ctrl = ev.state.control_mask,
            .meta = ev.state.super_mask,
        };
        var buf: [32]u8 = undefined;
        switch (xterm_keys.evaluate(xev, app_cursor, &buf)) {
            .send => |bytes| self.sendInput(bytes),
            .none => {},
            .page_up => self.scrollPage(-1),
            .page_down => self.scrollPage(1),
        }
        return true;
    }

    /// Write bytes to the terminal as typed input (the `text:` binding:
    /// raw bytes to the backend, and the view snaps to the bottom, T-17).
    pub fn sendInput(self: *Self, bytes: []const u8) void {
        const priv = self.private();
        if (priv.pastes_pending > 0) {
            priv.held_input.appendSlice(alloc_c, bytes) catch {};
            return;
        }
        self.writeInput(bytes);
    }

    /// A text paste's clipboard read started (terminal/clipboard.zig).
    pub fn pasteBegin(self: *Self) void {
        const priv = self.private();
        priv.pastes_pending += 1;
        priv.paste_generation +%= 1;
        // A clipboard owner that never answers must not swallow typing.
        const Timeout = struct {
            fn run(ud: ?*anyopaque) callconv(.c) c_int {
                const pane: *Self = @ptrCast(@alignCast(ud.?));
                defer pane.unref();
                const pv = pane.private();
                if (pv.pastes_pending > 0 and pv.paste_generation == pane.timeoutGeneration()) {
                    log.warn("clipboard read still pending after 1 s; sending held input", .{});
                    pv.pastes_pending = 0;
                    pane.flushHeldInput();
                }
                return 0;
            }
        };
        priv.paste_timeout_generation = priv.paste_generation;
        _ = glib.timeoutAdd(1000, Timeout.run, self.ref());
    }

    fn timeoutGeneration(self: *Self) u32 {
        return self.private().paste_timeout_generation;
    }

    /// The paste's text (or ^V) has been written: send what was typed
    /// meanwhile.
    pub fn pasteEnd(self: *Self) void {
        const priv = self.private();
        if (priv.pastes_pending == 0) return;
        priv.pastes_pending -= 1;
        if (priv.pastes_pending == 0) self.flushHeldInput();
    }

    fn flushHeldInput(self: *Self) void {
        const priv = self.private();
        if (priv.held_input.items.len == 0) return;
        const held = priv.held_input.toOwnedSlice(alloc_c) catch return;
        defer alloc_c.free(held);
        self.writeInput(held);
    }

    fn writeInput(self: *Self, bytes: []const u8) void {
        const surface = self.core() orelse return;
        var esc: std.ArrayList(u8) = .empty;
        defer esc.deinit(alloc_c);
        for (bytes) |b| {
            if (b >= 0x20 and b < 0x7f and b != '\\') {
                esc.append(alloc_c, b) catch return;
            } else {
                esc.print(alloc_c, "\\x{x:0>2}", .{b}) catch return;
            }
        }
        _ = surface.performBindingAction(.{ .text = esc.items }) catch |err| {
            log.warn("cannot send input: {t}", .{err});
        };
    }

    /// Shift+PageUp/PageDown: scroll by rows - 1 (xterm `scrollPages`).
    fn scrollPage(self: *Self, dir: i32) void {
        const surface = self.core() orelse return;
        const rows: i32 = rows: {
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());
            break :rows @intCast(surface.renderer_state.terminal.rows);
        };
        const lines: i16 = @intCast(std.math.clamp(dir * @max(1, rows - 1), -32768, 32767));
        _ = surface.performBindingAction(.{ .scroll_page_lines = lines }) catch {};
        if (dir > 0) _ = self.snapToBottomIfNear();
    }

    fn kittyKeyboardActive(self: *Self) bool {
        const surface = self.core() orelse return false;
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        const flags = surface.renderer_state.terminal.screens.active.kitty_keyboard.current();
        return @as(u5, @bitCast(flags)) != 0;
    }

    /// Typing snaps the viewport to the bottom (T-17); the pane's own
    /// paste keys bypass the encoder, so do it here for them.
    fn scrollToBottomOnInput(self: *Self) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.scroll_to_bottom) catch {};
    }

    fn ecKeyPressed(
        ec: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const ev = KeyEvent.fromController(ec, .press, keyval, keycode, state) orelse return 0;
        return @intFromBool(self.handleKey(ev));
    }

    fn ecKeyReleased(
        ec: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) void {
        const ev = KeyEvent.fromController(ec, .release, keyval, keycode, state) orelse return;
        _ = self.handleKey(ev);
    }

    //---------------------------------------------------------------
    // Input method

    fn updateImePosition(self: *Self) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;

        // GTK wants widget coordinates: divide by the surface scale only.
        const surface_scale: f32 = @floatCast(scale_util.widgetSurfaceScale(
            priv.render_surface.as(gtk.Widget),
        ));
        const ime_point = surface.imePointScaled(.{ .x = surface_scale, .y = surface_scale });

        const top = @floor(ime_point.y - ime_point.height);
        const bottom = @ceil(ime_point.y);
        priv.im_context.as(gtk.IMContext).setCursorLocation(&.{
            .f_x = @intFromFloat(@floor(ime_point.x)),
            .f_y = @intFromFloat(top),
            .f_width = 1,
            .f_height = @intFromFloat(@max(1, bottom - top)),
        });
    }

    fn imPreeditStart(_: *gtk.IMMulticontext, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.im_composing = true;
        priv.im_len = 0;
        self.updateImePosition();
    }

    fn imPreeditChanged(ctx: *gtk.IMMulticontext, self: *Self) callconv(.c) void {
        const priv = self.private();
        // See the stock surface: fcitx5-hangul commits and keeps composing.
        priv.im_composing = true;
        const surface = priv.core_surface orelse return;

        var buf: [*:0]u8 = undefined;
        ctx.as(gtk.IMContext).getPreeditString(&buf, null, null);
        defer glib.free(buf);
        const str = std.mem.sliceTo(buf, 0);

        surface.preeditCallback(str) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
        self.updateImePosition();
    }

    fn imPreeditEnd(_: *gtk.IMMulticontext, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.im_composing = false;
        const surface = priv.core_surface orelse return;
        surface.preeditCallback(null) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }

    fn imCommit(_: *gtk.IMMulticontext, bytes: [*:0]u8, self: *Self) callconv(.c) void {
        const priv = self.private();
        const str = std.mem.sliceTo(bytes, 0);

        switch (priv.in_keyevent) {
            // Not in a key event (on-screen keyboard etc.) or a composition
            // finishing: commit below.
            .false, .composing => {},
            // Plain key: let handleKey encode it together with the key.
            .not_composing => {
                if (str.len > priv.im_buf.len) {
                    log.warn("not enough buffer space for input method commit", .{});
                    return;
                }
                @memcpy(priv.im_buf[0..str.len], str);
                priv.im_len = @intCast(str.len);
                return;
            },
        }

        priv.im_composing = false;
        if (priv.core_surface) |surface| {
            surface.preeditCallback(null) catch |err| {
                log.warn("error in preedit callback err={}", .{err});
            };
            _ = surface.keyCallback(.{
                .action = .press,
                .key = .unidentified,
                .mods = .{},
                .consumed_mods = .{},
                .composing = false,
                .utf8 = str,
            }) catch |err| {
                log.warn("error in key callback err={}", .{err});
            };
        }
    }

    //---------------------------------------------------------------
    // Focus

    fn ecFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.updateFocus(true);
    }

    fn ecFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.updateFocus(false);
    }

    fn updateFocus(self: *Self, focused: bool) void {
        const priv = self.private();
        priv.focused = focused;

        const ctx = priv.im_context.as(gtk.IMContext);
        if (focused) {
            self.updateImePosition();
            ctx.focusIn();
        } else {
            ctx.focusOut();
        }

        // The core callback must run on an idle tick: it can take locks
        // that are held during other libghostty callbacks.
        _ = glib.idleAddOnce(idleFocus, self.ref());
        self.as(gobject.Object).notifyByPspec(properties.focused.impl.param_spec);
    }

    fn idleFocus(ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        surface.focusCallback(priv.focused) catch |err| {
            log.warn("error in focus callback err={}", .{err});
        };
    }

    //---------------------------------------------------------------
    // Mouse

    fn scaledCoordinates(self: *Self, x: f64, y: f64) struct { x: f64, y: f64 } {
        const widget = self.private().render_surface;
        const scale_factor = scale_util.widgetSurfaceScale(widget.as(gtk.Widget));
        return .{ .x = x * scale_factor, .y = y * scale_factor };
    }

    /// The mouse logic shared by the GTK controllers and `injectMouse`.
    /// Positions are device pixels relative to the terminal.
    ///
    /// Links (T-24, T-25): a left press on an http(s) link (a URL Ghostty
    /// reports through `mouse_over_link`, or an OSC 8 hyperlink found here)
    /// is held back from the core. Released in the same cell it opens the
    /// link through `iface.services.url` (Shift: copies it); moved to
    /// another cell it is replayed to the core as an ordinary press, so a
    /// drag that starts on a link still selects.
    ///
    /// While the program has mouse reporting on, the press is its to see
    /// (T-19), so it goes to the core as usual and a release in the same
    /// cell opens the link as well, as xterm.js does. Shift takes the
    /// mouse back from the program, so Shift+click is held back and
    /// copies as above.
    fn mouseMotion(self: *Self, pos: apprt.CursorPos, mods: input.Mods) void {
        const priv = self.private();
        const surface = priv.core_surface orelse {
            priv.cursor_pos = pos;
            return;
        };
        if (priv.pending_link) |pl| {
            if (!self.sameCell(pl.pos, pos)) {
                const press_pos = pl.pos;
                const press_mods = pl.mods;
                const held = pl.held;
                self.clearPendingLink();
                // A drag, not a link click. If the core has not seen the
                // press, replay it. The core reads the press position from
                // getCursorPos, so the pointer goes back there first.
                if (held) {
                    priv.cursor_pos = press_pos;
                    surface.cursorPosCallback(press_pos, press_mods) catch {};
                    _ = surface.mouseButtonCallback(.press, .left, press_mods) catch false;
                    priv.left_press = press_pos;
                }
            }
        }
        priv.cursor_pos = pos;
        surface.cursorPosCallback(pos, mods) catch |err| {
            log.warn("error in cursor pos callback err={}", .{err});
        };
        self.updateOsc8Hover(pos);
    }

    fn mousePress(self: *Self, button: input.MouseButton, mods: input.Mods) bool {
        const priv = self.private();
        const surface = priv.core_surface orelse return false;
        if (button == .left) {
            priv.left_press = priv.cursor_pos;
            if (!mods.alt and !mods.ctrl) {
                if (self.hoveredLink()) |url| {
                    const held = !surface.mouseClickReported(mods);
                    self.clearPendingLink();
                    priv.pending_link = .{
                        .url = alloc_c.dupeSentinel(u8, url, 0) catch return false,
                        .pos = priv.cursor_pos,
                        .mods = mods,
                        .held = held,
                    };
                    if (held) return true;
                }
            }
        }
        const selecting = button == .left and !surface.mouseReportingActive() and !mods.alt and !mods.ctrl;
        // D-06: Shift+click with no selection selects from the last click.
        if (selecting and mods.shift and !surface.hasSelection()) {
            if (self.shiftClickFromAnchor()) {
                priv.shift_click_release = true;
                return true;
            }
        }
        if (button == .middle and
            !priv.gtk_enable_primary_paste and
            !surface.mouseReportingActive()) return false;
        const consumed = surface.mouseButtonCallback(.press, button, mods) catch |err| {
            log.warn("error in mouse button callback err={}", .{err});
            return false;
        };
        if (selecting and !mods.shift) {
            switch (surface.mouse.selection_gesture.left_click_count) {
                1 => priv.click_anchor = self.boundaryAt(priv.cursor_pos),
                2 => self.selectXtermWord(priv.cursor_pos),
                else => {},
            }
        }
        return consumed;
    }

    /// D-06: replace the core's double-click word with xterm's.
    fn selectXtermWord(self: *Self, pos: apprt.CursorPos) void {
        const surface = self.core() orelse return;
        const cell = links.cellAt(surface.size, pos.x, pos.y) orelse return;
        {
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());
            const screen = surface.renderer_state.terminal.screens.active;
            const pin = screen.pages.pin(.{ .viewport = .{ .x = @intCast(cell.col), .y = @intCast(cell.row) } }) orelse return;
            screen.select(xterm_sel.wordAt(pin)) catch return;
        }
        surface.renderer_thread.wakeup.notify() catch {};
    }

    /// The cell boundary nearest `pos` (xterm rounds selection coordinates
    /// to the nearest boundary), in screen coordinates.
    fn boundaryAt(self: *Self, pos: apprt.CursorPos) ?xterm_sel.Boundary {
        const surface = self.core() orelse return null;
        const size = surface.size;
        const cw: f64 = @floatFromInt(@max(1, size.cell.width));
        const grid = size.grid();
        const fx = (pos.x - @as(f64, @floatFromInt(size.padding.left))) / cw;
        const col: u32 = @intFromFloat(std.math.clamp(@round(fx), 0, @as(f64, @floatFromInt(grid.columns))));
        const cell = links.cellAt(size, @max(pos.x, @as(f64, @floatFromInt(size.padding.left))), pos.y) orelse return null;
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        const screen = surface.renderer_state.terminal.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(cell.row) } }) orelse return null;
        const pt = screen.pages.pointFromPin(.screen, pin) orelse return null;
        return .{ .x = col, .y = pt.coord().y };
    }

    fn shiftClickFromAnchor(self: *Self) bool {
        const priv = self.private();
        const surface = self.core() orelse return false;
        const anchor = priv.click_anchor orelse return false;
        const here = self.boundaryAt(priv.cursor_pos) orelse return false;
        {
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());
            const screen = surface.renderer_state.terminal.screens.active;
            const sel = xterm_sel.between(screen, anchor, here) orelse return false;
            screen.select(sel) catch return false;
        }
        surface.renderer_thread.wakeup.notify() catch {};
        return true;
    }

    fn mouseRelease(self: *Self, button: input.MouseButton, mods: input.Mods) bool {
        const priv = self.private();
        const surface = priv.core_surface orelse return false;
        if (button == .left and priv.shift_click_release) {
            priv.shift_click_release = false;
            if (surface.hasSelection()) terminal_clipboard.selectionToPrimary(self);
            return true;
        }
        if (button == .left) if (priv.pending_link) |pl| {
            defer self.clearPendingLink();
            const action: iface.services.UrlAction = if (mods.shift) .copy else .open;
            iface.services.url(pl.url, action, self.as(gtk.Widget));
            // A held press never reached the core, so neither does its
            // release. A reported one is the program's too.
            if (pl.held) return true;
        };
        if (button == .middle and
            !priv.gtk_enable_primary_paste and
            !surface.mouseReportingActive()) return false;
        const consumed = surface.mouseButtonCallback(.release, button, mods) catch |err| {
            log.warn("error in mouse button callback err={}", .{err});
            return false;
        };
        if (button == .left) {
            const press = priv.left_press;
            priv.left_press = null;
            // T-20: Alt+click (no drag) moves the shell cursor there.
            if (!consumed and mods.alt and !mods.shift and !mods.ctrl) {
                if (press) |p| if (self.sameCell(p, priv.cursor_pos)) self.altClickMoveCursor(priv.cursor_pos);
            }
            // T-21: a finished selection becomes PRIMARY.
            if (surface.hasSelection()) terminal_clipboard.selectionToPrimary(self);
        }
        return consumed;
    }

    fn sameCell(self: *Self, a: apprt.CursorPos, b: apprt.CursorPos) bool {
        const surface = self.core() orelse return false;
        const ca = links.cellAt(surface.size, a.x, a.y) orelse return false;
        const cb = links.cellAt(surface.size, b.x, b.y) orelse return false;
        return ca.col == cb.col and ca.row == cb.row;
    }

    /// The http(s) link under the pointer, if any (borrowed).
    fn hoveredLink(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        if (priv.link_osc8) |u| if (links.isHttp(u)) return u;
        if (priv.mouse_hover_url) |u| if (links.isHttp(u)) return u;
        return null;
    }

    fn clearPendingLink(self: *Self) void {
        const priv = self.private();
        if (priv.pending_link) |pl| alloc_c.free(pl.url);
        priv.pending_link = null;
    }

    /// Track the OSC 8 hyperlink under the pointer. Ghostty only reports
    /// OSC 8 links with Ctrl held; xterm.js treats them like URLs (T-25).
    fn updateOsc8Hover(self: *Self, pos: apprt.CursorPos) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const uri: ?[:0]u8 = uri: {
            const cell = links.cellAt(surface.size, pos.x, pos.y) orelse break :uri null;
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());
            break :uri links.osc8At(alloc_c, surface.renderer_state.terminal, cell);
        };
        const changed = if (priv.link_osc8) |old|
            (if (uri) |n| !std.mem.eql(u8, old, n) else true)
        else
            uri != null;
        if (priv.link_osc8) |old| alloc_c.free(old);
        priv.link_osc8 = uri;
        if (changed) self.applyCursor();
    }

    fn altClickMoveCursor(self: *Self, pos: apprt.CursorPos) void {
        const surface = self.core() orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc_c);
        {
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());
            const t = surface.renderer_state.terminal;
            const target = links.cellAt(surface.size, pos.x, pos.y) orelse return;
            // Only with the viewport at the bottom (xterm: ybase == ydisp).
            const sb = t.screens.active.pages.scrollbar();
            if (sb.offset + sb.len < sb.total) return;
            const cursor = t.screens.active.cursor;
            links.moveToCell(
                &out,
                alloc_c,
                .{ .col = cursor.x, .row = cursor.y },
                target,
                @intCast(t.cols),
                t.screens.active_key == .primary,
                t.modes.get(.cursor_keys),
            ) catch return;
        }
        if (out.items.len == 0) return;
        // Escape for the `text:` binding parser (\x1b).
        var esc: std.ArrayList(u8) = .empty;
        defer esc.deinit(alloc_c);
        for (out.items) |b| {
            if (b == 0x1b) esc.appendSlice(alloc_c, "\\x1b") catch return else esc.append(alloc_c, b) catch return;
        }
        _ = surface.performBindingAction(.{ .text = esc.items }) catch {};
    }

    fn gcMouseDown(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();
        if (priv.core_surface == null) return;
        // The press is where the button went down, even if no motion
        // event preceded it (a pointer that entered and clicked at once).
        self.pointerAt(x, y, gtk_key.translateMods(event.getModifierState()));

        const widget = priv.render_surface.as(gtk.Widget);
        const had_focus = widget.hasFocus() != 0;
        if (!had_focus) _ = widget.grabFocus();

        const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());

        // The click that focuses a pane also acts (link, selection,
        // mouse report), as in the Electron client (D-07).
        // No context menu (T-23).
        _ = self.mousePress(button, gtk_key.translateMods(event.getModifierState()));
    }

    fn gcMouseUp(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        self.pointerAt(x, y, gtk_key.translateMods(event.getModifierState()));
        const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());

        if (button == .left and priv.suppress_left_mouse_release) {
            priv.suppress_left_mouse_release = false;
            return;
        }

        const consumed = self.mouseRelease(button, gtk_key.translateMods(event.getModifierState()));
        if (!consumed and button == .left and !surface.hasSelection()) {
            _ = priv.im_context.as(gtk.IMContext).activateOsk(event);
        }
    }

    fn ecMouseMotion(
        ec: *gtk.EventControllerMotion,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = ec.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();

        const scaled = self.scaledCoordinates(x, y);
        const pos: apprt.CursorPos = .{ .x = @floatCast(scaled.x), .y = @floatCast(scaled.y) };

        // GTK sends motion without movement on resize/title change.
        if (@abs(priv.cursor_pos.x - pos.x) < 1 and @abs(priv.cursor_pos.y - pos.y) < 1) return;

        if (priv.config) |config| {
            const widget = priv.render_surface.as(gtk.Widget);
            if (widget.hasFocus() == 0 and config.get().@"focus-follows-mouse") {
                _ = widget.grabFocus();
            }
        }

        self.mouseMotion(pos, gtk_key.translateMods(event.getModifierState()));
    }

    /// Bring the pointer position up to date (CSS px in the terminal area)
    /// when it differs from the last motion.
    fn pointerAt(self: *Self, x: f64, y: f64, mods: input.Mods) void {
        const priv = self.private();
        const scaled = self.scaledCoordinates(x, y);
        const pos: apprt.CursorPos = .{ .x = @floatCast(scaled.x), .y = @floatCast(scaled.y) };
        if (@abs(priv.cursor_pos.x - pos.x) < 1 and @abs(priv.cursor_pos.y - pos.y) < 1) return;
        self.mouseMotion(pos, mods);
    }

    fn ecMouseEnter(ec: *gtk.EventControllerMotion, x: f64, y: f64, self: *Self) callconv(.c) void {
        const mods: input.Mods = if (ec.as(gtk.EventController).getCurrentEvent()) |e|
            gtk_key.translateMods(e.getModifierState())
        else
            .{};
        self.pointerAt(x, y, mods);
    }

    fn ecMouseLeave(ec: *gtk.EventControllerMotion, self: *Self) callconv(.c) void {
        const event = ec.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();
        if (priv.core_surface) |surface| {
            const mods = gtk_key.translateMods(event.getModifierState());
            surface.cursorPosCallback(.{ .x = -1, .y = -1 }, mods) catch |err| {
                log.warn("error in cursor pos callback err={}", .{err});
            };
        }
        if (priv.link_osc8) |old| {
            alloc_c.free(old);
            priv.link_osc8 = null;
            self.applyCursor();
        }
    }

    pub const MouseInput = union(enum) {
        /// Pointer moved to (x, y), CSS px relative to the pane.
        motion: struct { x: f64, y: f64 },
        press: input.MouseButton,
        release: input.MouseButton,
        /// Scroll by (dx, dy) in GTK's units (lines for a wheel).
        scroll: struct { dx: f64, dy: f64 },
    };

    /// Feed a synthesized mouse event through the same logic as the GTK
    /// controllers (control socket `mouse`; no GDK event involved, so
    /// focus-on-click and the on-screen keyboard are skipped).
    pub fn injectMouse(self: *Self, ev: MouseInput, mods: input.Mods) !bool {
        if (self.core() == null) return error.NoSurface;
        switch (ev) {
            .motion => |m| {
                const scaled = self.scaledCoordinates(m.x, m.y);
                self.mouseMotion(.{ .x = @floatCast(scaled.x), .y = @floatCast(scaled.y) }, mods);
                return true;
            },
            .press => |b| return self.mousePress(b, mods),
            .release => |b| return self.mouseRelease(b, mods),
            .scroll => |s| return self.scroll(s.dx, s.dy, mods, false),
        }
    }

    fn ecScrollBegin(_: *gtk.EventControllerScroll, self: *Self) callconv(.c) void {
        self.private().precision_scroll = true;
    }

    fn ecScrollEnd(_: *gtk.EventControllerScroll, self: *Self) callconv(.c) void {
        self.private().precision_scroll = false;
    }

    fn ecScroll(
        ec: *gtk.EventControllerScroll,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const mods: input.Mods = if (ec.as(gtk.EventController).getCurrentEvent()) |e|
            gtk_key.translateMods(e.getModifierState())
        else
            .{};
        // Touchpad (and other pixel-precise devices) vs wheel notches.
        const precision = ec.getUnit() == .surface or self.private().precision_scroll;
        return @intFromBool(self.scroll(x, y, mods, precision));
    }

    /// What Chromium on Wayland makes of one surface pixel of a touchpad
    /// scroll: 12 CSS pixels of `WheelEvent.deltaY` (measured: Electron 43
    /// under sway, 4 finger scrolls of 20 px gave deltaY 240 each, at
    /// scale 1 and 2; a wheel notch gives 120).
    const chromium_px_per_touch_px = 12.0;

    /// Wheel/touchpad scroll in GTK units (positive y = towards the bottom):
    /// wheel notches, or logical pixels when `precision`.
    ///
    /// As the Electron client (xterm.js 5.5, scrollSensitivity 1, Alt ×5):
    /// - wheel: 3 lines per notch at every scale (deviation 18; the core's
    ///   discrete multiplier), never multiplied by the display scale;
    /// - touchpad: each logical pixel is 12 CSS px (`chromium_px_per_touch_px`)
    ///   and a row is the cell height in CSS px. The result depends only on
    ///   the distance, never on how the touchpad slices it:
    ///   - normal screen (xterm `Viewport.handleWheel`): a CSS-pixel
    ///     position accumulates (`scrollTop += deltaY`) and the viewport
    ///     sits at round(position / row). The fraction lives as long as
    ///     xterm's does: until the viewport moves any other way (output at
    ///     the bottom, typing, the scrollbar, the wheel, a snap to the
    ///     bottom), or stops at the top or bottom (the browser clamps
    ///     `scrollTop`);
    ///   - alternate screen arrows and mouse wheel reports (xterm
    ///     `getLinesScrolled`): lines accumulate as a signed fraction; whole
    ///     lines go out (towards zero) and the rest is kept, across events
    ///     and gestures, as xterm's `_wheelPartialScroll` is never reset.
    ///   A reversal simply subtracts in both.
    fn scroll(self: *Self, x: f64, y: f64, mods: input.Mods, precision: bool) bool {
        const priv = self.private();
        const surface = priv.core_surface orelse return false;
        const fast: f64 = if (mods.alt) 5 else 1;

        if (!precision) {
            // Values are inverted for natural scrolling, as in the stock shell.
            surface.scrollCallback(x * -fast, y * -fast, .{}) catch |err| {
                log.warn("error in scroll callback err={}", .{err});
                return false;
            };
        } else {
            const css_y = y * chromium_px_per_touch_px * fast;
            const scale = scale_util.widgetSurfaceScale(priv.render_surface.as(gtk.Widget));
            const cell_h: u32 = @max(1, surface.size.cell.height);
            const row_css = @as(f64, @floatFromInt(cell_h)) / scale;
            if (!self.touchScrollViewport(css_y, row_css)) {
                priv.touch_partial += css_y / row_css;
                // (a hair of tolerance: 85 px is 60.000 lines, not 59.999…)
                const eps: f64 = if (priv.touch_partial < 0) -1e-6 else 1e-6;
                const whole = @trunc(priv.touch_partial + eps);
                priv.touch_partial -= whole;
                if (whole != 0) {
                    // Whole cells, so the core's own (lossy) accounting has
                    // nothing left over.
                    surface.scrollCallback(0, -whole * @as(f64, @floatFromInt(cell_h)), .{ .precision = true }) catch |err| {
                        log.warn("error in scroll callback err={}", .{err});
                        return false;
                    };
                }
            }
        }

        // T-30: a downward scroll that ends near the bottom snaps to it.
        if (y > 0 and !surface.mouseReportingActive()) {
            if (self.snapToBottomIfNear()) priv.touch_offset = null;
        }
        return true;
    }

    /// The normal-screen touchpad path of `scroll`: moves the viewport to
    /// the rounded accumulated position (synchronously, under the renderer
    /// lock, as the core's own scroll does). False when the screen does not
    /// scroll its viewport (alternate screen with alternate scroll, or
    /// mouse reporting).
    fn touchScrollViewport(self: *Self, css_y: f64, row_css: f64) bool {
        const priv = self.private();
        const surface = self.core() orelse return false;
        {
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());
            const t = surface.renderer_state.terminal;
            if (t.flags.mouse_event != .none) return false;
            if (t.screens.active_key == .alternate and t.modes.get(.mouse_alternate_scroll)) return false;
            const sb = t.screens.active.pages.scrollbar();
            const max = sb.total -| sb.len;
            // Moved some other way since our last step: start afresh there.
            if (priv.touch_offset == null or priv.touch_offset.? != sb.offset) {
                priv.touch_px = 0;
                priv.touch_start = sb.offset;
            }
            priv.touch_px += css_y;
            const want_f = @as(f64, @floatFromInt(priv.touch_start)) + @round(priv.touch_px / row_css);
            const target: usize = @intFromFloat(std.math.clamp(want_f, 0, @as(f64, @floatFromInt(max))));
            if (target != sb.offset) {
                t.scrollViewport(.{ .delta = @as(isize, @intCast(target)) - @as(isize, @intCast(sb.offset)) });
            }
            const now = t.screens.active.pages.scrollbar().offset;
            // Clamped at the top or bottom: the position stops there.
            if (want_f < 0 or want_f > @as(f64, @floatFromInt(max))) {
                priv.touch_px = (@as(f64, @floatFromInt(now)) - @as(f64, @floatFromInt(priv.touch_start))) * row_css;
            }
            priv.touch_offset = now;
        }
        surface.renderer_thread.wakeup.notify() catch {};
        return true;
    }

    fn scrollOffset(self: *Self) ?usize {
        const surface = self.core() orelse return null;
        surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.renderer_state.mutex.unlock(global.io());
        return surface.renderer_state.terminal.screens.active.pages.scrollbar().offset;
    }

    /// T-30: after a downward viewport move (wheel, Shift+PageDown,
    /// scrollbar), within `max(3, round(rows * 0.15))` lines of the bottom
    /// snap to the very bottom (Electron app.js `onScroll`).
    fn snapToBottomIfNear(self: *Self) bool {
        const surface = self.core() orelse return false;
        surface.renderer_state.mutex.lockUncancelable(global.io());
        const t = surface.renderer_state.terminal;
        const sb = t.screens.active.pages.scrollbar();
        const rows = t.rows;
        surface.renderer_state.mutex.unlock(global.io());
        const dist = sb.total -| (sb.offset + sb.len);
        if (dist == 0 or dist > links.stickyBand(rows)) return false;
        _ = surface.performBindingAction(.scroll_to_bottom) catch {};
        return true;
    }

    //---------------------------------------------------------------
    // Render surface lifecycle

    fn renderSurfaceRealize(_: *RenderSurface, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.core_surface) |v| {
            v.displayRealized() catch |err| {
                log.warn("core displayRealized failed err={}", .{err});
            };
            self.redraw();
        }
        priv.im_context.as(gtk.IMContext).setClientWidget(self.as(gtk.Widget));
    }

    fn renderSurfaceUnrealize(_: *RenderSurface, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.core_surface) |surface| surface.displayUnrealized();
        priv.im_context.as(gtk.IMContext).setClientWidget(null);
    }

    fn renderSurfaceMap(_: *RenderSurface, self: *Self) callconv(.c) void {
        self.private().mapped = true;
        self.updateOcclusion();
    }

    fn renderSurfaceUnmap(_: *RenderSurface, self: *Self) callconv(.c) void {
        self.private().mapped = false;
        self.updateOcclusion();
    }

    /// Tell the core whether the pane is visible (mapped and its window
    /// not suspended). Containers call this when they hide panes.
    pub fn updateOcclusion(self: *Self) void {
        const surface = self.core() orelse return;
        const priv = self.private();
        const visible = priv.mapped and priv.shown and !self.windowSuspended();
        surface.occlusionCallback(visible) catch |err| {
            log.warn("error in occlusion callback err={}", .{err});
        };
    }

    fn windowSuspended(self: *Self) bool {
        const native = self.as(gtk.Widget).getNative() orelse return false;
        const window = gobject.ext.cast(gtk.Window, native) orelse return false;
        return window.isSuspended() != 0;
    }

    /// While held, a resize of the terminal waits (`iface.Pane.
    /// holdResize`): the container is animating the pane to its new size,
    /// and the terminal takes it when the move ends. A pane that has no
    /// core surface yet is not held back: its session starts at once, at
    /// the size it is given.
    pub fn holdResize(self: *Self, hold: bool) void {
        const priv = self.private();
        if (priv.hold_resize == hold) return;
        priv.hold_resize = hold;
        if (hold) return;
        const pending = priv.pending_size orelse return;
        priv.pending_size = null;
        self.applySize(pending);
    }

    fn renderSurfaceResize(_: *RenderSurface, width: c_int, height: c_int, self: *Self) callconv(.c) void {
        const priv = self.private();
        const new_size: apprt.SurfaceSize = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
        if (priv.hold_resize and priv.core_surface != null) {
            priv.pending_size = new_size;
            return;
        }
        priv.pending_size = null;
        self.applySize(new_size);
    }

    fn applySize(self: *Self, new_size: apprt.SurfaceSize) void {
        const priv = self.private();
        const changed = !priv.size.eql(&new_size);
        priv.size = new_size;

        if (priv.core_surface) |surface| {
            // No signal exists for content scale changes; they come with
            // a resize.
            surface.contentScaleCallback(self.getContentScale()) catch |err| {
                log.warn("error in content scale callback err={}", .{err});
            };
            if (changed) surface.sizeCallback(new_size) catch |err| {
                log.warn("error in size callback err={}", .{err});
            };
        } else {
            self.initSurface() catch |err| {
                log.warn("surface failed to initialize err={}", .{err});
            };
        }
    }

    fn initSurface(self: *Self) !void {
        const priv = self.private();
        assert(priv.core_surface == null);

        const app = Application.default();
        const alloc = app.allocator();

        const surface = try alloc.create(CoreSurface);
        errdefer alloc.destroy(surface);

        try app.core().addSurface(self.rt());
        errdefer app.core().deleteSurface(self.rt());

        var config = try apprt.surface.newConfig(app.core(), priv.config.?.get(), .window);
        defer config.deinit();

        const content_scale = self.getContentScale();
        log.info("surface content scale: x={d} y={d} font_size={d}", .{
            content_scale.x,
            content_scale.y,
            config.@"font-size",
        });

        surface.init(alloc, &config, app.core(), app.rt(), &priv.rt_surface) catch |err| {
            log.warn("failed to initialize surface err={}", .{err});
            return error.SurfaceError;
        };
        errdefer surface.deinit();

        priv.core_surface = surface;
        priv.render_surface.setCoreSurface(surface);

        // Not realized yet: start the renderer unrealized; `realize`
        // calls displayRealized.
        if (priv.render_surface.as(gtk.Widget).getRealized() == 0) {
            surface.displayUnrealized();
        }

        signals.ready.impl.emit(self, null, .{}, null);
        self.updateFocus(priv.focused);
        // A pane told to stay hidden before its surface existed (the
        // container is still moving it into place) starts that way.
        if (!priv.shown) self.updateOcclusion();
    }

    //---------------------------------------------------------------
    // apprt callbacks (called via Surface.zig and App.zig performAction)

    pub fn coreClose(self: *Self) void {
        signals.@"close-request".impl.emit(self, null, .{}, null);
    }

    pub fn getContentScale(self: *Self) apprt.ContentScale {
        const widget = self.private().render_surface.as(gtk.Widget);

        const gtk_scale: f32 = scale: {
            const surface_scale = scale_util.widgetSurfaceScale(widget);
            if (surface_scale <= 0) break :scale 1.0;
            break :scale @floatCast(surface_scale);
        };

        // Font DPI from the desktop's accessibility settings (gtk-xft-dpi
        // is DPI * 1024; -1 means default).
        const xft_dpi_scale: f32 = xft: {
            const dpi = gsettings.get(.@"gtk-xft-dpi") orelse break :xft 1.0;
            if (dpi <= 0) break :xft 1.0;
            break :xft (@as(f32, @floatFromInt(dpi)) / 1024.0) / 96.0;
        };

        const scale = gtk_scale * xft_dpi_scale;
        return .{ .x = scale, .y = scale };
    }

    pub fn getSize(self: *Self) apprt.SurfaceSize {
        return self.private().size;
    }

    pub fn getCursorPos(self: *Self) apprt.CursorPos {
        return self.private().cursor_pos;
    }

    pub fn defaultTermioEnv(self: *Self) !std.process.Environ.Map {
        _ = self;
        var env = try global.environMap();
        errdefer env.deinit();

        // GTK/launcher variables must not leak into the shell.
        inline for (.{
            "GDK_DEBUG",                  "GDK_DISABLE",       "GSK_RENDERER",
            "GIO_LAUNCHED_DESKTOP_FILE",  "GIO_LAUNCHED_DESKTOP_FILE_PID",
            "DBUS_STARTER_ADDRESS",       "DBUS_STARTER_BUS_TYPE",
            "INVOCATION_ID",              "JOURNAL_STREAM",
            "NOTIFY_SOCKET",              @import("control.zig").env_var,
        }) |name| _ = env.orderedRemove(name);
        return env;
    }

    pub fn renderDeviceOptions(self: *Self) !renderer.Device.Options {
        switch (build_config.renderer) {
            .opengl => {
                const gtk_native = self.as(gtk.Widget).getNative() orelse return .{};
                const gdk_surface = gtk_native.getSurface() orelse return .{};
                const gdk_display = gdk_surface.getDisplay();
                if (comptime build_options.wayland) {
                    const gdk_wayland = @import("gdk_wayland");
                    if (gobject.ext.cast(gdk_wayland.WaylandDisplay, gdk_display)) |wl| {
                        return .{ .display = @ptrCast(wl.getEglDisplay()) };
                    }
                }
                if (comptime build_options.x11) {
                    const gdk_x11 = @import("gdk_x11");
                    if (gobject.ext.cast(gdk_x11.X11Display, gdk_display)) |x| {
                        return .{ .display = @ptrCast(x.getEglDisplay()) };
                    }
                }
                return .{};
            },
            .metal => comptime unreachable,
        }
    }

    /// The title as the pane bar shows it: `displayTitle` of what the
    /// session or the core published (panels D7).
    pub fn setTitle(self: *Self, title: ?[:0]const u8) void {
        const alloc = Application.default().allocator();
        const shown: ?[:0]u8 = if (title) |t| displayTitle(alloc, t) catch null else null;
        defer if (shown) |x| alloc.free(x);
        @import("ext.zig").replaceString(&self.private().title, if (shown) |x| x else title);
        self.as(gobject.Object).notifyByPspec(properties.title.impl.param_spec);
    }

    pub fn setPwd(self: *Self, pwd: ?[:0]const u8) void {
        @import("ext.zig").replaceString(&self.private().pwd, pwd);
        self.as(gobject.Object).notifyByPspec(properties.pwd.impl.param_spec);
    }

    pub fn setMouseHoverUrl(self: *Self, url: ?[:0]const u8) void {
        @import("ext.zig").replaceString(&self.private().mouse_hover_url, url);
        self.as(gobject.Object).notifyByPspec(properties.@"mouse-hover-url".impl.param_spec);
    }

    pub fn setMouseShape(self: *Self, shape: terminal.MouseShape) void {
        self.private().mouse_shape = shape;
        self.applyCursor();
    }

    pub fn setMouseHidden(self: *Self, hidden: bool) void {
        self.private().mouse_hidden = hidden;
        self.applyCursor();
    }

    pub fn setCellSize(self: *Self, size: apprt.action.CellSize) void {
        self.private().cell_size = size;
    }

    /// The core's scrollbar state → the scrollbar widget (T-10).
    pub fn setScrollbar(self: *Self, sb: terminal.Scrollbar) void {
        const priv = self.private();
        priv.scrollbar = sb;
        priv.scrollbar_syncing = true;
        defer priv.scrollbar_syncing = false;
        const len: f64 = @floatFromInt(sb.len);
        priv.scrollbar_adj.configure(
            @floatFromInt(sb.offset),
            0,
            @floatFromInt(sb.total),
            1,
            len,
            len,
        );
        // The column keeps its 10px; the thumb shows only with scrollback.
        priv.scrollbar_widget.as(gtk.Widget).setOpacity(if (sb.total > sb.len) 1 else 0);
    }

    fn scrollbarValueChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.scrollbar_syncing) return;
        const surface = priv.core_surface orelse return;
        const row: usize = @intFromFloat(@max(0, @round(adj.getValue())));
        // After a snap GTK may report the dragged position again (another
        // motion to the same place, or the button release): not a move.
        if (priv.scrollbar_snapped_from) |from| {
            if (from == row) return;
            priv.scrollbar_snapped_from = null;
        }
        const down = row > priv.scrollbar.offset;
        _ = surface.performBindingAction(.{ .scroll_to_row = row }) catch {};
        // A thumb drag down into the bottom band re-sticks (T-30, D-08).
        if (down and self.snapToBottomIfNear()) priv.scrollbar_snapped_from = row;
    }

    /// Pane classes the CSS keys on: `light` with a light background.
    fn applySchemeClass(self: *Self) void {
        const priv = self.private();
        const config = priv.config orelse return;
        const bg = config.get().background.toTerminalRGB();
        const lum = bg.perceivedLuminance();
        const widget = self.as(gtk.Widget);
        if (lum > 0.5) widget.addCssClass("light") else widget.removeCssClass("light");
        // The render surface fills in the terminal's background itself,
        // and imports its frames as opaque when the terminal is.
        priv.render_surface.setBackground(.{
            .f_red = @as(f32, @floatFromInt(bg.r)) / 255,
            .f_green = @as(f32, @floatFromInt(bg.g)) / 255,
            .f_blue = @as(f32, @floatFromInt(bg.b)) / 255,
            .f_alpha = 1,
        }, config.get().@"background-opacity" >= 1);
    }

    /// Send a side-channel frame on the session socket (remote panes).
    /// False if the pane is local or no socket is open.
    pub fn sendFrame(self: *Self, frame: termio.Webmux.ClientFrame) bool {
        const surface = self.core() orelse return false;
        switch (surface.io.backend) {
            .webmux => |*w| return w.send(frame),
            else => return false,
        }
    }

    /// Whether the core currently renders this pane (mapped, shown, not
    /// suspended), for `dump`.
    pub fn isVisible(self: *Self) bool {
        const priv = self.private();
        return priv.mapped and priv.shown and !self.windowSuspended();
    }

    pub fn setRendererHealth(self: *Self, health: renderer.Health) void {
        self.private().renderer_health = health;
        if (health != .healthy) log.warn("renderer health={t}", .{health});
    }

    pub fn ringBell(self: *Self) void {
        signals.bell.impl.emit(self, null, .{}, null);
    }

    pub fn setConfig(self: *Self, config: *ConfigObject) void {
        const priv = self.private();
        if (priv.config) |old| old.unref();
        priv.config = config.ref();
        self.applySchemeClass();
    }

    pub fn showOnScreenKeyboard(self: *Self) bool {
        return self.private().im_context.as(gtk.IMContext).activateOsk(null) != 0;
    }

    fn applyCursor(self: *Self) void {
        const priv = self.private();
        const widget = priv.render_surface.as(gtk.Widget);
        if (priv.mouse_hidden) return widget.setCursorFromName("none");
        if (priv.link_osc8) |u| if (links.isHttp(u)) return widget.setCursorFromName("pointer");
        widget.setCursorFromName(cursorName(priv.mouse_shape).ptr);
    }

    //---------------------------------------------------------------
    // Clipboard

    pub fn clipboardRequest(
        self: *Self,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        return try Clipboard.request(self, clipboard_type, state);
    }

    pub fn setClipboard(
        self: *Self,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) void {
        Clipboard.set(self, clipboard_type, contents, confirm);
    }

    //---------------------------------------------------------------
    // GObject

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.* = .{};
        priv.rt_surface = .{ .pane = self };
        priv.config = Application.default().getConfig();
        priv.gtk_enable_primary_paste = gsettings.get(.@"gtk-enable-primary-paste") orelse true;

        const widget = self.as(gtk.Widget);
        widget.addCssClass("terminal-pane");
        widget.setFocusable(0);

        // Widget tree.
        const ov = gtk.Overlay.new();
        priv.overlay = ov;
        const rs = gobject.ext.newInstance(RenderSurface, .{});
        priv.render_surface = rs;
        const rs_widget = rs.as(gtk.Widget);
        rs_widget.setHexpand(1);
        rs_widget.setVexpand(1);
        rs_widget.setFocusable(1);
        rs_widget.setFocusOnClick(1);
        rs_widget.setCursorFromName("text");
        if (render_surface_mod.offloadWanted()) {
            // The frames go to the compositor on a subsurface while
            // nothing but a rectangular clip stands between the texture
            // and the window (GTK falls back to drawing them otherwise).
            const off = gtk.GraphicsOffload.new(rs_widget);
            off.setEnabled(.enabled);
            off.as(gtk.Widget).setHexpand(1);
            off.as(gtk.Widget).setVexpand(1);
            ov.setChild(off.as(gtk.Widget));
        } else {
            ov.setChild(rs_widget);
        }
        ov.as(gtk.Widget).setHexpand(1);

        // T-10: terminal | 10px scrollbar column.
        const adj = gtk.Adjustment.new(0, 0, 0, 1, 0, 0);
        priv.scrollbar_adj = adj;
        _ = gtk.Adjustment.signals.value_changed.connect(adj, *Self, scrollbarValueChanged, self, .{});
        const sb = gtk.Scrollbar.new(.vertical, adj);
        priv.scrollbar_widget = sb;
        sb.as(gtk.Widget).addCssClass("webmux-terminal-scrollbar");
        sb.as(gtk.Widget).setOpacity(0);
        // The column carries the terminal's background (terminal.css):
        // the scrollbar itself is fully transparent while there is
        // nothing to scroll, and nothing is painted under the pane.
        const sb_col = gtk.Box.new(.vertical, 0);
        sb_col.as(gtk.Widget).addCssClass("webmux-terminal-scrollbar-column");
        sb.as(gtk.Widget).setVexpand(1);
        sb_col.append(sb.as(gtk.Widget));
        const box = gtk.Box.new(.horizontal, 0);
        box.append(ov.as(gtk.Widget));
        box.append(sb_col.as(gtk.Widget));
        self.as(adw.Bin).setChild(box.as(gtk.Widget));
        self.applySchemeClass();

        _ = gtk.Widget.signals.realize.connect(rs, *Self, renderSurfaceRealize, self, .{});
        _ = gtk.Widget.signals.unrealize.connect(rs, *Self, renderSurfaceUnrealize, self, .{});
        _ = gtk.Widget.signals.map.connect(rs, *Self, renderSurfaceMap, self, .{});
        _ = gtk.Widget.signals.unmap.connect(rs, *Self, renderSurfaceUnmap, self, .{});
        _ = RenderSurface.signals.resize.connect(rs, *Self, renderSurfaceResize, self, .{});

        // Input method.
        const im = gtk.IMMulticontext.new();
        priv.im_context = im;
        {
            var purpose = gobject.ext.Value.newFrom(gtk.InputPurpose.terminal);
            defer purpose.unset();
            gobject.Object.setProperty(im.as(gobject.Object), "input-purpose", &purpose);
        }
        _ = gtk.IMContext.signals.preedit_start.connect(im, *Self, imPreeditStart, self, .{});
        _ = gtk.IMContext.signals.preedit_changed.connect(im, *Self, imPreeditChanged, self, .{});
        _ = gtk.IMContext.signals.preedit_end.connect(im, *Self, imPreeditEnd, self, .{});
        _ = gtk.IMContext.signals.commit.connect(im, *Self, imCommit, self, .{});

        // Event controllers, on the pane (events bubble up from the
        // focused render surface).
        const ec_focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(ec_focus, *Self, ecFocusEnter, self, .{});
        _ = gtk.EventControllerFocus.signals.leave.connect(ec_focus, *Self, ecFocusLeave, self, .{});
        widget.addController(ec_focus.as(gtk.EventController));

        const ec_key = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(ec_key, *Self, ecKeyPressed, self, .{});
        _ = gtk.EventControllerKey.signals.key_released.connect(ec_key, *Self, ecKeyReleased, self, .{});
        widget.addController(ec_key.as(gtk.EventController));

        const ec_scroll = gtk.EventControllerScroll.new(.{ .vertical = true, .horizontal = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(ec_scroll, *Self, ecScroll, self, .{});
        _ = gtk.EventControllerScroll.signals.scroll_begin.connect(ec_scroll, *Self, ecScrollBegin, self, .{});
        _ = gtk.EventControllerScroll.signals.scroll_end.connect(ec_scroll, *Self, ecScrollEnd, self, .{});
        // Pointer controllers on the terminal area only, so the scrollbar's
        // clicks and drags never reach the terminal.
        ov.as(gtk.Widget).addController(ec_scroll.as(gtk.EventController));

        const ec_motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(ec_motion, *Self, ecMouseMotion, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(ec_motion, *Self, ecMouseLeave, self, .{});
        _ = gtk.EventControllerMotion.signals.enter.connect(ec_motion, *Self, ecMouseEnter, self, .{});
        ov.as(gtk.Widget).addController(ec_motion.as(gtk.EventController));

        const gc = gtk.GestureClick.new();
        gc.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(gc, *Self, gcMouseDown, self, .{});
        _ = gtk.GestureClick.signals.released.connect(gc, *Self, gcMouseUp, self, .{});
        ov.as(gtk.Widget).addController(gc.as(gtk.EventController));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }
        self.as(adw.Bin).setChild(null);
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();
        const priv = self.private();
        priv.held_input.deinit(alloc_c);
        if (priv.core_surface) |v| {
            // Unregister first so callbacks during deinit cannot find us.
            app.core().deleteSurface(self.rt());
            v.deinit();
            alloc.destroy(v);
            priv.core_surface = null;
        }
        // After the core surface: its deinit stopped the backend's reader
        // thread, so no event callback can still reach the proxy we drop.
        if (priv.remote) |st| {
            st.destroy();
            priv.remote = null;
        }
        priv.im_context.unref();
        if (priv.link_osc8) |u| alloc_c.free(u);
        if (priv.pending_link) |pl| alloc_c.free(pl.url);
        inline for (.{ "title", "pwd", "mouse_hover_url" }) |field| {
            if (@field(priv, field)) |v| glib.free(@ptrCast(@constCast(v)));
            @field(priv, field) = null;
        }
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(RenderSurface);
            gtk.Widget.Class.setCssName(class.as(gtk.Widget.Class), "terminal-pane");
            // The pane's stylesheet, once for the process (no chrome file
            // needs to load it).
            if (gdk.Display.getDefault()) |display| {
                const css = gtk.CssProvider.new();
                css.loadFromString(@embedFile("terminal/terminal.css"));
                gtk.StyleContext.addProviderForDisplay(
                    display,
                    css.as(gtk.StyleProvider),
                    gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
                );
            }

            gobject.ext.registerProperties(class, &.{
                properties.title.impl,
                properties.pwd.impl,
                properties.focused.impl,
                properties.@"mouse-hover-url".impl,
            });

            signals.@"close-request".impl.register(.{});
            signals.bell.impl.register(.{});
            signals.ready.impl.register(.{});
            signals.@"link-changed".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};

const PendingLink = struct {
    url: [:0]u8,
    pos: apprt.CursorPos,
    mods: input.Mods,
    /// True if the press was held back from the core. False while the
    /// program has mouse reporting on: it got the press, and gets the
    /// release.
    held: bool,
};

/// See `TerminalPane.handleKey` and the stock surface's IMKeyEvent.
const IMKeyEvent = enum { false, composing, not_composing };

fn translateMouseButton(button: c_uint) input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        10 => .ten,
        11 => .eleven,
        else => .unknown,
    };
}

fn cursorName(shape: terminal.MouseShape) [:0]const u8 {
    return switch (shape) {
        .default => "default",
        .help => "help",
        .pointer => "pointer",
        .context_menu => "context-menu",
        .progress => "progress",
        .wait => "wait",
        .cell => "cell",
        .crosshair => "crosshair",
        .text => "text",
        .vertical_text => "vertical-text",
        .alias => "alias",
        .copy => "copy",
        .no_drop => "no-drop",
        .move => "move",
        .not_allowed => "not-allowed",
        .grab => "grab",
        .grabbing => "grabbing",
        .all_scroll => "all-scroll",
        .col_resize => "col-resize",
        .row_resize => "row-resize",
        .n_resize => "n-resize",
        .e_resize => "e-resize",
        .s_resize => "s-resize",
        .w_resize => "w-resize",
        .ne_resize => "ne-resize",
        .nw_resize => "nw-resize",
        .se_resize => "se-resize",
        .sw_resize => "sw-resize",
        .ew_resize => "ew-resize",
        .ns_resize => "ns-resize",
        .nesw_resize => "nesw-resize",
        .nwse_resize => "nwse-resize",
        .zoom_in => "zoom-in",
        .zoom_out => "zoom-out",
    };
}

/// A session title as the Electron client's pane label shows it (a span
/// with `textContent = title`, `white-space: nowrap`; measured in Electron
/// 43): spaces, tabs, line feeds and carriage returns collapse into one
/// space and are trimmed at both ends; every other C0 control and DEL is
/// drawn by Chromium as its control picture (BEL as U+2407 ␇, ESC as
/// U+241B ␛), so it becomes that character here (Pango would draw a hex
/// box); C1 controls become U+FFFD; invalid UTF-8 becomes U+FFFD per byte.
pub fn displayTitle(alloc: Allocator, raw: []const u8) Allocator.Error![:0]u8 {
    const valid = try sanitizeUtf8(alloc, raw);
    defer alloc.free(valid);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var space = false;
    var it: std.unicode.Utf8Iterator = .{ .bytes = valid, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        const mapped: u21 = switch (cp) {
            ' ', '\t', '\n', '\r' => {
                space = true;
                continue;
            },
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => 0x2400 + cp,
            0x7f => 0x2421,
            0x80...0x9f => 0xfffd,
            else => cp,
        };
        if (space and out.items.len > 0) try out.append(alloc, ' ');
        space = false;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(mapped, &buf) catch unreachable;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSliceSentinel(alloc, 0);
}

test "displayTitle" {
    const a = std.testing.allocator;
    const t1 = try displayTitle(a, "T\x07itle\x1b]0;evil\x07 end");
    defer a.free(t1);
    try std.testing.expectEqualStrings("T\u{2407}itle\u{241B}]0;evil\u{2407} end", t1);
    const t2 = try displayTitle(a, "  a\t\tb\r\nc \x7f\xc2\x85 ");
    defer a.free(t2);
    try std.testing.expectEqualStrings("a b c \u{2421}\u{FFFD}", t2);
}

/// `bytes` with every invalid UTF-8 sequence replaced by U+FFFD, one per
/// offending byte (TextDecoder's replacement). Caller frees.
pub fn sanitizeUtf8(alloc: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (n > 0 and i + n <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i .. i + n])) |_| {
                try out.appendSlice(alloc, bytes[i .. i + n]);
                i += n;
                continue;
            } else |_| {}
        }
        try out.appendSlice(alloc, "\u{FFFD}");
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

test "sanitizeUtf8" {
    const a = std.testing.allocator;
    const s1 = try sanitizeUtf8(a, "h\xc3\xa9");
    defer a.free(s1);
    try std.testing.expectEqualStrings("hé", s1);
    const s2 = try sanitizeUtf8(a, "\xff");
    defer a.free(s2);
    try std.testing.expectEqualStrings("\u{FFFD}", s2);
}

/// Clipboard, from the stock surface's `Clipboard` namespace minus the
/// confirmation dialog: requests that would need confirmation are denied
/// and logged (config.zig turns paste protection off and sets OSC 52 to
/// allow/deny, so this only happens if someone changes that).
const Clipboard = struct {
    fn set(
        self: *TerminalPane,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) void {
        const text: [:0]const u8 = for (contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/plain")) break content.data;
        } else return;

        if (confirm) {
            log.warn("clipboard write needs confirmation, which this shell does not offer; denied", .{});
            return;
        }

        // The core writes the clipboard for OSC 52 only: the shell never
        // runs Ghostty's clipboard bindings (keys and Edit › Copy/Paste go
        // through `copyToClipboard` / `pasteFromClipboard`, selection to
        // PRIMARY through terminal/clipboard.zig). So: always CLIPBOARD,
        // whatever the target field said, plain UTF-8 text with invalid
        // sequences replaced by U+FFFD (the Electron client's
        // TextDecoder), then its toast (C-01).
        _ = clipboard_type;
        const alloc = Application.default().allocator();
        const clean = sanitizeUtf8(alloc, text) catch return;
        defer alloc.free(clean);
        const priv = self.private();
        const clipboard = get(priv.render_surface.as(gtk.Widget), .standard);
        const bytes = glib.Bytes.new(clean.ptr, clean.len);
        defer bytes.unref();
        // UTF-8 first: some clients pick the first match.
        const atoms = [_][:0]const u8{ "text/plain;charset=utf-8", "text/plain" };
        var providers: [atoms.len]*gdk.ContentProvider = undefined;
        for (atoms, 0..) |atom, j| providers[j] = gdk.ContentProvider.newForBytes(atom, bytes);
        const all = gdk.ContentProvider.newUnion(&providers, providers.len);
        defer all.unref();
        const ok = clipboard.setContent(all) != 0;
        iface.services.status(self.connName(), if (ok)
            "clipboard set from terminal"
        else
            "could not write to the clipboard");
    }

    fn request(
        self: *TerminalPane,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) Allocator.Error!apprt.ClipboardReadResult {
        if (state == .kitty_read or state == .kitty_write or state == .list) return .unsupported;

        const clipboard = get(self.private().render_surface.as(gtk.Widget), clipboard_type);

        // Let performable paste binds fall through when there is no text.
        if (state == .paste) {
            if (clipboard.getFormats().containGtype(gobject.ext.types.string) == 0) {
                return .unavailable;
            }
        }

        const alloc = Application.default().allocator();
        const ud = try alloc.create(Request);
        ud.* = .{ .self = self.ref(), .state = state };
        clipboard.readTextAsync(null, readText, ud);
        return .started;
    }

    fn get(widget: *gtk.Widget, clipboard: apprt.Clipboard) *gdk.Clipboard {
        return switch (clipboard) {
            .standard => widget.getClipboard(),
            .selection, .primary => widget.getPrimaryClipboard(),
        };
    }

    const Request = struct {
        /// Strong ref; released when the read completes.
        self: *TerminalPane,
        state: apprt.ClipboardRequest,
    };

    fn readText(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const req: *Request = @ptrCast(@alignCast(ud orelse return));
        const alloc = Application.default().allocator();
        defer alloc.destroy(req);
        const self = req.self;
        defer self.unref();

        const clipboard = gobject.ext.cast(gdk.Clipboard, source orelse return) orelse return;
        var gerr: ?*glib.Error = null;
        const cstr_ = clipboard.readTextFinish(res, &gerr);
        if (gerr) |err| {
            defer err.free();
            log.warn("failed to read clipboard err={s}", .{err.f_message orelse "(no message)"});
            return;
        }
        const cstr = cstr_ orelse return;
        defer glib.free(cstr);
        const str = std.mem.sliceTo(cstr, 0);

        const surface = self.core() orelse return;
        surface.completeClipboardRequest(
            req.state,
            .{ .contents = &.{.{ .mime = "text/plain", .data = str }} },
        ) catch |err| switch (err) {
            error.UnsafePaste, error.UnauthorizedPaste => log.warn(
                "clipboard request needs confirmation, which this shell does not offer; denied",
                .{},
            ),
            else => log.warn("failed to complete clipboard request err={}", .{err}),
        };
    }
};
