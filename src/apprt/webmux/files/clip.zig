//! `WebmuxFilesClip`: one Miller column's box in the strip. It has an
//! explicit, animatable width and clips its child, which is what the CSS
//! enter/leave/width animations of index.html need: a column grows from
//! zero width while fading in, collapses to zero while fading out, a
//! same-slot swap fades in, and the preview column eases between 600 and
//! 280 px. During enter/leave the child keeps its full width (it slides
//! under the clip instead of reflowing); during a width change it follows
//! the current width, as a CSS width transition reflows.
//!
//! The browser drives every clip from one tick callback (`tick`).
const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;

pub const Ease = enum { out, in, linear };

pub const Clip = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxFilesClip",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Anim = struct {
        t0: i64 = 0, // µs, frame clock time; 0 = starts on the next tick
        dur: i64,
        ease: Ease,
        from_w: f64,
        to_w: f64,
        from_op: f64,
        to_op: f64,
        /// The child follows the current width (else: the target).
        reflow: bool,
    };

    const Private = struct {
        child: ?*gtk.Widget = null,
        width: f64 = 0,
        target: f64 = 0,
        reflow: bool = true,
        anim: ?Anim = null,
        pub var offset: c_int = 0;
    };

    pub fn new(child: *gtk.Widget, width: f64) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.width = width;
        priv.target = width;
        self.setChild(child);
        return self;
    }

    pub fn setChild(self: *Self, child: ?*gtk.Widget) void {
        const priv = self.private();
        if (priv.child) |old| old.unparent();
        priv.child = child;
        if (child) |c| c.setParent(self.as(gtk.Widget));
    }

    pub fn getChild(self: *Self) ?*gtk.Widget {
        return self.private().child;
    }

    pub fn currentWidth(self: *Self) f64 {
        return self.private().width;
    }

    pub fn targetWidth(self: *Self) f64 {
        return self.private().target;
    }

    pub fn animating(self: *Self) bool {
        return self.private().anim != null;
    }

    /// Jump to `w` with no animation.
    pub fn setWidth(self: *Self, w: f64) void {
        const priv = self.private();
        priv.anim = null;
        priv.width = w;
        priv.target = w;
        priv.reflow = true;
        self.as(gtk.Widget).setOpacity(1);
        self.as(gtk.Widget).queueResize();
    }

    /// Grow from 0 to `w` while fading in (CSS `files-col-in`).
    pub fn enter(self: *Self, w: f64, ms: i64) void {
        self.start(.{ .dur = ms * 1000, .ease = .out, .from_w = 0, .to_w = w, .from_op = 0, .to_op = 1, .reflow = false });
    }

    /// Collapse to 0 while fading out (CSS `files-col-out`).
    pub fn leave(self: *Self, ms: i64) void {
        const cur = self.private().width;
        self.start(.{ .dur = ms * 1000, .ease = .in, .from_w = cur, .to_w = 0, .from_op = self.as(gtk.Widget).getOpacity(), .to_op = 0, .reflow = false });
        self.private().target = cur;
    }

    /// Fade in at the full width (CSS `files-fade-in`).
    pub fn fadeIn(self: *Self, w: f64, ms: i64) void {
        self.start(.{ .dur = ms * 1000, .ease = .out, .from_w = w, .to_w = w, .from_op = 0, .to_op = 1, .reflow = true });
    }

    /// Ease the width to `w` (CSS `transition: width`).
    pub fn animateWidth(self: *Self, w: f64, ms: i64) void {
        const priv = self.private();
        if (priv.anim == null and priv.width == w) return;
        self.start(.{ .dur = ms * 1000, .ease = .out, .from_w = priv.width, .to_w = w, .from_op = self.as(gtk.Widget).getOpacity(), .to_op = 1, .reflow = true });
    }

    fn start(self: *Self, a: Anim) void {
        const priv = self.private();
        priv.anim = a;
        priv.width = a.from_w;
        priv.target = if (a.reflow) a.to_w else @max(a.from_w, a.to_w);
        priv.reflow = a.reflow;
        self.as(gtk.Widget).setOpacity(a.from_op);
        self.as(gtk.Widget).queueResize();
    }

    /// Advance the animation to `now` (µs). Returns true while running.
    pub fn tick(self: *Self, now: i64) bool {
        const priv = self.private();
        const a = if (priv.anim) |*an| an else return false;
        if (a.t0 == 0) a.t0 = now;
        const p: f64 = if (a.dur <= 0) 1 else @min(1.0, @as(f64, @floatFromInt(now - a.t0)) / @as(f64, @floatFromInt(a.dur)));
        const e = ease(a.ease, p);
        priv.width = a.from_w + (a.to_w - a.from_w) * e;
        self.as(gtk.Widget).setOpacity(a.from_op + (a.to_op - a.from_op) * e);
        self.as(gtk.Widget).queueResize();
        if (p >= 1) {
            priv.width = a.to_w;
            if (a.reflow) priv.target = a.to_w;
            priv.anim = null;
            priv.reflow = true;
            return false;
        }
        return true;
    }

    fn measure(
        self: *Self,
        orientation: gtk.Orientation,
        for_size: c_int,
        minimum: ?*c_int,
        natural: ?*c_int,
        min_baseline: ?*c_int,
        nat_baseline: ?*c_int,
    ) callconv(.c) void {
        const priv = self.private();
        var min: c_int = 0;
        var nat: c_int = 0;
        if (orientation == .horizontal) {
            nat = @intFromFloat(@round(priv.width));
        } else if (priv.child) |c| {
            _ = for_size;
            c.measure(.vertical, -1, &min, &nat, null, null);
        }
        if (minimum) |m| m.* = min;
        if (natural) |n| n.* = nat;
        if (min_baseline) |b| b.* = -1;
        if (nat_baseline) |b| b.* = -1;
    }

    fn sizeAllocate(self: *Self, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        const priv = self.private();
        const child = priv.child orelse return;
        var cmin: c_int = 0;
        child.measure(.horizontal, -1, &cmin, null, null, null);
        const want: c_int = if (priv.reflow) width else @intFromFloat(@round(priv.target));
        child.allocate(@max(want, cmin), height, -1, null);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().* = .{};
        self.as(gtk.Widget).setOverflow(.hidden);
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.setChild(null);
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
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
            gtk.Widget.Class.setCssName(class.as(gtk.Widget.Class), "filescol");
            gtk.Widget.virtual_methods.measure.implement(class, &measure);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
};

