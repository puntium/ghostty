//! Small GVariant / GDBus helpers for the chrome's D-Bus clients (the
//! Secret Service in keyring.zig, logind in sleep.zig). GDBus connections
//! are thread-safe: the blocking calls here are meant for worker threads
//! (never the GTK main thread, except for the instant bus-daemon queries
//! at startup).
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");

pub const V = *glib.Variant;

extern fn g_dbus_error_get_remote_error(err: *const glib.Error) ?[*:0]u8;
extern fn g_variant_get_fixed_array(v: *glib.Variant, n: *usize, size: usize) ?[*]const u8;
extern fn g_free(p: ?*anyopaque) void;

/// A GVariantType from a type string (G_VARIANT_TYPE is a cast in C).
pub fn vtype(comptime s: [:0]const u8) *const glib.VariantType {
    return @ptrCast(s.ptr);
}

pub fn str(s: [*:0]const u8) V {
    return glib.Variant.newString(s);
}
pub fn objpath(s: [*:0]const u8) V {
    return glib.Variant.newObjectPath(s);
}
pub fn boolean(b: bool) V {
    return glib.Variant.newBoolean(@intFromBool(b));
}
pub fn variant(v: V) V {
    return glib.Variant.newVariant(v);
}
pub fn tuple(children: []const V) V {
    return glib.Variant.newTuple(children.ptr, children.len);
}
pub fn array(comptime child_type: [:0]const u8, children: []const V) V {
    return glib.Variant.newArray(vtype(child_type), if (children.len == 0) null else children.ptr, children.len);
}
pub fn entry(k: V, v: V) V {
    return glib.Variant.newDictEntry(k, v);
}
/// `ay` holding a copy of `bytes`.
pub fn bytes(b: []const u8) V {
    return glib.Variant.newFixedArray(vtype("y"), if (b.len == 0) null else b.ptr, b.len, 1);
}

/// Borrowed string of an `s`/`o` variant.
pub fn getStr(v: V) []const u8 {
    var n: usize = 0;
    const p = glib.Variant.getString(v, &n);
    return p[0..n];
}

/// Borrowed bytes of an `ay` variant.
pub fn getBytes(v: V) []const u8 {
    var n: usize = 0;
    const p = g_variant_get_fixed_array(v, &n, 1) orelse return &.{};
    return p[0..n];
}

/// New reference to child `i`.
pub fn child(v: V, i: usize) V {
    return glib.Variant.getChildValue(v, i);
}

pub fn count(v: V) usize {
    return glib.Variant.nChildren(v);
}

pub fn unref(v: V) void {
    glib.Variant.unref(v);
}

/// Why a call failed, as far as the caller needs to know.
pub const CallError = struct {
    /// The D-Bus error name if the peer (or the bus) answered with one,
    /// e.g. "org.freedesktop.DBus.Error.ServiceUnknown".
    name_buf: [128]u8 = undefined,
    name_len: usize = 0,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn name(self: *const CallError) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn message(self: *const CallError) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    /// No peer: nobody owns the name (and nothing activates it).
    pub fn noService(self: *const CallError) bool {
        const n = self.name();
        return std.mem.eql(u8, n, "org.freedesktop.DBus.Error.ServiceUnknown") or
            std.mem.eql(u8, n, "org.freedesktop.DBus.Error.NameHasNoOwner") or
            std.mem.eql(u8, n, "org.freedesktop.DBus.Error.Spawn.ServiceNotFound") or
            std.mem.eql(u8, n, "org.freedesktop.DBus.Error.NoReply") or
            std.mem.eql(u8, n, "org.freedesktop.DBus.Error.Disconnected") or
            std.mem.eql(u8, n, "no-bus");
    }

    fn set(self: *CallError, err: *glib.Error) void {
        if (g_dbus_error_get_remote_error(err)) |remote| {
            defer g_free(remote);
            const s = std.mem.span(remote);
            const n = @min(s.len, self.name_buf.len);
            @memcpy(self.name_buf[0..n], s[0..n]);
            self.name_len = n;
        } else self.name_len = 0;
        const m = std.mem.span(err.f_message orelse "");
        const n = @min(m.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], m[0..n]);
        self.message_len = n;
    }

    fn setText(self: *CallError, n: []const u8, m: []const u8) void {
        @memcpy(self.name_buf[0..n.len], n);
        self.name_len = n.len;
        const k = @min(m.len, self.message_buf.len);
        @memcpy(self.message_buf[0..k], m[0..k]);
        self.message_len = k;
    }
};

/// The session or system bus (a shared connection, new reference), or
/// null with `err` set.
pub fn bus(kind: gio.BusType, err: *CallError) ?*gio.DBusConnection {
    var gerr: ?*glib.Error = null;
    const c = gio.busGetSync(kind, null, &gerr) orelse {
        if (gerr) |e| {
            defer e.free();
            err.set(e);
        }
        if (err.name_len == 0) err.setText("no-bus", "no D-Bus bus");
        return null;
    };
    return c;
}

/// A blocking method call. `params` (floating) is consumed. Returns the
/// reply tuple (unref it) or null with `err` set.
pub fn call(
    c: *gio.DBusConnection,
    dest: [*:0]const u8,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    method: [*:0]const u8,
    params: ?V,
    comptime reply_type: ?[:0]const u8,
    timeout_ms: c_int,
    err: *CallError,
) ?V {
    var gerr: ?*glib.Error = null;
    const r = c.callSync(
        dest,
        path,
        iface,
        method,
        params,
        if (reply_type) |t| vtype(t) else null,
        .{},
        timeout_ms,
        null,
        &gerr,
    );
    if (r == null) {
        if (gerr) |e| {
            defer e.free();
            err.set(e);
        } else err.setText("unknown", "D-Bus call failed");
    }
    return r;
}
