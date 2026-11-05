//! The workspace feature's registration (features.zig): the strip of
//! columns is every connection's view (`iface.workspace_factory`).
const std = @import("std");
const gdk = @import("gdk");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const Workspace = @import("workspace.zig").Workspace;

/// Called once at application start. Creates no widgets.
pub fn register() void {
    iface.workspace_factory = .{ .create = create };
}

fn create(c: *const iface.Conn, host: iface.WorkspaceHost) anyerror!iface.Workspace {
    ensureCss();
    const ws = Workspace.new(c, host);
    return ws.handle();
}

var css_loaded = false;

/// The workspace's stylesheet (style.css next to this file), installed
/// once for the display at application priority, like the shell's own.
fn ensureCss() void {
    if (css_loaded) return;
    const display = gdk.Display.getDefault() orelse return;
    const provider = gtk.CssProvider.new();
    provider.loadFromString(@embedFile("style.css"));
    gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    css_loaded = true;
}

comptime {
    _ = std;
}
