//! `WebmuxPaneFrame`: the chrome around one pane (electron/ui/index.html
//! `.pane`): a title bar (type icon, title, ✕) over the pane's own widget,
//! the 1 px border and 8 px corners, the focus ring, and the unfocused
//! fade. The pane widget is the frame's body and is never drawn into: the
//! fade is two colour quads appended over it.
//!
//! The fade (index.html `.pane:not(.focused) .pane-body` + `::after`): with
//! k = fade/100 the body is drawn at opacity 1 − 0.375k with a black layer
//! of alpha 0.7k inside it. A widget opacity would make GSK render the
//! terminal to an offscreen texture on every repaint (the reason the
//! Electron client replaced its CSS filter with an overlay), so the same
//! pixels come from quads instead: black at 0.7k over the body, then the
//! panel colour at 0.375k (the body sits on the panel, so "opacity α over
//! the panel" is the panel at 1 − α on top). At k = 0 nothing is appended.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");
const gsk = @import("gsk.zig");
const files_title = @import("../files/title.zig");

const Common = @import("../class.zig").Common;
const anim = @import("anim.zig");
const layout = @import("../../../webmux/layout.zig");
const Workspace = @import("workspace.zig").Workspace;

pub const Kind = layout.Kind;

/// `--panel` in both schemes (index.html :root / [data-theme=light]).
pub fn panelColor(dark: bool) gdk.RGBA {
    return if (dark) rgb(0x1f, 0x1f, 0x2b) else rgb(0xf4, 0xf5, 0xf9);
}

pub fn rgb(r: u8, g: u8, b: u8) gdk.RGBA {
    return .{ .f_red = @as(f32, @floatFromInt(r)) / 255, .f_green = @as(f32, @floatFromInt(g)) / 255, .f_blue = @as(f32, @floatFromInt(b)) / 255, .f_alpha = 1 };
}

pub fn isDark() bool {
    return adw.StyleManager.getDefault().getDark() != 0;
}

/// Append the unfocused fade over `rect` at strength `k` (0…1).
pub fn appendFade(snap: *gtk.Snapshot, rect: graphene.Rect, k: f64, with_body_opacity: bool) void {
    if (k <= 0.0005) return;
    const black: gdk.RGBA = .{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = @floatCast(0.7 * k) };
    snap.appendColor(&black, &rect);
    if (with_body_opacity) {
        var panel = panelColor(isDark());
        panel.f_alpha = @floatCast(0.375 * k);
        snap.appendColor(&panel, &rect);
    }
}

