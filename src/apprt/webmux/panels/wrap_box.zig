//! `WebmuxWrapBox`: a row of widgets that wraps onto more lines when it is
//! too narrow, like a CSS `display: flex; flex-wrap: wrap` row with an
//! optional `flex: 1` spacer (logs.html #toolbar). Line breaking is
//! `model.flow`; each line is as tall as its tallest child and children
//! are centred in it (`align-items: center`). Height-for-width, so the
//! window gets taller rather than wider when the row wraps.
const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const model = @import("model.zig");

const max_children = 24;

pub const WrapBox = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxWrapBox",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The spacer child (an empty box), if any.
        spacer: ?*gtk.Widget = null,
        gap: c_int = 8,
        line_gap: c_int = 8,
        pub var offset: c_int = 0;
    };

    pub fn new(gap: c_int, line_gap: c_int) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.private().gap = gap;
        self.private().line_gap = line_gap;
        return self;
    }

    pub fn append(self: *Self, child: *gtk.Widget) void {
        child.setParent(self.as(gtk.Widget));
    }

    /// Add the `flex: 1` spacer at this position.
    pub fn appendSpacer(self: *Self) void {
        const s = gtk.Box.new(.horizontal, 0);
        self.private().spacer = s.as(gtk.Widget);
        self.append(s.as(gtk.Widget));
    }

    const Child = struct { w: *gtk.Widget, item: model.FlowItem };

    fn children(self: *Self, buf: *[max_children]Child) []Child {
        var n: usize = 0;
        var c = self.as(gtk.Widget).getFirstChild();
        while (c) |w| : (c = w.getNextSibling()) {
            if (n == max_children) break;
            if (w.shouldLayout() == 0) continue;
            var min: c_int = 0;
            var nat: c_int = 0;
            w.measure(.horizontal, -1, &min, &nat, null, null);
            buf[n] = .{ .w = w, .item = .{ .min = min, .nat = nat, .spacer = w == self.private().spacer } };
            n += 1;
        }
        return buf[0..n];
    }

    const Lines = struct {
        places: [max_children]model.FlowPlace = undefined,
        heights: [max_children]c_int = @splat(0),
        n: u32 = 0,
        total: c_int = 0,
    };

    fn layout(self: *Self, cs: []Child, width: c_int) Lines {
        var items: [max_children]model.FlowItem = undefined;
        for (cs, 0..) |c, i| items[i] = c.item;
        var l: Lines = .{};
        l.n = model.flow(items[0..cs.len], width, self.private().gap, l.places[0..cs.len]);
        for (cs, 0..) |c, i| {
            if (c.item.spacer) continue;
            var nat: c_int = 0;
            c.w.measure(.vertical, l.places[i].w, null, &nat, null, null);
            const line = l.places[i].line;
            l.heights[line] = @max(l.heights[line], nat);
        }
        for (0..l.n) |i| l.total += l.heights[i];
        if (l.n > 1) l.total += self.private().line_gap * @as(c_int, @intCast(l.n - 1));
        return l;
    }

    fn requestMode(_: *Self) callconv(.c) gtk.SizeRequestMode {
        return .height_for_width;
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
        var buf: [max_children]Child = undefined;
        const cs = self.children(&buf);
        var min: c_int = 0;
        var nat: c_int = 0;
        if (orientation == .horizontal) {
            // Narrowest: the widest single item; natural: all on one line.
            var count: c_int = 0;
            for (cs) |c| {
                min = @max(min, c.item.min);
                nat += c.item.nat;
                count += 1;
            }
            if (count > 1) nat += self.private().gap * (count - 1);
            if (for_size >= 0 and min < nat and self.layout(cs, min).total > for_size) {
                // Width for a given height: the narrowest width whose
                // wrapped height fits (GTK checks the two directions
                // agree).
                var lo = min;
                var hi = nat;
                while (lo < hi) {
                    const mid = lo + @divTrunc(hi - lo, 2);
                    if (self.layout(cs, mid).total <= for_size) hi = mid else lo = mid + 1;
                }
                min = lo;
            }
        } else {
            // Height for a width; with no width, the one-line height
            // (the smallest height, as GTK expects of -1).
            var natw: c_int = 0;
            for (cs) |c| natw += c.item.nat;
            natw += self.private().gap * @as(c_int, @intCast(@max(cs.len, 1) - 1));
            const w = if (for_size < 0) natw else for_size;
            const l = self.layout(cs, w);
            min = l.total;
            nat = l.total;
        }
        if (minimum) |m| m.* = min;
        if (natural) |n| n.* = nat;
        if (min_baseline) |b| b.* = -1;
        if (nat_baseline) |b| b.* = -1;
    }

    fn sizeAllocate(self: *Self, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        _ = height;
        var buf: [max_children]Child = undefined;
        const cs = self.children(&buf);
        const l = self.layout(cs, width);
        var line_y: [max_children]c_int = undefined;
        var y: c_int = 0;
        for (0..l.n) |i| {
            line_y[i] = y;
            y += l.heights[i] + self.private().line_gap;
        }
        for (cs, 0..) |c, i| {
            const p = l.places[i];
            const lh = l.heights[p.line];
            var ch: c_int = 0;
            c.w.measure(.vertical, p.w, null, &ch, null, null);
            ch = if (c.item.spacer) lh else @min(ch, lh);
            var a: gtk.Allocation = .{
                .f_x = p.x,
                .f_y = line_y[p.line] + @divTrunc(lh - ch, 2),
                .f_width = p.w,
                .f_height = if (c.item.spacer) lh else ch,
            };
            c.w.sizeAllocate(&a, -1);
        }
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().* = .{};
    }

    fn dispose(self: *Self) callconv(.c) void {
        while (self.as(gtk.Widget).getFirstChild()) |c| c.unparent();
        self.private().spacer = null;
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
            gtk.Widget.Class.setCssName(class.as(gtk.Widget.Class), "wrapbox");
            gtk.Widget.virtual_methods.get_request_mode.implement(class, &requestMode);
            gtk.Widget.virtual_methods.measure.implement(class, &measure);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
};
