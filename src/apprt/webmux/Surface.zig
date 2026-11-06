//! The apprt Surface: the struct the Ghostty core holds a pointer to for
//! each terminal (`CoreSurface.rt_surface`). It lives inside the
//! TerminalPane's private data and forwards everything to the pane.
//!
//! This is the full list of what the core calls on an apprt surface; see
//! src/apprt/gtk/Surface.zig for the stock equivalent.
const Self = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const renderer = @import("../../renderer.zig");
const termio = @import("../../termio.zig");
const ApprtApp = @import("App.zig");
const Application = @import("application.zig").Application;
const TerminalPane = @import("pane.zig").TerminalPane;

pane: *TerminalPane,

pub fn deinit(self: *Self) void {
    _ = self;
}

/// The pane widget for this surface. (Named `gobj` like the stock shell.)
pub fn gobj(self: *Self) *TerminalPane {
    return self.pane;
}

pub fn core(self: *Self) *CoreSurface {
    // The core only calls this for initialized surfaces.
    return self.pane.core().?;
}

pub fn rtApp(self: *Self) *ApprtApp {
    _ = self;
    return Application.default().rt();
}

pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    self.pane.coreClose();
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.pane.getTitle();
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    return self.pane.getContentScale();
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return self.pane.getSize();
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.pane.getCursorPos();
}

pub fn supportsClipboard(self: *const Self, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard, .selection, .primary => true,
    };
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    return try self.pane.clipboardRequest(clipboard_type, state);
}

pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    self.pane.setClipboard(clipboard_type, contents, confirm);
}

pub fn defaultTermioEnv(self: *Self) !std.process.Environ.Map {
    return try self.pane.defaultTermioEnv();
}

/// Links are underlined on hover while the program has mouse reporting
/// on too, as in xterm.js (T-24). Read by the core (`mouseLinksActive`);
/// the pane opens them (`TerminalPane.mousePress`).
pub const links_while_mouse_reporting = true;

/// The termio backend seam (src/termio/Webmux.zig): a remote pane returns
/// its session's config, a local pane null (termio.Exec).
pub fn termioBackend(self: *Self) !?termio.Webmux.Config {
    return self.pane.termioBackend();
}

pub fn renderDeviceOptions(self: *Self) !renderer.Device.Options {
    return self.pane.renderDeviceOptions();
}
