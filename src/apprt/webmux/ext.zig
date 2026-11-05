//! Small Zig-friendly helpers around GTK/GObject. Started as a trimmed copy
//! of src/apprt/gtk/ext.zig (Ghostty f54340ad); add to it freely.

const std = @import("std");

const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

pub const actions = @import("ext/actions.zig");

/// Wrapper around `gobject.boxedCopy` to copy a boxed type `T`.
pub fn boxedCopy(comptime T: type, ptr: *const T) *T {
    const copy = gobject.boxedCopy(T.getGObjectType(), ptr);
    return @ptrCast(@alignCast(copy));
}

/// Wrapper around `gobject.boxedFree` to free a boxed type `T`.
pub fn boxedFree(comptime T: type, ptr: ?*T) void {
    if (ptr) |p| gobject.boxedFree(
        T.getGObjectType(),
        p,
    );
}

/// Wrapper around `gtk.Widget.getAncestor` to get the widget ancestor
/// of the given type `T`, or null if it doesn't exist.
pub fn getAncestor(comptime T: type, widget: *gtk.Widget) ?*T {
    const ancestor_ = widget.getAncestor(gobject.ext.typeFor(T));
    const ancestor = ancestor_ orelse return null;
    // We can assert the unwrap because getAncestor above
    return gobject.ext.cast(T, ancestor).?;
}

/// Check a gobject.Value to see what type it is wrapping. This is equivalent to GTK's
/// `G_VALUE_HOLDS()` macro but Zig's C translator does not like it.
pub fn gValueHolds(value_: ?*const gobject.Value, g_type: gobject.Type) bool {
    const value = value_ orelse return false;
    if (value.f_g_type == g_type) return true;
    return gobject.typeCheckValueHolds(value, g_type) != 0;
}

/// Free a glib-allocated, nul-terminated string held in an optional slot
/// and set the slot to `value` (copied with glib), or null.
pub fn replaceString(slot: *?[:0]const u8, value: ?[]const u8) void {
    if (slot.*) |v| glib.free(@ptrCast(@constCast(v.ptr)));
    slot.* = if (value) |v| glib.ext.dupeZ(u8, v) else null;
}

test {
    _ = actions;
}
