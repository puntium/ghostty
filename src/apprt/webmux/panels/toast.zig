//! Status messages: `iface.services.status` (PARITY M-01, M-02).
//!
//! electron/ui/app.js `setStatus`: one message at a time; a new message
//! replaces the old one and restarts the 3000 ms hide timer. Shown as a
//! libadwaita toast (`AdwToast` in an `AdwToastOverlay`, deviation 70):
//! libadwaita's look and place (bottom centre), its close button, and its
//! rule that the timer pauses while the pointer is over the toast.
//!
//! A window gets its overlay one of two ways:
//!
//!   - `attach(window, overlay)`: the window already has a toast overlay
//!     of its own above everything, and the toasts go there;
//!   - `adoptWindow(window)`: the toast module wraps the window's content
//!     in an overlay of its own and keeps it wrapped when the content is
//!     replaced (`notify::content`; wrapping happens synchronously inside
//!     `setContent`, before the new content is allocated). The main
//!     window uses this.
//!
//! A message goes to the active `Window` (else the first host). With no
//! host at all it is only logged.
const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const mainloop = @import("../mainloop.zig");
const Application = @import("../application.zig").Application;

const log = std.log.scoped(.webmux_panels);
const alloc = std.heap.c_allocator;

/// electron/ui/app.js setStatus: `setTimeout(…, 3000)`.
pub const hide_after_ms = 3000;

const Host = struct {
    /// Borrowed; the host is freed when the window is destroyed.
    window: *gtk.Window,
    /// Strong reference (ours).
    overlay: *adw.ToastOverlay,
    /// The toast on show (our reference), null when none.
    toast: ?*adw.Toast = null,
    /// Its `dismissed` handler.
    dismissed_id: c_ulong = 0,
    /// The window's content is wrapped by us (adoptWindow).
    adopted: bool,
    /// notify::content handler on the window (adopted hosts).
    notify_id: c_ulong = 0,
    text: ?[:0]u8 = null,
    /// The connection whose message is showing (null: app-wide).
    owner: ?[]u8 = null,
    /// Messages shown on this host (for the control socket).
    count: u64 = 0,
};

var hosts: std.ArrayList(*Host) = .empty;

/// Messages shown since start (for the control socket).
pub var total: u64 = 0;

fn newHost(window: *gtk.Window, overlay: *adw.ToastOverlay, adopted: bool) *Host {
    const host = alloc.create(Host) catch @panic("OOM");
    host.* = .{ .window = window, .overlay = overlay, .adopted = adopted };
    hosts.append(alloc, host) catch @panic("OOM");
    _ = gtk.Widget.signals.destroy.connect(window, *Host, onWindowDestroy, host, .{});
    return host;
}

fn findHost(window: *gtk.Window) ?*Host {
    for (hosts.items) |h| if (h.window == window) return h;
    return null;
}

/// Use a toast overlay the window already has.
pub fn attach(window: *gtk.Window, overlay: *adw.ToastOverlay) void {
    if (findHost(window) != null) return;
    _ = overlay.as(gobject.Object).ref();
    _ = newHost(window, overlay, false);
}

/// Wrap the window's content (now and whenever it is replaced) in a
/// toast overlay.
pub fn adoptWindow(window: *adw.ApplicationWindow) void {
    const win = window.as(gtk.Window);
    if (findHost(win) != null) return;
    const overlay = adw.ToastOverlay.new();
    _ = overlay.as(gobject.Object).refSink();
    const host = newHost(win, overlay, true);
    wrapContent(host);
    host.notify_id = gobject.Object.signals.notify.connect(window, *Host, onContent, host, .{ .detail = "content" });
}

fn wrapContent(host: *Host) void {
    const window: *adw.ApplicationWindow = @ptrCast(host.window);
    // Null while the window is being torn down: leave it alone.
    const c = window.getContent() orelse return;
    if (c == host.overlay.as(gtk.Widget)) return;
    // Keep it alive while it moves from the window into the overlay.
    _ = c.as(gobject.Object).ref();
    defer c.as(gobject.Object).unref();
    window.setContent(host.overlay.as(gtk.Widget));
    host.overlay.setChild(c);
}

