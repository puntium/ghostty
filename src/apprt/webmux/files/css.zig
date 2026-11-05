//! The file browser's stylesheet (files.css), installed once for the
//! display at application priority (one line in application.zig).
const gdk = @import("gdk");
const gtk = @import("gtk");

var provider: ?*gtk.CssProvider = null;

pub fn install(display: *gdk.Display) void {
    if (provider != null) return;
    const p = gtk.CssProvider.new();
    p.loadFromString(@embedFile("files.css"));
    gtk.StyleContext.addProviderForDisplay(display, p.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    provider = p;
}
