//! `WebmuxPaneFrame`: the chrome around one pane (electron/ui/index.html
//! `.pane`): a title bar (type icon, title, ✕) over the pane's own widget,
//! the 1 px border and 8 px corners, the focus ring, and the unfocused
//! fade. The pane widget is the frame's body and is never drawn into.
//!
//! Drawing is arranged so that every pixel of a pane is touched as few
//! times as possible, which is what a large display on an integrated GPU
//! needs (WEBMUX.md › Performance):
//!
//!   - No rounded clip around the pane. A rounded clip costs every pixel
//!     under it a slower shader, turns into an offscreen pass as soon as
//!     a second clip meets it (the strip's in-flight clip), and keeps the
//!     terminal from being offloaded. The content is drawn square and
//!     the four corners are painted over it afterwards (`drawCorners`):
//!     the strip's background outside the arc, then the border's arc and
//!     the focus ring's.
//!   - No background under what a pane paints itself (`iface.Pane.fade`
//!     says which part of its widget that is; for a terminal, all but
//!     its scrollbar column); the panel colour is drawn behind the title
//!     bar, around that part, and behind other bodies.
//!   - The fade (index.html `.pane:not(.focused) .pane-body` + `::after`):
//!     with k = fade/100 the body is drawn at opacity 1 − 0.375k with a
//!     black layer of alpha 0.7k inside it, over the panel colour. Both
//!     layers together are `out = s·in + 0.375k·panel` with
//!     s = (1 − 0.375k)(1 − 0.7k). A pane that can apply that itself does
//!     (`iface.Pane.fade`: the terminal, in its texture's pass); what is
//!     left of the body gets one quad of alpha 1 − s. A widget opacity
//!     would make GSK render the terminal to an offscreen texture on
//!     every repaint (the reason the Electron client replaced its CSS
//!     filter with an overlay).
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
const iface = @import("../iface.zig");
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

/// `--bg` in both schemes: what shows between panes (style.css
/// workspace-strip).
pub fn stripColor(dark: bool) gdk.RGBA {
    return if (dark) rgb(0x16, 0x16, 0x1e) else rgb(0xdf, 0xe1, 0xe8);
}

/// `--border` in both schemes (style.css pane-frame).
pub fn borderColor(dark: bool) gdk.RGBA {
    return if (dark) rgb(0x34, 0x34, 0x4a) else rgb(0xc4, 0xc8, 0xd8);
}

/// `--accent` in both schemes (style.css pane-frame.focused).
pub fn accentColor(dark: bool) gdk.RGBA {
    return if (dark) rgb(0x7a, 0xa2, 0xf7) else rgb(0x2e, 0x7d, 0xe9);
}

/// The unfocused fade at strength `k` (0…1) as one affine map per colour
/// channel: `out = scale * in + add`.
pub const Fade = struct {
    scale: f32 = 1,
    add: [3]f32 = .{ 0, 0, 0 },

    pub fn of(k: f64, dark: bool) Fade {
        if (k <= 0.0005) return .{};
        const panel = panelColor(dark);
        const mix: f32 = @floatCast(0.375 * k);
        return .{
            .scale = @floatCast((1 - 0.375 * k) * (1 - 0.7 * k)),
            .add = .{ mix * panel.f_red, mix * panel.f_green, mix * panel.f_blue },
        };
    }

    pub fn none(self: Fade) bool {
        return self.scale >= 1;
    }

    /// The same map as a quad drawn over the pixels: alpha 1 − scale,
    /// colour add / alpha.
    pub fn append(self: Fade, snap: *gtk.Snapshot, rect: graphene.Rect) void {
        if (self.none() or rect.f_size.f_width <= 0 or rect.f_size.f_height <= 0) return;
        const a = 1 - self.scale;
        const c: gdk.RGBA = .{ .f_red = self.add[0] / a, .f_green = self.add[1] / a, .f_blue = self.add[2] / a, .f_alpha = a };
        snap.appendColor(&c, &rect);
    }
};

/// The black layer of the fade alone, over `rect`: for a ghost, which is
/// the panel colour already.
pub fn appendFade(snap: *gtk.Snapshot, rect: graphene.Rect, k: f64) void {
    if (k <= 0.0005) return;
    const black: gdk.RGBA = .{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = @floatCast(0.7 * k) };
    snap.appendColor(&black, &rect);
}

