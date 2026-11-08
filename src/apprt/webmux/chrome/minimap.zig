//! The pane minimap inside a host pill (deviation 73): the workspace's
//! `iface.Minimap` drawn as rounded boxes, the focused pane in the accent
//! colour (the host in front) or a stronger foreground (a host behind),
//! and the viewport outline when the strip scrolls. The widget is as big
//! as its map; the pill hides it while the map is empty. Clicks are the
//! pill's: it asks `paneAt` for the pane under the pointer.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gsk = @import("../workspace/gsk.zig");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const Common = @import("../class.zig").Common;

const alloc = std.heap.c_allocator;

pub const Minimap = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxHostMinimap",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        map: iface.Minimap = .empty,
        /// The host is in front: the focused pane in the accent colour.
        emphasized: bool = true,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    /// Take `map` (owned from now on) and redraw; the widget resizes when
    /// the map's size changed.
    pub fn set(self: *Self, new_map: iface.Minimap) void {
        const priv = self.private();
        const resized = new_map.width != priv.map.width or new_map.height != priv.map.height;
        priv.map.deinit(alloc);
        priv.map = new_map;
        const w = self.as(gtk.Widget);
        if (resized) w.queueResize();
        w.queueDraw();
    }

    pub fn map(self: *Self) *const iface.Minimap {
        return &self.private().map;
    }

    pub fn setEmphasized(self: *Self, on: bool) void {
        const priv = self.private();
        if (priv.emphasized == on) return;
        priv.emphasized = on;
        self.as(gtk.Widget).queueDraw();
    }

    /// The pane under a point in widget coordinates.
    pub fn paneAt(self: *Self, x: f64, y: f64) ?[]const u8 {
        return self.private().map.paneAt(x, y);
    }

    fn measure(
        self: *Self,
        orientation: gtk.Orientation,
        _: c_int,
        minimum: ?*c_int,
        natural: ?*c_int,
        min_baseline: ?*c_int,
        nat_baseline: ?*c_int,
    ) callconv(.c) void {
        const m = &self.private().map;
        const size: c_int = @intFromFloat(@ceil(if (orientation == .horizontal) m.width else m.height));
        if (minimum) |p| p.* = size;
        if (natural) |p| p.* = size;
        if (min_baseline) |b| b.* = -1;
        if (nat_baseline) |b| b.* = -1;
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const priv = self.private();
        const m = &priv.map;
        if (m.isEmpty()) return;
        var fg: gdk.RGBA = undefined;
        self.as(gtk.Widget).getColor(&fg);
        const idle = withAlpha(fg, 0.28);
        const focus = if (priv.emphasized) accent() else withAlpha(fg, 0.6);
        for (m.cells) |c| {
            fillRounded(snap, rect(c.rect), 1.5, if (c.focused) focus else idle);
        }
        if (m.viewport) |v| {
            var rr: gsk.RoundedRect = undefined;
            _ = rr.initFromRect(&rect(.{ .x = v.x + 0.5, .y = v.y, .w = v.w - 1, .h = v.h }), 2.5);
            const widths: [4]f32 = @splat(1);
            const colors: [4]gdk.RGBA = @splat(withAlpha(fg, 0.55));
            snap.appendBorder(&rr, &widths, &colors);
        }
    }

    fn fillRounded(snap: *gtk.Snapshot, r: graphene.Rect, radius: f32, color: gdk.RGBA) void {
        var rr: gsk.RoundedRect = undefined;
        _ = rr.initFromRect(&r, radius);
        snap.pushRoundedClip(&rr);
        snap.appendColor(&color, &r);
        snap.pop();
    }

    fn rect(r: iface.Minimap.Rect) graphene.Rect {
        return .{
            .f_origin = .{ .f_x = @floatCast(r.x), .f_y = @floatCast(r.y) },
            .f_size = .{ .f_width = @floatCast(@max(0, r.w)), .f_height = @floatCast(@max(0, r.h)) },
        };
    }

    fn withAlpha(c: gdk.RGBA, a: f32) gdk.RGBA {
        return .{ .f_red = c.f_red, .f_green = c.f_green, .f_blue = c.f_blue, .f_alpha = a };
    }

    /// libadwaita's accent colour for the current scheme.
    fn accent() gdk.RGBA {
        const c = adw.StyleManager.getDefault().getAccentColorRgba();
        defer c.free();
        return c.*;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().* = .{};
        const w = self.as(gtk.Widget);
        w.setHalign(.center);
        w.setValign(.center);
        w.setFocusable(0);
        w.setCanTarget(1);
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().map.deinit(alloc);
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        pub const as = C.Class.as;

        fn init(class: *Class) callconv(.c) void {
            const wc = class.as(gtk.Widget.Class);
            gtk.Widget.Class.setCssName(wc, "host-minimap");
            gtk.Widget.virtual_methods.measure.implement(class, &measure);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