pub const PaneFrame = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxPaneFrame",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The workspace that owns this frame (its parent); cleared when
        /// the frame leaves the layout.
        owner: ?*Workspace = null,
        id: [:0]u8 = undefined,
        kind: Kind = .terminal,
        bar: *gtk.Box = undefined,
        icon: *gtk.Widget = undefined,
        label: *gtk.Label = undefined,
        close: *gtk.Button = undefined,
        body: ?*gtk.Widget = null,
        focused: bool = false,
        /// Fade strength the frame is heading for, and where it is.
        fade_target: f64 = 0,
        fade_from: f64 = 0,
        fade_now: f64 = 0,
        fade_start_us: i64 = 0,
        fade_tick: c_uint = 0,
        /// The fade jumps instead of easing (reduced motion).
        instant: bool = false,
        bar_height: c_int = 0,
        /// File browsers (F-15): the full title (the label shows it
        /// fitted by files/title.zig), the label width it was fitted to,
        /// and a pending re-fit after a resize.
        full_title: ?[:0]u8 = null,
        fit_width: c_int = -1,
        fit_idle: c_uint = 0,

        pub var offset: c_int = 0;
    };

    pub fn new(owner: *Workspace, pane_id: []const u8, kind: Kind) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.owner = owner;
        priv.id = std.heap.c_allocator.dupeSentinel(u8, pane_id, 0) catch @panic("OOM");
        priv.kind = kind;
        priv.label.setText(priv.id.ptr);
        const bar_tip: [:0]const u8 = if (kind == .files) "file browser" else blk: {
            var buf: [256]u8 = undefined;
            break :blk std.fmt.bufPrintSentinel(&buf, "session {s}", .{pane_id}, 0) catch "session";
        };
        priv.bar.as(gtk.Widget).setTooltipText(bar_tip.ptr);
        priv.close.as(gtk.Widget).setTooltipText(if (kind == .files) "Close" else "Kill session");
        return self;
    }

    pub fn id(self: *Self) []const u8 {
        return self.private().id;
    }

    /// Parent the pane's widget (or a placeholder) as the body.
    pub fn setBody(self: *Self, w: *gtk.Widget) void {
        const priv = self.private();
        std.debug.assert(priv.body == null);
        w.setParent(self.as(gtk.Widget));
        priv.body = w;
    }

    pub fn body(self: *Self) ?*gtk.Widget {
        return self.private().body;
    }

    pub fn setTitle(self: *Self, text: [:0]const u8) void {
        const priv = self.private();
        const lbl = priv.label;
        if (priv.kind == .files) {
            if (priv.full_title) |f| if (std.mem.eql(u8, f, text)) return;
            const copy = std.heap.c_allocator.dupeSentinel(u8, text, 0) catch return;
            if (priv.full_title) |f| std.heap.c_allocator.free(f);
            priv.full_title = copy;
            self.refitTitle();
            return;
        }
        if (std.mem.eql(u8, std.mem.span(lbl.getText()), text)) return;
        lbl.setText(text.ptr);
    }

    pub fn title(self: *Self) [:0]const u8 {
        const priv = self.private();
        if (priv.full_title) |f| return f;
        return std.mem.span(priv.label.getText());
    }

    /// File browsers: fit the full path into the label's width (F-15).
    fn refitTitle(self: *Self) void {
        const priv = self.private();
        const full = priv.full_title orelse return;
        priv.fit_width = priv.label.as(gtk.Widget).getWidth();
        files_title.fit(priv.label, full, null);
    }

    fn refitIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        defer self.unref();
        self.private().fit_idle = 0;
        self.refitTitle();
        return 0;
    }

    /// The frame leaves the layout (closing animation, then gone): no more
    /// input, no more calls into the workspace.
    pub fn detach(self: *Self) void {
        const priv = self.private();
        priv.owner = null;
        const w = self.as(gtk.Widget);
        w.setCanTarget(0);
        w.setCanFocus(0);
    }

    pub fn isFocused(self: *Self) bool {
        return self.private().focused;
    }

    /// Focus ring and fade. `k` is the fade strength for an unfocused pane
    /// (settings › unfocused fade / 100).
    pub fn setFocused(self: *Self, focused: bool, k: f64, instant: bool) void {
        const priv = self.private();
        const w = self.as(gtk.Widget);
        if (focused != priv.focused) {
            priv.focused = focused;
            if (focused) w.addCssClass("focused") else w.removeCssClass("focused");
        }
        priv.instant = instant;
        self.setFadeTarget(if (focused) 0 else k);
    }

    fn setFadeTarget(self: *Self, target: f64) void {
        const priv = self.private();
        if (target == priv.fade_target and (priv.fade_tick != 0 or priv.fade_now == target)) return;
        priv.fade_target = target;
        const w = self.as(gtk.Widget);
        if (priv.instant or w.getMapped() == 0) {
            priv.fade_now = target;
            self.stopFadeTick();
            w.queueDraw();
            return;
        }
        priv.fade_from = priv.fade_now;
        priv.fade_start_us = glib.getMonotonicTime();
        if (priv.fade_tick == 0) priv.fade_tick = w.addTickCallback(fadeTick, null, null);
    }

    fn stopFadeTick(self: *Self) void {
        const priv = self.private();
        if (priv.fade_tick != 0) {
            self.as(gtk.Widget).removeTickCallback(priv.fade_tick);
            priv.fade_tick = 0;
        }
    }

    fn fadeTick(w: *gtk.Widget, fc: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
        const self = gobject.ext.cast(Self, w).?;
        const priv = self.private();
        _ = fc;
        const ms = @as(f64, @floatFromInt(glib.getMonotonicTime() - priv.fade_start_us)) / 1000;
        const x = ms / (anim.fade_ms * Workspace.time_scale);
        if (x >= 1) {
            priv.fade_now = priv.fade_target;
            priv.fade_tick = 0;
            w.queueDraw();
            return 0;
        }
        priv.fade_now = priv.fade_from + (priv.fade_target - priv.fade_from) * anim.cssEase(x);
        w.queueDraw();
        return 1;
    }

    /// Fade strength currently drawn (0 for the focused pane once its
    /// transition ends).
    pub fn fadeNow(self: *Self) f64 {
        return self.private().fade_now;
    }

    pub fn barHeight(self: *Self) c_int {
        return self.private().bar_height;
    }

    // --- input ---------------------------------------------------------

    /// Any press inside the frame focuses the pane first (app.js
    /// pointerdown capture → setFocus). Not claimed: the click goes on.
    fn gcPressed(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Self) callconv(.c) void {
        self.pressed();
    }

    pub fn pressed(self: *Self) void {
        const owner = self.private().owner orelse return;
        owner.paneClicked(self.id());
    }

    /// A click on the bar (not ✕) moves keyboard focus into the content.
    fn barReleased(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Self) callconv(.c) void {
        self.barClicked();
    }

    pub fn barClicked(self: *Self) void {
        const owner = self.private().owner orelse return;
        owner.paneBarClicked(self.id());
    }

    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.closeButton();
    }

    pub fn closeButton(self: *Self) void {
        const owner = self.private().owner orelse return;
        owner.paneCloseClicked(self.id());
    }

    // --- the type icon (app.js PANE_ICON_SVG: 11 px, stroke 2 of 24) ---

    const icon_paths = struct {
        const terminal: [:0]const u8 = "M 4 17 L 10 11 L 4 5 M 12 19 L 20 19";
        const files: [:0]const u8 = "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z";
    };

    fn drawIcon(self: *Self, snap: *gtk.Snapshot) void {
        const priv = self.private();
        const icon = priv.icon;
        var b: graphene.Rect = undefined;
        if (icon.computeBounds(self.as(gtk.Widget), &b) == 0) return;
        const path = gsk.Path.parse(switch (priv.kind) {
            .terminal => icon_paths.terminal,
            .files => icon_paths.files,
        }) orelse return;
        defer path.unref();
        const stroke = gsk.Stroke.new(2);
        defer stroke.free();
        stroke.setLineCap(.round);
        stroke.setLineJoin(.round);
        var color: gdk.RGBA = undefined;
        priv.label.as(gtk.Widget).getColor(&color);
        color.f_alpha *= 0.55;
        const size = @min(b.f_size.f_width, b.f_size.f_height);
        snap.save();
        var o: graphene.Point = .{ .f_x = b.f_origin.f_x + (b.f_size.f_width - size) / 2, .f_y = b.f_origin.f_y + (b.f_size.f_height - size) / 2 };
        snap.translate(&o);
        snap.scale(size / 24, size / 24);
        snap.appendStroke(path, stroke, &color);
        snap.restore();
    }

    // --- layout and drawing ----------------------------------------------

    fn measure(
        _: *Self,
        _: gtk.Orientation,
        _: c_int,
        minimum: ?*c_int,
        natural: ?*c_int,
        min_baseline: ?*c_int,
        nat_baseline: ?*c_int,
    ) callconv(.c) void {
        // The strip decides every pane's size; nothing here may push back.
        if (minimum) |m| m.* = 0;
        if (natural) |n| n.* = 0;
        if (min_baseline) |b| b.* = -1;
        if (nat_baseline) |b| b.* = -1;
    }

    fn sizeAllocate(self: *Self, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        const priv = self.private();
        const bar = priv.bar.as(gtk.Widget);
        var bmin: c_int = 0;
        var bnat: c_int = 0;
        bar.measure(.vertical, width, &bmin, &bnat, null, null);
        var wmin: c_int = 0;
        bar.measure(.horizontal, -1, &wmin, null, null, null);
        const bh = @min(bnat, height);
        priv.bar_height = bh;
        bar.allocate(@max(width, wmin), bh, -1, null);
        // A file browser's title is re-fitted when its label changes width
        // (outside the allocation: fitting changes the label's text).
        if (priv.full_title != null and priv.fit_idle == 0 and priv.label.as(gtk.Widget).getWidth() != priv.fit_width) {
            priv.fit_idle = glib.idleAdd(refitIdle, self.ref());
        }
        if (priv.body) |b| {
            var m: c_int = 0;
            b.measure(.vertical, width, &m, null, null, null);
            var mw: c_int = 0;
            b.measure(.horizontal, -1, &mw, null, null, null);
            var p: graphene.Point = .{ .f_x = 0, .f_y = @floatFromInt(bh) };
            const t = gsk.Transform.translate(null, &p);
            b.allocate(@max(width, mw), @max(height - bh, m), -1, t);
        }
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const w = self.as(gtk.Widget);
        const priv = self.private();
        w.snapshotChild(priv.bar.as(gtk.Widget), snap);
        self.drawIcon(snap);
        const b = priv.body orelse return;
        w.snapshotChild(b, snap);
        const k = priv.fade_now;
        if (k > 0.0005) {
            const rect: graphene.Rect = .{
                .f_origin = .{ .f_x = 0, .f_y = @floatFromInt(priv.bar_height) },
                .f_size = .{ .f_width = @floatFromInt(w.getWidth()), .f_height = @floatFromInt(@max(0, w.getHeight() - priv.bar_height)) },
            };
            appendFade(snap, rect, k, true);
        }
    }

    // --- GObject ----------------------------------------------------------

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.* = .{};
        const w = self.as(gtk.Widget);
        w.setOverflow(.hidden);
        w.setFocusable(0);

        const bar = gtk.Box.new(.horizontal, 4);
        bar.as(gtk.Widget).addCssClass("pane-bar");
        priv.bar = bar;

        // Drawn by the frame (drawIcon) in this box's place.
        const icon = gtk.Box.new(.horizontal, 0).as(gtk.Widget);
        icon.setSizeRequest(11, 11);
        icon.addCssClass("pane-icon");
        icon.setValign(.center);
        priv.icon = icon;
        bar.append(icon);

        const label = gtk.Label.new("");
        label.setEllipsize(.end);
        label.setXalign(0);
        label.setSingleLineMode(1);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("pane-label");
        priv.label = label;
        bar.append(label.as(gtk.Widget));

        const close = gtk.Button.newWithLabel("✕");
        close.as(gtk.Widget).addCssClass("pane-close");
        close.as(gtk.Widget).setFocusable(0);
        close.as(gtk.Widget).setFocusOnClick(0);
        close.as(gtk.Widget).setValign(.center);
        close.as(gtk.Widget).setCursorFromName("pointer");
        _ = gtk.Button.signals.clicked.connect(close, *Self, closeClicked, self, .{});
        priv.close = close;
        bar.append(close.as(gtk.Widget));

        const bar_click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.released.connect(bar_click, *Self, barReleased, self, .{});
        bar.as(gtk.Widget).addController(bar_click.as(gtk.EventController));

        bar.as(gtk.Widget).setParent(w);

        const press = gtk.GestureClick.new();
        press.as(gtk.GestureSingle).setButton(0);
        press.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureClick.signals.pressed.connect(press, *Self, gcPressed, self, .{});
        w.addController(press.as(gtk.EventController));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.stopFadeTick();
        priv.owner = null;
        if (priv.body) |b| {
            b.unparent();
            priv.body = null;
        }
        var child = self.as(gtk.Widget).getFirstChild();
        while (child) |c| {
            child = c.getNextSibling();
            c.unparent();
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        std.heap.c_allocator.free(self.private().id);
        if (self.private().full_title) |f| std.heap.c_allocator.free(f);
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
            const wc = class.as(gtk.Widget.Class);
            gtk.Widget.Class.setCssName(wc, "pane-frame");
            gtk.Widget.virtual_methods.measure.implement(class, &measure);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
