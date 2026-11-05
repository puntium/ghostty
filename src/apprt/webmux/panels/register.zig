//! The panels' registration (features.zig): the status and URL services,
//! and the application actions `app.show-settings` / `app.show-log` that
//! the chrome's menu and shortcuts activate by name.
//!
//! What the rest of the shell calls besides `iface`:
//!
//!   settings.load()          apply the stored settings; the chrome calls
//!                            it right after it sets `iface.engine`, before
//!                            presenting the first window (it also runs by
//!                            itself when the first window is added, so a
//!                            chrome that creates the engine earlier needs
//!                            nothing else)
//!   settings.external(&s)    forward the engine's `.settings` event
//!   toast.attach(win, ovl)   give a window's overlay the status toast, or
//!   toast.adoptWindow(win)   let the toast wrap the window's content
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const Application = @import("../application.zig").Application;
const toast = @import("toast.zig");
const url = @import("url.zig");
const settings = @import("settings.zig");
const settings_panel = @import("settings_panel.zig");
const log_window = @import("log_window.zig");

pub fn register() void {
    iface.services.status = toast.showFrom;
    iface.services.url = url.service;
    url.initSink();

    const app = Application.default();
    addAction(app, "show-settings", onShowSettings);
    addAction(app, "show-log", onShowLog);
    _ = gtk.Application.signals.window_added.connect(app.as(gtk.Application), ?*anyopaque, onWindowAdded, null, .{});
    _ = gtk.Application.signals.window_removed.connect(app.as(gtk.Application), ?*anyopaque, onWindowRemoved, null, .{});
}

const ActionFn = *const fn (*gio.SimpleAction, ?*glib.Variant, ?*anyopaque) callconv(.c) void;

fn addAction(app: *Application, comptime name: [:0]const u8, cb: ActionFn) void {
    const action = gio.SimpleAction.new(name.ptr, null);
    defer action.unref();
    _ = gio.SimpleAction.signals.activate.connect(action, ?*anyopaque, cb, null, .{});
    app.as(gio.ActionMap).addAction(action.as(gio.Action));
}

fn onShowSettings(_: *gio.SimpleAction, _: ?*glib.Variant, _: ?*anyopaque) callconv(.c) void {
    settings_panel.show();
}

fn onShowLog(_: *gio.SimpleAction, _: ?*glib.Variant, _: ?*anyopaque) callconv(.c) void {
    log_window.show();
}

fn onWindowAdded(_: *gtk.Application, _: *gtk.Window, _: ?*anyopaque) callconv(.c) void {
    // E-07: the stored settings are applied before the first window is
    // presented (window-added runs while the window is being constructed).
    if (!settings.loaded) settings.load();
}

fn onWindowRemoved(app: *gtk.Application, _: *gtk.Window, _: ?*anyopaque) callconv(.c) void {
    log_window.onAppWindowRemoved(app);
}
