//! The few GSK types the strip draws with. The build gives the root module
//! no `gsk` import (SharedDeps lists adw, gdk, gio, glib, gobject,
//! graphene, gtk), so they are taken from the GTK functions that use them
//! instead of adding one.
const gtk = @import("gtk");

fn Pointee(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| Pointee(o.child),
        .pointer => |p| p.child,
        else => @compileError("not a pointer"),
    };
}

fn Param(comptime f: anytype, comptime i: usize) type {
    return Pointee(@typeInfo(@TypeOf(f)).@"fn".param_types[i].?);
}

pub const RoundedRect = Param(gtk.Snapshot.pushRoundedClip, 1);
pub const Transform = Param(gtk.Widget.allocate, 4);
pub const Path = Param(gtk.Snapshot.appendStroke, 1);
pub const Stroke = Param(gtk.Snapshot.appendStroke, 2);