/// The display's refresh interval as the frame clock knows it, µs.
pub fn refreshUs(fc: *gdk.FrameClock) i64 {
    var interval: i64 = 0;
    var presentation: i64 = 0;
    fc.getRefreshInfo(fc.getFrameTime(), &interval, &presentation);
    return if (interval > 0) interval else 16667;
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
        /// The pane behind the body, if it is one (not a placeholder).
        pane: ?iface.Pane = null,
        focused: bool = false,
        /// Fade strength the frame is heading for, and where it is.
        fade_target: f64 = 0,
        fade_from: f64 = 0,
        fade_now: f64 = 0,
        /// Frame clock time the transition began; null until its first
        /// tick (the clock's time is stale while it is idle).
        fade_start_us: ?i64 = null,
        fade_tick: c_uint = 0,
        /// A child was allocated more than the frame has (its minimum
        /// size): the children are clipped to the frame.
        overflows: bool = false,
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

    /// Parent the pane's widget (or a placeholder, `pane` null) as the
    /// body.
    pub fn setBody(self: *Self, w: *gtk.Widget, pane: ?iface.Pane) void {
        const priv = self.private();
        std.debug.assert(priv.body == null);
        w.setParent(self.as(gtk.Widget));
        priv.body = w;
        priv.pane = pane;
        _ = self.applyFade();
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
            _ = self.applyFade();
            w.queueDraw();
            return;
        }
        priv.fade_from = priv.fade_now;
        priv.fade_start_us = null;
        if (priv.fade_tick == 0) priv.fade_tick = w.addTickCallback(fadeTick, null, null);
    }

    /// Hand the fade as it is now to the pane. Returns the part of the
    /// frame the pane paints and fades itself (frame coordinates), if
    /// any.
    fn applyFade(self: *Self) ?graphene.Rect {
        const priv = self.private();
        const pane = priv.pane orelse return null;
        const f = Fade.of(priv.fade_now, isDark());
        const own = pane.fade(f.scale, f.add) orelse return null;
        return .{
            .f_origin = .{ .f_x = @floatCast(own.x), .f_y = @floatCast(own.y + @as(f64, @floatFromInt(priv.bar_height))) },
            .f_size = .{ .f_width = @floatCast(own.w), .f_height = @floatCast(own.h) },
        };
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
        // The frame clock's time, so the steps are as even as the frames;
        // the first tick shows one refresh of progress.
        const now = fc.getFrameTime();
        const start = priv.fade_start_us orelse blk: {
            const s0 = now - refreshUs(fc);
            priv.fade_start_us = s0;
            break :blk s0;
        };
        const ms = @as(f64, @floatFromInt(now - start)) / 1000;
        const x = ms / (anim.fade_ms * Workspace.time_scale);
        if (x >= 1) {
            priv.fade_now = priv.fade_target;
            priv.fade_tick = 0;
            _ = self.applyFade();
            w.queueDraw();
            return 0;
        }
        priv.fade_now = priv.fade_from + (priv.fade_target - priv.fade_from) * anim.cssEase(x);
        _ = self.applyFade();
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
        var overflows = wmin > width;
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
            overflows = overflows or mw > width or m > height - bh;
        }
        priv.overflows = overflows;
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const w = self.as(gtk.Widget);
        const priv = self.private();
        const dark = isDark();
        const width: f32 = @floatFromInt(w.getWidth());
        const height: f32 = @floatFromInt(w.getHeight());
        const bar_h: f32 = @floatFromInt(priv.bar_height);
        const body_rect: graphene.Rect = .{
            .f_origin = .{ .f_x = 0, .f_y = bar_h },
            .f_size = .{ .f_width = width, .f_height = @max(0, height - bar_h) },
        };

        // Children only reach past the frame when it is smaller than
        // their minimum size; a clip is needed for that case alone.
        const clip = priv.overflows;
        if (clip) snap.pushClip(&.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = width, .f_height = height } });

        // The panel colour: behind the bar, and behind whatever of the
        // body the pane does not cover with pixels of its own (for a
        // terminal that leaves its scrollbar column).
        const panel = panelColor(dark);
        const fade = Fade.of(priv.fade_now, dark);
        const own: ?graphene.Rect = if (priv.body != null) self.applyFade() else null;
        if (own) |o| {
            snap.appendColor(&panel, &.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = width, .f_height = @min(bar_h, height) } });
            for (around(body_rect, o)) |r| appendRect(snap, &panel, r);
        } else {
            snap.appendColor(&panel, &.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = width, .f_height = height } });
        }

        w.snapshotChild(priv.bar.as(gtk.Widget), snap);
        self.drawIcon(snap);
        if (priv.body) |b| {
            w.snapshotChild(b, snap);
            // The pane fades `own` itself; a quad for the rest.
            if (own) |o| {
                for (around(body_rect, o)) |r| fade.append(snap, r);
            } else {
                fade.append(snap, body_rect);
            }
        }
        if (clip) snap.pop();
        self.drawCorners(snap, dark);
    }

    /// What is left of `outer` around `inner`: the bands above and below
    /// it, then left and right of it. Empty ones have no size.
    fn around(outer: graphene.Rect, inner: graphene.Rect) [4]graphene.Rect {
        const x0 = outer.f_origin.f_x;
        const y0 = outer.f_origin.f_y;
        const x1 = x0 + outer.f_size.f_width;
        const y1 = y0 + outer.f_size.f_height;
        const l = std.math.clamp(inner.f_origin.f_x, x0, x1);
        const r = std.math.clamp(inner.f_origin.f_x + inner.f_size.f_width, l, x1);
        const t = std.math.clamp(inner.f_origin.f_y, y0, y1);
        const b = std.math.clamp(inner.f_origin.f_y + inner.f_size.f_height, t, y1);
        return .{
            .{ .f_origin = .{ .f_x = x0, .f_y = y0 }, .f_size = .{ .f_width = x1 - x0, .f_height = t - y0 } },
            .{ .f_origin = .{ .f_x = x0, .f_y = b }, .f_size = .{ .f_width = x1 - x0, .f_height = y1 - b } },
            .{ .f_origin = .{ .f_x = x0, .f_y = t }, .f_size = .{ .f_width = l - x0, .f_height = b - t } },
            .{ .f_origin = .{ .f_x = r, .f_y = t }, .f_size = .{ .f_width = x1 - r, .f_height = b - t } },
        };
    }

    fn appendRect(snap: *gtk.Snapshot, color: *const gdk.RGBA, r: graphene.Rect) void {
        if (r.f_size.f_width <= 0 or r.f_size.f_height <= 0) return;
        snap.appendColor(color, &r);
    }

    /// The rounded corners, painted over the square content: per corner,
    /// the strip's background outside the border's arc, the focus ring's
    /// arc (which that just covered) and the border's own arc (which the
    /// content covered).
    fn drawCorners(self: *Self, snap: *gtk.Snapshot, dark: bool) void {
        const w = self.as(gtk.Widget);
        const priv = self.private();
        const width: f32 = @floatFromInt(w.getWidth());
        const height: f32 = @floatFromInt(w.getHeight());
        // Widget coordinates start at the content box; the 1 px border
        // (style.css) is outside it.
        const border: f32 = 1;
        const radius: f32 = @floatCast(anim.pane_radius);
        const ring: f32 = if (priv.focused) 1 else 0;
        const box: graphene.Rect = .{
            .f_origin = .{ .f_x = -border, .f_y = -border },
            .f_size = .{ .f_width = width + 2 * border, .f_height = height + 2 * border },
        };
        if (box.f_size.f_width < 2 * radius or box.f_size.f_height < 2 * radius) return;
        var outline: gsk.RoundedRect = undefined;
        _ = outline.initFromRect(&box, radius);
        const strip = stripColor(dark);
        const edge = if (priv.focused) accentColor(dark) else borderColor(dark);
        const widths: [4]f32 = @splat(border);
        const colors: [4]gdk.RGBA = @splat(edge);
        const size = radius + ring;
        const x0 = box.f_origin.f_x - ring;
        const y0 = box.f_origin.f_y - ring;
        const x1 = box.f_origin.f_x + box.f_size.f_width + ring - size;
        const y1 = box.f_origin.f_y + box.f_size.f_height + ring - size;
        const corners = [4]graphene.Point{
            .{ .f_x = x0, .f_y = y0 },
            .{ .f_x = x1, .f_y = y0 },
            .{ .f_x = x0, .f_y = y1 },
            .{ .f_x = x1, .f_y = y1 },
        };
        for (corners) |c| {
            snap.pushClip(&.{ .f_origin = c, .f_size = .{ .f_width = size, .f_height = size } });
            snap.appendOutsetShadow(&outline, &strip, 0, 0, radius, 0);
            if (priv.focused) snap.appendOutsetShadow(&outline, &edge, 0, 0, ring, 0);
            snap.appendBorder(&outline, &widths, &colors);
            snap.pop();
        }
    }

    // --- GObject ----------------------------------------------------------

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.* = .{};
        const w = self.as(gtk.Widget);
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
