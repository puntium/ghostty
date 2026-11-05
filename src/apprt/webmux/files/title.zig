//! Fitting a file browser's title into a label (F-15). The pane title is
//! the full path to the selection (`Pane.title`); whoever draws the title
//! bar calls `fit` with its label on every title change and label resize.
//! The text is measured in the label's own font at weight 600 (the focused
//! bar's weight, so it still fits when focus arrives), parents collapse
//! into '…' before the name is cut, and the full path becomes the tooltip.
//!
//! Measuring goes through the label itself (markup + measure), not Pango:
//! calling Pango directly would add a library the build does not put on
//! the executable's run path.
const std = @import("std");
const gtk = @import("gtk");
const paths = @import("paths.zig");

const alloc = std.heap.c_allocator;

const Ctx = struct {
    label: *gtk.Label,
    buf: std.ArrayList(u8) = .empty,
};

fn measure(ctx_ptr: *anyopaque, text: []const u8) f64 {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    ctx.buf.clearRetainingCapacity();
    ctx.buf.appendSlice(alloc, "<span weight=\"600\">") catch return 1e9;
    for (text) |c| switch (c) {
        '&' => ctx.buf.appendSlice(alloc, "&amp;") catch return 1e9,
        '<' => ctx.buf.appendSlice(alloc, "&lt;") catch return 1e9,
        '>' => ctx.buf.appendSlice(alloc, "&gt;") catch return 1e9,
        else => ctx.buf.append(alloc, c) catch return 1e9,
    };
    ctx.buf.appendSlice(alloc, "</span>") catch return 1e9;
    ctx.buf.append(alloc, 0) catch return 1e9;
    ctx.label.setMarkup(@ptrCast(ctx.buf.items.ptr));
    var nat: c_int = 0;
    ctx.label.as(gtk.Widget).measure(.horizontal, -1, null, &nat, null, null);
    return @floatFromInt(nat);
}

/// Set `label` to `full` fitted to the label's current width (`width`
/// overrides it, e.g. before the first allocation), with `full` as tooltip.
pub fn fit(label: *gtk.Label, full: []const u8, width: ?f64) void {
    const zfull = alloc.dupeSentinel(u8, full, 0) catch return;
    defer alloc.free(zfull);
    label.as(gtk.Widget).setTooltipText(zfull.ptr);
    const w = width orelse @as(f64, @floatFromInt(label.as(gtk.Widget).getWidth()));
    if (w <= 0) {
        label.setText(zfull.ptr);
        return;
    }
    // Measure without ellipsizing.
    const ell = label.getEllipsize();
    label.setEllipsize(.none);
    var ctx: Ctx = .{ .label = label };
    defer ctx.buf.deinit(alloc);
    const s = paths.fitPath(alloc, full, w - 1, .{ .ctx = &ctx, .func = measure }) catch return;
    defer alloc.free(s);
    const z = alloc.dupeSentinel(u8, s, 0) catch return;
    defer alloc.free(z);
    label.setEllipsize(ell);
    label.setText(z.ptr);
}
