//! Wake from suspend → `Engine.notifyResume()` (main.js powerMonitor
//! 'resume'): logind's `PrepareForSleep(false)` on the system bus.
//!
//! For development the signal can be watched on the session bus instead
//! (`WEBMUX_GTK_SLEEP_BUS=session`), so a headless run can fake it with
//! `gdbus emit --session --object-path /org/freedesktop/login1 --signal
//! org.freedesktop.login1.Manager.PrepareForSleep false`; the control
//! command `sleep-resume` enters at the same handler.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");

const log = std.log.scoped(.webmux_chrome);

var on_resume: ?*const fn () void = null;
var bus: ?*gio.DBusConnection = null;
var sub: c_uint = 0;

pub fn start(resume_fn: *const fn () void) void {
    on_resume = resume_fn;
    const session = if (std.c.getenv("WEBMUX_GTK_SLEEP_BUS")) |v| std.mem.eql(u8, std.mem.span(v), "session") else false;
    // Async so a missing or slow system bus never delays startup.
    gio.busGet(if (session) .session else .system, null, onBus, @ptrFromInt(@intFromBool(session)));
}

fn onBus(_: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
    const session = @intFromPtr(ud) != 0;
    var err: ?*glib.Error = null;
    const c = gio.busGetFinish(res, &err) orelse {
        if (err) |e| {
            defer e.free();
            log.info("no {s} bus for sleep notifications: {s}", .{ if (session) "session" else "system", e.f_message orelse "?" });
        }
        return;
    };
    bus = c;
    sub = c.signalSubscribe(
        if (session) null else "org.freedesktop.login1",
        "org.freedesktop.login1.Manager",
        "PrepareForSleep",
        "/org/freedesktop/login1",
        null,
        .{},
        onSignal,
        null,
        null,
    );
    log.info("watching PrepareForSleep on the {s} bus", .{if (session) "session" else "system"});
}

fn onSignal(_: *gio.DBusConnection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, params: *glib.Variant, _: ?*anyopaque) callconv(.c) void {
    if (params.nChildren() < 1) return;
    const v = params.getChildValue(0);
    defer v.unref();
    const going_to_sleep = v.getBoolean() != 0;
    log.info("PrepareForSleep({})", .{going_to_sleep});
    if (!going_to_sleep) resumed();
}

/// Also the control command's entry point.
pub fn resumed() void {
    if (on_resume) |f| f();
}

pub fn stop() void {
    if (bus) |c| {
        if (sub != 0) c.signalUnsubscribe(sub);
        c.unref();
    }
    bus = null;
    sub = 0;
}

const gobject = @import("gobject");