fn onContent(_: *adw.ApplicationWindow, _: *gobject.ParamSpec, host: *Host) callconv(.c) void {
    wrapContent(host);
}

fn onWindowDestroy(_: *gtk.Window, host: *Host) callconv(.c) void {
    for (hosts.items, 0..) |h, i| if (h == host) {
        _ = hosts.orderedRemove(i);
        break;
    };
    if (host.notify_id != 0) gobject.signalHandlerDisconnect(host.window.as(gobject.Object), host.notify_id);
    dropToast(host);
    if (host.text) |t| alloc.free(t);
    if (host.owner) |o| alloc.free(o);
    host.overlay.as(gobject.Object).unref();
    alloc.destroy(host);
}

fn currentHost() ?*Host {
    if (hosts.items.len == 0) return null;
    if (gobject.ext.cast(Application, @import("gio").Application.getDefault() orelse return hosts.items[0])) |app| {
        if (app.activeWindow()) |w| {
            if (findHost(w.as(gtk.Window))) |h| return h;
        }
    }
    return hosts.items[0];
}

/// `iface.services.status` (no source: shown wherever the user is).
pub fn show(text: []const u8) void {
    showFrom(null, text);
}

/// A status message from a connection's workspace (`conn_name` = profile
/// name), or app-wide (`null`). The Electron status line belongs to each
/// host's page, so a host's message is shown only while that host is in
/// front; one from a host behind is kept with its 3 s deadline and shows
/// for what is left of it if that host comes to the front in time. Until
/// the chrome reports a front (`setFront`), every message shows. Main
/// thread (posted there if not).
pub fn showFrom(conn_name: ?[]const u8, text: []const u8) void {
    if (!mainloop.isMainThread()) {
        const copy = alloc.dupe(u8, text) catch return;
        const name = if (conn_name) |n| alloc.dupe(u8, n) catch null else null;
        mainloop.post(Posted{ .text = copy, .conn = name }, Posted.run);
        return;
    }
    // Other areas' smokes look for exactly `status: <text>` in app.log.
    log.info("status: {s}", .{text});
    if (conn_name) |n| log.debug("status from {s}", .{n});
    total += 1;
    const now = nowMs();
    if (conn_name) |n| remember(n, text, now + hide_after_ms);
    if (conn_name == null or isFront(conn_name.?)) {
        display(conn_name, text, hide_after_ms);
    } else {
        log.debug("status for {s} kept until it comes to the front", .{conn_name.?});
    }
}

/// The chrome reports which connection is in front (null: the connection
/// page). Another host's toast goes away with its host; the new front
/// host's message reappears for the rest of its 3 s.
pub fn setFront(conn_name: ?[]const u8) void {
    front_known = true;
    if (front) |f| alloc.free(f);
    front = if (conn_name) |n| alloc.dupe(u8, n) catch null else null;
    const host = currentHost() orelse return;
    if (host.owner) |o| {
        if (!isFront(o)) dropToast(host);
    }
    const n = conn_name orelse return;
    for (pending.items) |m| {
        if (!std.mem.eql(u8, m.conn, n)) continue;
        const left = m.until - nowMs();
        if (left > 0) display(n, m.text, @intCast(left));
        return;
    }
}

const Pending = struct { conn: []u8, text: [:0]u8, until: i64 };
/// The last message of each connection (one entry per connection).
var pending: std.ArrayList(Pending) = .empty;
var front: ?[]u8 = null;
var front_known = false;

fn isFront(conn_name: []const u8) bool {
    if (!front_known) return true;
    const f = front orelse return false;
    return std.mem.eql(u8, f, conn_name);
}

fn nowMs() i64 {
    return @divTrunc(glib.getMonotonicTime(), 1000);
}

