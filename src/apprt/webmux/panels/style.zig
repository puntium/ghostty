//! The panels' stylesheets: panels.css (dark, always loaded; one line in
//! application.zig, next to the application stylesheet) and
//! panels-light.css on top of it while libadwaita is light.
//!
//! The switch follows `AdwStyleManager:dark`, like the other areas' CSS
//! classes: Settings › Color scheme changes it through
//! `Application.setScheme` (which forces libadwaita's scheme), and so does
//! anything else that switches the scheme. GTK's
//! `@media (prefers-color-scheme)` does not follow libadwaita's forced
//! scheme in this app, so it is not used.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

var base: ?*gtk.CssProvider = null;
var light: ?*gtk.CssProvider = null;
/// Whether the light overrides are off.
pub var dark: bool = true;

pub fn install(display: *gdk.Display) void {
    if (base != null) return;
    const p = gtk.CssProvider.new();
    p.loadFromString(@embedFile("panels.css"));
    gtk.StyleContext.addProviderForDisplay(display, p.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    base = p;
    const l = gtk.CssProvider.new();
    l.loadFromString(@embedFile("panels-light.css"));
    light = l;

    const sm = adw.StyleManager.getDefault();
    _ = gobject.Object.signals.notify.connect(sm, ?*anyopaque, onDark, null, .{ .detail = "dark" });
    setDark(sm.getDark() != 0);
}

fn onDark(sm: *adw.StyleManager, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    setDark(sm.getDark() != 0);
}

fn setDark(want_dark: bool) void {
    if (want_dark == dark) return;
    const display = gdk.Display.getDefault() orelse return;
    const l = light orelse return;
    dark = want_dark;
    if (dark) {
        gtk.StyleContext.removeProviderForDisplay(display, l.as(gtk.StyleProvider));
    } else {
        gtk.StyleContext.addProviderForDisplay(display, l.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    }
}

comptime {
    _ = std;
}
