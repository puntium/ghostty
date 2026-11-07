//! `WebmuxApplication`: the process. Owns the Ghostty core app, the
//! terminal configuration, the main loop, application-wide CSS, the
//! control socket, and the apprt action dispatch (`performAction`).
//!
//! The run loop and lifecycle are adapted from
//! src/apprt/gtk/class/application.zig (Ghostty f54340ad); the action
//! table is new.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const CoreApp = @import("../../App.zig");
const CoreConfig = @import("../../config.zig").Config;

const Common = @import("class.zig").Common;
const ApprtApp = @import("App.zig");
const ConfigObject = @import("config_object.zig").Config;
const Window = @import("window.zig").Window;
const TerminalPane = @import("pane.zig").TerminalPane;
const ext = @import("ext.zig");
const termconfig = @import("config.zig");
const control = @import("control.zig");
const chrome = @import("chrome/hub.zig");
const dev = @import("dev.zig");

const log = std.log.scoped(.webmux_application);

/// Every stylesheet of the shell, loaded once for the display at
/// application priority in this order. One line per feature area.
const stylesheets = [_][:0]const u8{
    @embedFile("style.css"),
    @embedFile("chrome/chrome.css"),
};

extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;

pub const Application = extern struct {
    const Self = @This();

    pub const application_id = "me.puntium.webmux.gtk";

    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxApplication",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        rt_app: *ApprtApp,
        core_app: *CoreApp,

        /// The terminal configuration every new pane starts from.
        config: *ConfigObject,
        scheme: termconfig.Scheme,

        /// Application-wide stylesheets (`stylesheets`), one provider each.
        css_providers: [stylesheets.len]*gtk.CssProvider,

        /// Set once a window was requested, so the loop doesn't quit
        /// before the first window exists.
        requested_window: bool = false,

        /// False ends the run loop. Main thread only.
        running: bool = false,

        pub var offset: c_int = 0;
    };

    /// The process-wide application. Asserts it exists.
    pub fn default() *Self {
        const app = gio.Application.getDefault().?;
        return gobject.ext.cast(Self, app).?;
    }

    pub fn new(rt_app: *ApprtApp, core_app: *CoreApp) !*Self {
        const alloc = core_app.alloc;

        _ = glib.logSetWriterFunc(glibLogWriterFunction, null, null);

        var config = try termconfig.build(alloc, .dark);
        defer config.deinit();
        logDiagnostics(&config);

        setGtkEnv();
        adw.init();

        const display: *gdk.Display = gdk.Display.getDefault() orelse {
            log.err("no display (is WAYLAND_DISPLAY set and the compositor up?), exiting", .{});
            std.process.exit(1);
        };

        const config_obj: *ConfigObject = try .new(alloc, &config);
        errdefer config_obj.unref();

        var css_providers: [stylesheets.len]*gtk.CssProvider = undefined;
        for (stylesheets, &css_providers) |css, *slot| {
            const provider = gtk.CssProvider.new();
            provider.loadFromString(css.ptr);
            gtk.StyleContext.addProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            slot.* = provider;
        }
        @import("files/css.zig").install(display);

        const self = gobject.ext.newInstance(Self, .{
            .application_id = application_id,
            // One process per launch for now; single-instance hand-off
            // can come with the window chrome work.
            .flags = gio.ApplicationFlags{ .non_unique = true },
        });

        self.private().* = .{
            .rt_app = rt_app,
            .core_app = core_app,
            .config = config_obj,
            .scheme = .dark,
            .css_providers = css_providers,
        };
        return self;
    }

    /// Force cleanup (applications are never fully unreferenced).
    pub fn deinit(self: *Self) void {
        const priv = self.private();
        control.stop();
        priv.config.unref();
        for (priv.css_providers) |provider| {
            if (gdk.Display.getDefault()) |display| {
                gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));
            }
            provider.unref();
        }
    }

    pub fn allocator(self: *Self) Allocator {
        return self.private().core_app.alloc;
    }

    pub fn core(self: *Self) *CoreApp {
        return self.private().core_app;
    }

    pub fn rt(self: *Self) *ApprtApp {
        return self.private().rt_app;
    }

    /// The current terminal configuration, with a new reference.
    pub fn getConfig(self: *Self) *ConfigObject {
        return self.private().config.ref();
    }

    pub fn getScheme(self: *Self) termconfig.Scheme {
        return self.private().scheme;
    }

    /// Switch the terminal colour scheme (Electron: Settings › theme) for
    /// every pane, and libadwaita's light/dark to match.
    pub fn setScheme(self: *Self, scheme: termconfig.Scheme) !void {
        const priv = self.private();
        var config = try termconfig.build(self.allocator(), scheme);
        defer config.deinit();
        priv.scheme = scheme;
        self.applyStyleScheme();
        // Pushes `change_config` to every surface, then `config_change`
        // to us for the app-level copy.
        try priv.core_app.updateConfig(priv.rt_app, &config);
    }

    fn applyStyleScheme(self: *Self) void {
        const style = self.as(adw.Application).getStyleManager();
        style.setColorScheme(switch (self.private().scheme) {
            .dark => .force_dark,
            .light => .force_light,
        });
    }

    /// The window that has (or last had) focus, else any window.
    pub fn activeWindow(self: *Self) ?*Window {
        if (self.as(gtk.Application).getActiveWindow()) |w| {
            if (gobject.ext.cast(Window, w)) |win| return win;
        }
        const list: ?*glib.List = self.as(gtk.Application).getWindows();
        var it = list;
        while (it) |node| : (it = node.f_next) {
            const w: *gtk.Window = @ptrCast(@alignCast(node.f_data orelse continue));
            if (gobject.ext.cast(Window, w)) |win| return win;
        }
        return null;
    }

    /// Run until quit. Replaces `g_application_run` so the Ghostty core
    /// app can be ticked on every main-loop iteration.
    pub fn run(self: *Self) !void {
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;
        defer {
            while (glib.MainContext.iteration(ctx, 0) != 0) {}
            glib.MainContext.release(ctx);
        }

        var err_: ?*glib.Error = null;
        if (self.as(gio.Application).register(null, &err_) == 0) {
            if (err_) |err| {
                defer err.free();
                log.warn("error registering application: {s}", .{err.f_message orelse "(unknown)"});
            }
            return error.ApplicationRegisterFailed;
        }

        self.as(gio.Application).activate();

        const priv = self.private();
        log.debug("entering runloop", .{});
        defer log.debug("exiting runloop", .{});
        priv.running = true;
        while (priv.running) {
            _ = glib.MainContext.iteration(ctx, 1);
            try priv.core_app.tick(priv.rt_app);

            // Quit when the last window is gone.
            if (priv.requested_window and @as(
                ?*glib.List,
                self.as(gtk.Application).getWindows(),
            ) == null) {
                log.debug("no windows left, quitting", .{});
                self.quitNow();
            }
        }
    }

    /// Quit: destroy every window (which tears down the panes and their
    /// core surfaces) and leave the run loop. No confirmation.
    pub fn quit(self: *Self) void {
        if (!self.private().running) return;
        self.quitNow();
    }

    fn quitNow(self: *Self) void {
        const list = gtk.Window.listToplevels();
        defer list.free();
        list.foreach(struct {
            fn callback(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const window: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                // Only ours: input methods (fcitx) own toplevels of their
                // own, and destroying those double-frees.
                if (gobject.ext.isA(window, Window)) window.destroy();
            }
        }.callback, null);
        // Every tunnel and deploy step goes with the app (W-06).
        chrome.shutdown();
        self.private().running = false;
    }

    /// Open the main window (or present it: there is one main window).
    pub fn newWindow(self: *Self) *Window {
        self.private().requested_window = true;
        if (self.activeWindow()) |existing| {
            existing.as(gtk.Window).present();
            return existing;
        }
        const win = Window.new(self);
        win.as(gtk.Window).present();
        return win;
    }

    /// Called by the core, from any thread.
    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    //---------------------------------------------------------------
    // apprt actions
    //
    // Every action the core can send is listed. Returning false means
    // "not performed": for keybinding-triggered actions the key then
    // falls through to the terminal; for notifications it is ignored.

    pub fn performAction(
        self: *Self,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        const pane: ?*TerminalPane = switch (target) {
            .app => null,
            .surface => |core_surface| core_surface.rt_surface.gobj(),
        };

        switch (action) {
            // --- Application lifecycle -----------------------------------
            .quit => self.quit(),
            .new_window => _ = self.newWindow(),
            .close_window => {
                const p = pane orelse return false;
                const win = ext.getAncestor(Window, p.as(gtk.Widget)) orelse return false;
                win.as(gtk.Window).close();
            },
            // The core starts/stops this as surfaces come and go; we quit
            // when the last window closes instead (see run).
            .quit_timer => {},

            // --- Configuration -------------------------------------------
            .config_change => try self.configChange(pane, value.config),
            .reload_config => {
                // There is no config file; rebuild the built-in config.
                try self.setScheme(self.private().scheme);
            },

            // --- Terminal pane -------------------------------------------
            .render => (pane orelse return false).redraw(),
            .set_title => (pane orelse return false).setTitle(value.title),
            .pwd => (pane orelse return false).setPwd(value.pwd),
            .mouse_shape => (pane orelse return false).setMouseShape(value),
            .mouse_visibility => (pane orelse return false).setMouseHidden(value == .hidden),
            .mouse_over_link => (pane orelse return false).setMouseHoverUrl(
                if (value.url.len > 0) value.url else null,
            ),
            .cell_size => (pane orelse return false).setCellSize(value),
            .scrollbar => (pane orelse return false).setScrollbar(value),
            .renderer_health => (pane orelse return false).setRendererHealth(value),
            .ring_bell => (pane orelse return false).ringBell(),
            .present_terminal => {
                const p = pane orelse return false;
                if (ext.getAncestor(gtk.Window, p.as(gtk.Widget))) |w| w.present();
                p.grabFocus();
            },
            .copy_title_to_clipboard => {
                const p = pane orelse return false;
                const title = p.getTitle() orelse return false;
                if (title.len == 0) return false;
                p.setClipboard(.standard, &.{.{ .mime = "text/plain", .data = title }}, false);
            },
            .show_on_screen_keyboard => return (pane orelse return false).showOnScreenKeyboard(),
            // Informational; nothing in the shell reflects selection yet.
            .selection_changed, .color_change => {},
            .open_url => internal_os.open(value.kind, value.url) catch |err| {
                log.warn("unable to open url: {}", .{err});
                return false;
            },

            // --- Window state --------------------------------------------
            .toggle_fullscreen => {
                const w = windowOf(pane) orelse return false;
                if (w.isFullscreen() != 0) w.unfullscreen() else w.fullscreen();
            },
            .toggle_maximize => {
                const w = windowOf(pane) orelse return false;
                if (w.isMaximized() != 0) w.unmaximize() else w.maximize();
            },
            // The window has a fixed default size; these are sizing hints
            // for Ghostty's own windows (window-width/height config).
            .initial_size, .size_limit, .reset_window_size => return false,

            // --- Left to the core -----------------------------------------
            // Returning false makes the core print "Process exited" into
            // the terminal itself; then it closes the surface.
            .show_child_exited => return false,

            // --- Deliberately not handled: Ghostty window chrome webmux
            //     does not have (tabs, splits, quick terminal, palette).
            //     The layout strip owns panes and columns instead.
            .new_tab,
            .close_tab,
            .move_tab,
            .goto_tab,
            .move_tab_to_new_window,
            .toggle_tab_overview,
            .set_tab_title,
            .new_split,
            .goto_split,
            .resize_split,
            .equalize_splits,
            .toggle_split_zoom,
            .goto_window,
            .close_all_windows,
            .toggle_quick_terminal,
            .toggle_command_palette,
            .toggle_visibility,
            .toggle_window_decorations,
            .toggle_background_opacity,
            .float_window,
            .set_window_title,
            .resize_window,
            .prompt_title,
            => return false,

            // --- Deliberately not handled: Ghostty features the Electron
            //     client does not have (docs/native-client.md › Non-goals).
            .inspector,
            .show_gtk_inspector,
            .render_inspector,
            .export_terminal_io,
            .desktop_notification,
            .command_finished,
            .progress_report,
            .start_search,
            .end_search,
            .search_total,
            .search_selected,
            .readonly,
            .key_sequence,
            .key_table,
            .secure_input,
            .undo,
            .redo,
            => return false,

            // --- Deliberately not handled: no config file / updater. The
            //     theme is a webmux setting (setScheme), not a keybind
            //     override.
            .open_config,
            .check_for_updates,
            .set_window_theme,
            => return false,
        }

        return true;
    }

    fn windowOf(pane: ?*TerminalPane) ?*gtk.Window {
        const p = pane orelse return null;
        return ext.getAncestor(gtk.Window, p.as(gtk.Widget));
    }

    fn configChange(self: *Self, pane: ?*TerminalPane, new_config: *const CoreConfig) !void {
        const obj: *ConfigObject = try .new(self.allocator(), new_config);
        defer obj.unref();
        if (pane) |p| {
            p.setConfig(obj);
        } else {
            const priv = self.private();
            priv.config.unref();
            priv.config = obj.ref();
        }
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn startup(self: *Self) callconv(.c) void {
        gio.Application.virtual_methods.startup.call(Class.parent, self.as(Parent));
        gio.Application.setDefault(self.as(gio.Application));
        // The user-visible application name (GTK's file chooser records
        // saved files in "recently used" under it, and warns without one).
        glib.setApplicationName("webmux");
        // And the program name: GTK's recent manager writes the entry's
        // exec as g_strjoin(" ", g_get_prgname(), "%u"), which is broken
        // (invalid recently-used.xbel) when there is none (re-check N1).
        if (glib.getPrgname() == null) glib.setPrgname("webmux-gtk");

        self.applyStyleScheme();

        // Application actions. Window actions live in window.zig.
        const actions = [_]ext.actions.Action(Self){
            .init("quit", actionQuit, null),
        };
        ext.actions.add(Self, self, &actions);

        // Every feature area's iface registrations (features.zig).
        @import("features.zig").registerAll();

        // The connection engine (iface.engine), the stored settings and the
        // app.* actions of the chrome. Dev mode too: it makes no connections
        // there, but settings, the connection log and the keyring behave as
        // in the real app.
        chrome.start(self);

        // Control socket, if asked for.
        if (std.c.getenv(control.env_var)) |path_c| {
            const path = std.mem.span(path_c);
            if (path.len > 0) {
                @import("control/commands.zig").registerAll();
                control.start(path) catch |err| {
                    log.err("control socket disabled: {}", .{err});
                };
            }
        }
    }

    fn activate(self: *Self) callconv(.c) void {
        // The core turns this into a `new_window` action on its next tick.
        _ = self.private().core_app.mailbox.push(global.io(), .{
            .new_window = .{},
        }, .{ .forever = {} });
        gio.Application.virtual_methods.activate.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    fn actionQuit(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.quit();
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

        fn init(class: *Class) callconv(.c) void {
            gio.Application.virtual_methods.activate.implement(class, &activate);
            gio.Application.virtual_methods.startup.implement(class, &startup);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};

fn logDiagnostics(config: *const CoreConfig) void {
    if (config._diagnostics.empty()) return;
    var buf: [1024]u8 = undefined;
    for (config._diagnostics.items()) |diag| {
        var writer: std.Io.Writer = .fixed(&buf);
        diag.format(&writer) catch continue;
        log.err("built-in config: {s}", .{writer.buffered()});
    }
}

/// GTK environment, before GTK initializes. Ghostty renders with its own
/// EGL context; Vulkan in GTK only costs startup time and can conflict.
fn setGtkEnv() void {
    assert(gtk.isInitialized() == 0);
    if (std.c.getenv("GDK_DISABLE") == null) {
        _ = setenv("GDK_DISABLE", "vulkan", 1);
        global.syncEnviron();
    }
}

/// Route GLib/GTK log messages through Zig's logging (copied from the
/// stock application).
fn glibLogWriterFunction(
    level: glib.LogLevelFlags,
    fields: [*]const glib.LogField,
    n_fields: usize,
    _: ?*anyopaque,
) callconv(.c) glib.LogWriterOutput {
    const glib_log = std.log.scoped(.glib);

    var message_: ?[]const u8 = null;
    var domain_: ?[]const u8 = null;
    for (0..n_fields) |i| {
        const field = fields[i];
        const k = std.mem.span(field.f_key orelse continue);
        const v: []const u8 = v: {
            if (field.f_length >= 0) {
                const v: [*]const u8 = @ptrCast(field.f_value orelse continue);
                break :v v[0..@intCast(field.f_length)];
            }
            const v: [*:0]const u8 = @ptrCast(field.f_value orelse continue);
            break :v std.mem.span(v);
        };
        if (std.mem.eql(u8, k, "MESSAGE")) message_ = v;
        if (std.mem.eql(u8, k, "GLIB_DOMAIN")) domain_ = v;
    }

    const message = message_ orelse return .unhandled;
    const domain = domain_ orelse "«unknown»";

    if (level.level_error or level.level_critical) {
        glib_log.err("{s}: {s}", .{ domain, message });
    } else if (level.level_warning) {
        glib_log.warn("{s}: {s}", .{ domain, message });
    } else if (level.level_message or level.level_info) {
        glib_log.info("{s}: {s}", .{ domain, message });
    } else {
        glib_log.debug("{s}: {s}", .{ domain, message });
    }
    return .handled;
}