/// CSS timing functions: ease-out = cubic-bezier(0, 0, 0.58, 1),
/// ease-in = cubic-bezier(0.42, 0, 1, 1).
pub fn ease(kind: Ease, p: f64) f64 {
    return switch (kind) {
        .linear => p,
        .out => bezier(0, 0, 0.58, 1, p),
        .in => bezier(0.42, 0, 1, 1, p),
    };
}

fn bezier(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    // Solve x(t) = x by Newton's method with a bisection fallback.
    const bx = struct {
        fn at(a1: f64, a2: f64, t: f64) f64 {
            const u = 1 - t;
            return 3 * u * u * t * a1 + 3 * u * t * t * a2 + t * t * t;
        }
        fn d(a1: f64, a2: f64, t: f64) f64 {
            const u = 1 - t;
            return 3 * u * u * a1 + 6 * u * t * (a2 - a1) + 3 * t * t * (1 - a2);
        }
    };
    var t = x;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const err = bx.at(x1, x2, t) - x;
        if (@abs(err) < 1e-6) return bx.at(y1, y2, t);
        const dv = bx.d(x1, x2, t);
        if (@abs(dv) < 1e-6) break;
        t -= err / dv;
    }
    var lo: f64 = 0;
    var hi: f64 = 1;
    t = x;
    i = 0;
    while (i < 40) : (i += 1) {
        const v = bx.at(x1, x2, t);
        if (@abs(v - x) < 1e-7) break;
        if (v < x) lo = t else hi = t;
        t = (lo + hi) / 2;
    }
    return bx.at(y1, y2, t);
}

test "ease endpoints and shape" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 0), ease(.out, 0));
    try t.expectEqual(@as(f64, 1), ease(.in, 1));
    try t.expect(ease(.out, 0.5) > 0.5);
    try t.expect(ease(.in, 0.5) < 0.5);
}
