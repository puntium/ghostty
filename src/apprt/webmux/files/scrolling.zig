//! Scrolling the file browser's scrolled windows the way the Electron
//! client's page scrolls:
//!
//!   - touchpad (pixel) deltas move the view by exactly that many pixels,
//!     with no kinetic tail (GtkScrolledWindow moved a 100 px swipe by
//!     about 1100 px here);
//!   - a scroll along an axis the window cannot scroll (a code block that
//!     only scrolls sideways, a column that only scrolls vertically) goes
//!     to the nearest enclosing scrolled window that can, instead of being
//!     swallowed;
//!   - at the end of its range a window lets the scroll through to its
//!     enclosing one (scroll chaining), so the pane or the strip around it
//!     can move.
//!
//! Wheel (notch) deltas within a window that can scroll that way are left
//! to GTK (its step is page^(2/3) per notch).
const std = @import("std");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

/// `outer`: the outermost window (the column strip) handles scrolls after
/// the windows inside it (bubble phase), the others before GTK's own
/// handling of them (capture phase).
/// Stop GTK from scrolling `sw` to the focused widget. A GtkViewport
/// follows the window's focus-widget changes while focus is inside it, and
/// scrolls to the *new* focus widget even when that is outside it (a
/// terminal pane), to a position computed from unrelated coordinates: an
/// unfocused browser jumped sideways (final check, item 2). The browser
/// shows its cursor row and right edge itself. Call after `setChild`.
pub fn noScrollToFocus(sw: *gtk.ScrolledWindow) void {
    const child = sw.getChild() orelse return;
    if (gobject.ext.cast(gtk.Viewport, child)) |vp| vp.setScrollToFocus(0);
}

pub fn install(sw: *gtk.ScrolledWindow, outer: bool) void {
    sw.setKineticScrolling(0);
    const ec = gtk.EventControllerScroll.new(.{ .vertical = true, .horizontal = true });
    ec.as(gtk.EventController).setPropagationPhase(if (outer) .bubble else .capture);
    _ = gtk.EventControllerScroll.signals.scroll.connect(ec, *gtk.ScrolledWindow, onScroll, sw, .{});
    sw.as(gtk.Widget).addController(ec.as(gtk.EventController));
}

fn canScroll(sw: *gtk.ScrolledWindow, vertical: bool) bool {
    var hp: gtk.PolicyType = .automatic;
    var vp: gtk.PolicyType = .automatic;
    sw.getPolicy(&hp, &vp);
    return (if (vertical) vp else hp) != .never;
}

fn adjustment(sw: *gtk.ScrolledWindow, vertical: bool) *gtk.Adjustment {
    return if (vertical) sw.getVadjustment() else sw.getHadjustment();
}

/// Move `adj` by `delta` px; returns whether it moved.
fn move(adj: *gtk.Adjustment, delta: f64) bool {
    const before = adj.getValue();
    const max = adj.getUpper() - adj.getPageSize();
    const after = std.math.clamp(before + delta, adj.getLower(), @max(adj.getLower(), max));
    if (after == before) return false;
    adj.setValue(after);
    return true;
}

fn pixels(adj: *gtk.Adjustment, delta: f64, unit: gdk.ScrollUnit) f64 {
    if (unit == .surface) return delta;
    // GTK's wheel step: page^(2/3) per notch.
    return delta * std.math.pow(f64, @max(1, adj.getPageSize()), 2.0 / 3.0);
}

fn onScroll(ec: *gtk.EventControllerScroll, dx: f64, dy: f64, sw: *gtk.ScrolledWindow) callconv(.c) c_int {
    const vertical = @abs(dy) >= @abs(dx);
    const delta = if (vertical) dy else dx;
    if (delta == 0) return 0;
    const unit = ec.getUnit();
    // In this window, when it can scroll that way.
    if (canScroll(sw, vertical)) {
        if (unit == .wheel) return 0; // GTK's own wheel handling
        const adj = adjustment(sw, vertical);
        if (move(adj, pixels(adj, delta, unit))) return 1;
        // At its edge: let an enclosing window take it.
    }
    var w: ?*gtk.Widget = sw.as(gtk.Widget).getParent();
    while (w) |cur| : (w = cur.getParent()) {
        const outer = gobject.ext.cast(gtk.ScrolledWindow, cur) orelse continue;
        if (!canScroll(outer, vertical)) continue;
        const adj = adjustment(outer, vertical);
        if (move(adj, pixels(adj, delta, unit))) return 1;
    }
    // Nobody here can move: let it bubble (to the workspace's strip, for
    // horizontal scrolls).
    return 0;
}