fn remember(conn_name: []const u8, text: []const u8, until: i64) void {
    const z = alloc.dupeSentinel(u8, text, 0) catch return;
    for (pending.items) |*m| if (std.mem.eql(u8, m.conn, conn_name)) {
        alloc.free(m.text);
        m.text = z;
        m.until = until;
        return;
    };
    const n = alloc.dupe(u8, conn_name) catch {
        alloc.free(z);
        return;
    };
    pending.append(alloc, .{ .conn = n, .text = z, .until = until }) catch {
        alloc.free(n);
        alloc.free(z);
    };
}

/// Show `text` for `ms`, replacing what the host shows. `AdwToast`'s
/// timeout is in whole seconds, so what is left of a kept message is
/// rounded up.
fn display(owner: ?[]const u8, text: []const u8, ms: u32) void {
    const host = currentHost() orelse return;
    const z = alloc.dupeSentinel(u8, text, 0) catch return;
    if (host.text) |t| alloc.free(t);
    host.text = z;
    if (host.owner) |o| alloc.free(o);
    host.owner = if (owner) |o| alloc.dupe(u8, o) catch null else null;
    host.count += 1;
    dropToast(host);
    // Shown as it is: Pango must not add hyphens where it wraps (paths,
    // file names); through markup, as a Pango attribute list would need a
    // direct libpango call.
    const esc = glib.markupEscapeText(z.ptr, -1);
    defer glib.free(esc);
    const markup = std.fmt.allocPrintSentinel(alloc, "<span insert_hyphens=\"false\">{s}</span>", .{std.mem.span(esc)}, 0) catch null;
    defer if (markup) |m| alloc.free(m);
    const toast = adw.Toast.new(if (markup) |m| m.ptr else z.ptr);
    if (markup != null) toast.setUseMarkup(1);
    toast.setTimeout((ms + 999) / 1000);
    // Ahead of anything libadwaita still has queued (it shows at once).
    toast.setPriority(.high);
    _ = toast.as(gobject.Object).ref();
    host.toast = toast;
    host.dismissed_id = adw.Toast.signals.dismissed.connect(toast, *Host, onDismissed, host, .{});
    host.overlay.addToast(toast);
}

/// Dismiss the host's toast, if any, and forget it.
fn dropToast(host: *Host) void {
    const toast = host.toast orelse return;
    forgetToast(host);
    toast.dismiss();
    toast.as(gobject.Object).unref();
}

fn forgetToast(host: *Host) void {
    const toast = host.toast orelse return;
    if (host.dismissed_id != 0) gobject.signalHandlerDisconnect(toast.as(gobject.Object), host.dismissed_id);
    host.dismissed_id = 0;
    host.toast = null;
}

/// The timer ran out, or the user closed it.
fn onDismissed(toast: *adw.Toast, host: *Host) callconv(.c) void {
    if (host.toast != toast) return;
    forgetToast(host);
    toast.as(gobject.Object).unref();
}

const Posted = struct {
    text: []u8,
    conn: ?[]u8 = null,
    fn run(self: *Posted) void {
        defer alloc.free(self.text);
        defer if (self.conn) |c| alloc.free(c);
        showFrom(self.conn, self.text);
    }
};

/// For the control socket: what the toast of the active window shows.
pub const State = struct {
    hosts: usize,
    visible: bool,
    text: ?[]const u8,
    adopted: bool,
    shown_total: u64,
    /// The connection the showing message came from (null: app-wide).
    from: ?[]const u8 = null,
    front: ?[]const u8 = null,
    front_known: bool = false,
};

pub fn state() State {
    const host = currentHost() orelse return .{ .hosts = 0, .visible = false, .text = null, .adopted = false, .shown_total = total };
    return .{
        .hosts = hosts.items.len,
        .visible = host.toast != null,
        .text = if (host.text) |t| t else null,
        .adopted = host.adopted,
        .shown_total = total,
        .from = host.owner,
        .front = front,
        .front_known = front_known,
    };
}
