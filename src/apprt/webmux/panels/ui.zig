//! Small widget builders shared by the panels' modals (PARITY M-03:
//! electron/ui/index.html `.modal-overlay`, `.modal`, `.modal button`,
//! `.modal .actions`). Styling is in panels.css.
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");
const glib = @import("glib");
const gobject = @import("gobject");

/// A modal: libadwaita's in-window dialog (dims the window, centres the
/// panel, Escape and a click on the dimmed backdrop close it, focus goes
/// back where it was), always floating, styled as the Electron modal.
pub fn modal(class: [:0]const u8) *adw.Dialog {
    const d = adw.Dialog.new();
    const w = d.as(gtk.Widget);
    w.addCssClass("webmux-modal");
    w.addCssClass(class);
    d.setPresentationMode(.floating);
    d.setFollowsContentSize(1);
    return d;
}

pub const ButtonStyle = enum { normal, primary, danger };

pub fn button(text: [:0]const u8, style: ButtonStyle) *gtk.Button {
    const b = gtk.Button.newWithLabel(text.ptr);
    const w = b.as(gtk.Widget);
    w.addCssClass("modal-button");
    switch (style) {
        .normal => {},
        .primary => w.addCssClass("primary"),
        .danger => w.addCssClass("danger"),
    }
    return b;
}

/// `.modal .actions`: right-aligned, 8px gaps.
pub fn actionsRow() *gtk.Box {
    const box = gtk.Box.new(.horizontal, 8);
    const w = box.as(gtk.Widget);
    w.addCssClass("modal-actions");
    w.setHalign(.end);
    return box;
}

pub fn label(text: [:0]const u8, class: ?[:0]const u8) *gtk.Label {
    const l = gtk.Label.new(text.ptr);
    l.setXalign(0);
    if (class) |c| l.as(gtk.Widget).addCssClass(c);
    return l;
}

/// Present a modal, closing it on a click on the dimmed backdrop
/// (index.html: `overlay` click with `ev.target === overlay`). libadwaita's
/// floating dialog does not do that itself; its `dimming` node is inside
/// the dialog widget once presented.
pub fn present(d: *adw.Dialog, parent: *gtk.Widget) void {
    d.present(parent);
    if (!hookBackdrop(d)) _ = glib.idleAddOnce(hookLater, d.as(gobject.Object).ref());
}

fn hookLater(ud: ?*anyopaque) callconv(.c) void {
    const d: *adw.Dialog = @ptrCast(@alignCast(ud orelse return));
    defer d.as(gobject.Object).unref();
    _ = hookBackdrop(d);
}

fn findByCssName(w: *gtk.Widget, name: []const u8) ?*gtk.Widget {
    if (std.mem.eql(u8, std.mem.span(w.getCssName()), name)) return w;
    var c = w.getFirstChild();
    while (c) |child| : (c = child.getNextSibling()) {
        if (findByCssName(child, name)) |f| return f;
    }
    return null;
}

fn hookBackdrop(d: *adw.Dialog) bool {
    const dim = findByCssName(d.as(gtk.Widget), "dimming") orelse return false;
    const click = gtk.GestureClick.new();
    _ = gtk.GestureClick.signals.released.connect(click, *adw.Dialog, onBackdrop, d, .{});
    dim.addController(click.as(gtk.EventController));
    return true;
}

fn onBackdrop(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, d: *adw.Dialog) callconv(.c) void {
    _ = d.close();
}
