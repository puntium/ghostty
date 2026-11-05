//! `WebmuxWindow`: the main window. Its content is the chrome's frame
//! (chrome/hub.zig `populate`: header strip + one content view: the
//! connection page or a host's view), or in dev mode the single dev
//! connection view (dev.zig).
//!
//! The window owns keyboard shortcuts: a capture-phase key controller sees
//! every key before the focused widget and dispatches shortcuts.zig.

const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("class.zig").Common;
const Application = @import("application.zig").Application;
const TerminalPane = @import("pane.zig").TerminalPane;
const KeyEvent = @import("key_event.zig").KeyEvent;
const shortcuts = @import("shortcuts.zig");
const dev = @import("dev.zig");
const chrome = @import("chrome/hub.zig");
const ext = @import("ext.zig");

const log = std.log.scoped(.webmux_window);

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    /// Electron: `new BaseWindow({ width: 1400, height: 900 })`.
    pub const default_width = 1400;
    pub const default_height = 900;

    const Private = struct {
        _unused: u8 = 0,
        pub var offset: c_int = 0;
    };

    pub fn new(app: *Application) *Self {
        const self = gobject.ext.newInstance(Self, .{ .application = app });

        // Dev mode: one connection view on a local host socket (dev.zig).
        if (dev.socketPath() != null) {
            self.as(gtk.Window).setTitle("webmux (dev)");
            dev.populate(self);
        } else {
            // The application: header strip + connection page (W-02, W-04).
            chrome.populate(self);
        }
        // The status toast (panels) over whatever the content is.
        @import("panels/toast.zig").adoptWindow(self.as(adw.ApplicationWindow));
        return self;
    }

    /// Replace the window's content (dev mode, and later the chrome).
    pub fn setBody(self: *Self, widget: *gtk.Widget) void {
        self.as(adw.ApplicationWindow).setContent(widget);
    }

    /// Replace the content with a one-line status message.
    pub fn showStatus(self: *Self, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "…";
        const label = gtk.Label.new(text.ptr);
        label.as(gtk.Widget).addCssClass("dim-label");
        label.setWrap(1);
        self.setBody(label.as(gtk.Widget));
    }

    /// The terminal pane that has keyboard focus, else the first one.
    pub fn focusedPane(self: *Self) ?*TerminalPane {
        if (self.as(gtk.Window).getFocus()) |w| {
            if (ext.getAncestor(TerminalPane, w)) |p| return p;
        }
        var buf: [1]*TerminalPane = undefined;
        const found = self.panes(&buf);
        return if (found.len > 0) found[0] else null;
    }

    /// The terminal panes in this window's widget tree (at most
    /// `buf.len`): those in visible widgets first (the front host), then
    /// the hidden ones (other hosts' views), each in tree order. Works for
    /// whatever content the window has.
    pub fn panes(self: *Self, buf: []*TerminalPane) []*TerminalPane {
        var n: usize = 0;
        collectPanes(self.as(gtk.Widget), buf, &n, .visible);
        collectPanes(self.as(gtk.Widget), buf, &n, .hidden);
        return buf[0..n];
    }

    const Pass = enum { visible, hidden };

    fn collectPanes(widget: *gtk.Widget, buf: []*TerminalPane, n: *usize, pass: Pass) void {
        if (n.* >= buf.len) return;
        if (gobject.ext.cast(TerminalPane, widget)) |p| {
            const shown = p.as(gtk.Widget).isVisible() != 0 and p.as(gtk.Widget).getMapped() != 0;
            if (shown == (pass == .visible)) {
                buf[n.*] = p;
                n.* += 1;
            }
            return;
        }
        var child = widget.getFirstChild();
        while (child) |c| : (child = c.getNextSibling()) collectPanes(c, buf, n, pass);
    }

    /// Feed a key event through the same path a real one takes: shortcuts
    /// first, then the focused pane. Used for synthesized keys.
    pub fn dispatchKey(self: *Self, ev: KeyEvent) bool {
        if (self.matchShortcut(ev)) return true;
        // Like a real key: only a terminal that has the focus gets it (a
        // focused file browser, text field or dialog is not a terminal;
        // synthesized keys cannot reach those).
        if (self.as(gtk.Window).getFocus()) |f| {
            if (ext.getAncestor(TerminalPane, f) == null) return false;
        }
        const pane = self.focusedPane() orelse return false;
        return pane.handleKey(ev);
    }

    fn matchShortcut(self: *Self, ev: KeyEvent) bool {
        if (ev.action == .release or ev.is_modifier) return false;
        const widget = self.as(gtk.Widget);
        const chord: shortcuts.Chord = .{
            .keyval = ev.baseKeyval(widget.getDisplay()),
            .mods = .fromGdk(ev.state),
            .code = ev.physicalCode(),
        };
        const target = self.as(gtk.Window).getFocus() orelse widget;
        return shortcuts.dispatch(target, chord);
    }

    fn ecKeyPressed(
        ec: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const ev = KeyEvent.fromController(ec, .press, keyval, keycode, state) orelse return 0;
        return @intFromBool(self.matchShortcut(ev));
    }


    /// An in-window AdwDialog (settings, link chooser) takes a GTK grab
    /// while it is up: key events then propagate from the dialog, not the
    /// window, so the window's capture controller never sees them. Give
    /// every dialog the same capture controller when it is presented, so
    /// app shortcuts keep working over it (deviation 31) and pane chords
    /// are swallowed there (K-18, by `shortcuts.dispatch`).
    fn visibleDialogChanged(win: *adw.ApplicationWindow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const dialog = win.getVisibleDialog() orelse return;
        const obj = dialog.as(gobject.Object);
        if (obj.getData("webmux-shortcuts") != null) return;
        obj.setData("webmux-shortcuts", self);
        const ec = gtk.EventControllerKey.new();
        ec.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(ec, *Self, ecKeyPressed, self, .{});
        dialog.as(gtk.Widget).addController(ec.as(gtk.EventController));
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().* = .{};
        const win = self.as(gtk.Window);
        self.as(gtk.Widget).addCssClass("wm-main");
        win.setTitle("webmux");
        win.setDefaultSize(default_width, default_height);

        const ec = gtk.EventControllerKey.new();
        ec.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(ec, *Self, ecKeyPressed, self, .{});
        self.as(gtk.Widget).addController(ec.as(gtk.EventController));
        _ = gobject.Object.signals.notify.connect(self.as(adw.ApplicationWindow), *Self, visibleDialogChanged, self, .{ .detail = "visible-dialog" });
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
            gobject.ext.ensureType(TerminalPane);
            _ = class;
        }
    };
};
