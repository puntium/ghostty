//! The control socket: drive and inspect the running app from outside.
//!
//! When `WEBMUX_GTK_CONTROL` names a path, the application listens on a
//! unix stream socket there (created at startup, removed at exit). The
//! protocol is newline-delimited JSON, one request per line, one response
//! line per request, in order:
//!
//!     -> {"cmd":"dump","id":7}
//!     <- {"id":7,"ok":true,"result":{...}}
//!     <- {"id":7,"ok":false,"error":"no window"}
//!
//! `id` is optional and echoed back verbatim. Every other field of the
//! request object is the command's arguments. Requests on one connection
//! are handled one at a time: the next line is not read until the current
//! command has answered, so a slow command (e.g. `wait`) holds back the
//! ones after it. Use several connections for concurrency.
//!
//! Everything here runs on the GTK main thread (the socket is a GIO
//! `SocketService` on the default main context), so handlers can touch
//! widgets directly.
//!
//! Adding a command, from your own file (see WEBMUX.md › Control socket):
//!
//!     const control = @import("../control.zig"); // path to this file
//!
//!     pub fn register() void {
//!         control.register(.{
//!             .name = "layout",
//!             .help = "dump the column/stack layout",
//!             .handler = &layoutCmd,
//!         });
//!     }
//!
//!     fn layoutCmd(req: *control.Request) void {
//!         const win = control.activeWindow() orelse return req.fail("no window", .{});
//!         req.ok(.{ .columns = win.columnCount() });
//!     }
//!
//! and add `@import("your/file.zig").register();` to `control/commands.zig`.
//! A handler must call `req.ok(value)` or `req.fail(fmt, args)` exactly
//! once, either before it returns or later from a main-loop callback
//! (keep the `*Request`; it stays valid until answered). `value` is any
//! value `std.json.Stringify` can serialize; allocate scratch memory from
//! `req.allocator()` (freed after the answer is sent).

const std = @import("std");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const log = std.log.scoped(.webmux_control);

/// Environment variable that enables the control socket.
pub const env_var = "WEBMUX_GTK_CONTROL";

pub const Handler = *const fn (req: *Request) void;

pub const Command = struct {
    /// The value of the request's `cmd` field.
    name: []const u8,
    /// One line for `help`: arguments and what it does.
    help: []const u8,
    handler: Handler,
};

/// One request being handled. Owned by the control server; valid until
/// `ok` or `fail` is called.
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    conn: *Connection,
    id: std.json.Value,
    cmd: []const u8,
    /// The whole request object (includes `cmd` and `id`).
    args: std.json.ObjectMap,

    /// Scratch allocator, freed when the request is answered.
    pub fn allocator(self: *Request) Allocator {
        return self.arena.allocator();
    }

    pub fn get(self: *Request, key: []const u8) ?std.json.Value {
        return self.args.get(key);
    }

    pub fn string(self: *Request, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn int(self: *Request, key: []const u8) ?i64 {
        return switch (self.get(key) orelse return null) {
            .integer => |i| i,
            .float => |f| if (std.math.isFinite(f)) @intFromFloat(std.math.clamp(@trunc(f), -9e15, 9e15)) else null,
            else => null,
        };
    }

    pub fn boolean(self: *Request, key: []const u8) ?bool {
        return switch (self.get(key) orelse return null) {
            .bool => |b| b,
            else => null,
        };
    }

    /// Answer successfully with `result` (anything std.json can serialize).
    pub fn ok(self: *Request, result: anytype) void {
        const line = std.json.Stringify.valueAlloc(self.allocator(), .{
            .id = self.id,
            .ok = true,
            .result = result,
        }, .{}) catch {
            self.fail("out of memory serializing result", .{});
            return;
        };
        self.finish(line);
    }

    /// Answer with an error message.
    pub fn fail(self: *Request, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.allocator();
        const msg = std.fmt.allocPrint(alloc, fmt, args) catch "out of memory";
        const line = std.json.Stringify.valueAlloc(alloc, .{
            .id = self.id,
            .ok = false,
            .@"error" = msg,
        }, .{}) catch "{\"ok\":false,\"error\":\"out of memory\"}";
        self.finish(line);
    }

    fn finish(self: *Request, line: []const u8) void {
        const conn = self.conn;
        conn.write(line);
        conn.write("\n");
        conn.pending = null;
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
        conn.readNext();
    }
};

//---------------------------------------------------------------
// Registry

var registry: std.ArrayListUnmanaged(Command) = .empty;

/// Register a command. Main thread only; call during startup (from
/// `control/commands.zig`). Duplicate names are a programming error.
pub fn register(cmd: Command) void {
    for (registry.items) |existing| {
        if (std.mem.eql(u8, existing.name, cmd.name)) {
            std.debug.panic("control command registered twice: {s}", .{cmd.name});
        }
    }
    registry.append(std.heap.c_allocator, cmd) catch @panic("OOM");
}

/// The registered commands, in registration order.
pub fn commands() []const Command {
    return registry.items;
}

fn find(name: []const u8) ?Command {
    for (registry.items) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

//---------------------------------------------------------------
// Server

var service: ?*gio.SocketService = null;
var socket_path: ?[:0]u8 = null;

/// Start listening on `path` (removing a stale socket file first).
pub fn start(path: []const u8) !void {
    std.debug.assert(service == null);

    const path_z = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
    errdefer std.heap.c_allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);

    const svc = gio.SocketService.new();
    errdefer svc.unref();

    const addr = gio.UnixSocketAddress.new(path_z.ptr);
    defer addr.unref();

    var err_: ?*glib.Error = null;
    if (svc.as(gio.SocketListener).addAddress(
        addr.as(gio.SocketAddress),
        .stream,
        .default,
        null,
        null,
        &err_,
    ) == 0) {
        if (err_) |e| {
            defer e.free();
            log.err("cannot listen on {s}: {s}", .{ path, e.f_message orelse "(unknown)" });
        }
        return error.ListenFailed;
    }

    _ = gio.SocketService.signals.incoming.connect(svc, ?*anyopaque, onIncoming, null, .{});
    svc.start();
    service = svc;
    socket_path = path_z;
    log.info("control socket listening on {s}", .{path});
}

/// Stop listening and remove the socket file. Open connections are left
/// to finish on their own.
pub fn stop() void {
    if (service) |svc| {
        svc.stop();
        svc.as(gio.SocketListener).close();
        svc.unref();
        service = null;
    }
    if (socket_path) |p| {
        _ = std.c.unlink(p.ptr);
        std.heap.c_allocator.free(p);
        socket_path = null;
    }
}

fn onIncoming(
    _: *gio.SocketService,
    connection: *gio.SocketConnection,
    _: ?*gobject.Object,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const conn = std.heap.c_allocator.create(Connection) catch return 0;
    const io_stream = connection.as(gio.IOStream);
    conn.* = .{
        .connection = @ptrCast(@alignCast(gobject.Object.ref(connection.as(gobject.Object)))),
        .input = gio.DataInputStream.new(io_stream.getInputStream()),
        .output = io_stream.getOutputStream(),
    };
    conn.readNext();
    return 1;
}

pub const Connection = struct {
    connection: *gio.SocketConnection,
    input: *gio.DataInputStream,
    output: *gio.OutputStream,
    pending: ?*Request = null,
    broken: bool = false,

    fn readNext(self: *Connection) void {
        if (self.broken) return self.destroy();
        self.input.readLineAsync(glib.PRIORITY_DEFAULT, null, onLine, self);
    }

    fn write(self: *Connection, bytes: []const u8) void {
        if (self.broken) return;
        var err_: ?*glib.Error = null;
        if (self.output.writeAll(@constCast(bytes.ptr), bytes.len, null, null, &err_) == 0) {
            if (err_) |e| {
                defer e.free();
                log.warn("control write failed: {s}", .{e.f_message orelse "(unknown)"});
            }
            self.broken = true;
        }
    }

    fn destroy(self: *Connection) void {
        _ = self.connection.as(gio.IOStream).close(null, null);
        self.input.unref();
        self.connection.unref();
        std.heap.c_allocator.destroy(self);
    }

    fn onLine(
        source: ?*gobject.Object,
        res: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        _ = source;
        const self: *Connection = @ptrCast(@alignCast(ud.?));

        var len: usize = 0;
        var err_: ?*glib.Error = null;
        const line_ = self.input.readLineFinishUtf8(res, &len, &err_);
        if (err_) |e| {
            defer e.free();
            log.debug("control read ended: {s}", .{e.f_message orelse "(unknown)"});
            return self.destroy();
        }
        // null without error is EOF.
        const line_c = line_ orelse return self.destroy();
        defer glib.free(line_c);

        const line = std.mem.trim(u8, line_c[0..len], " \t\r");
        if (line.len == 0) return self.readNext();
        self.dispatch(line);
    }

    fn dispatch(self: *Connection, line: []const u8) void {
        const req = std.heap.c_allocator.create(Request) catch {
            self.write("{\"ok\":false,\"error\":\"out of memory\"}\n");
            return self.readNext();
        };
        req.* = .{
            .arena = .init(std.heap.c_allocator),
            .conn = self,
            .id = .null,
            .cmd = "",
            .args = undefined,
        };
        self.pending = req;
        const alloc = req.allocator();

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{}) catch |err| {
            req.args = .empty;
            return req.fail("invalid JSON: {t}", .{err});
        };
        switch (parsed) {
            .object => |obj| req.args = obj,
            else => {
                req.args = .empty;
                return req.fail("request must be a JSON object", .{});
            },
        }
        if (req.args.get("id")) |id| req.id = id;
        req.cmd = req.string("cmd") orelse return req.fail("missing \"cmd\"", .{});

        const cmd = find(req.cmd) orelse return req.fail(
            "unknown command \"{s}\" (try \"help\")",
            .{req.cmd},
        );
        log.debug("control cmd={s}", .{req.cmd});
        cmd.handler(req);
    }
};

test "registry rejects nothing it should accept" {
    const testing = std.testing;
    const S = struct {
        fn h(req: *Request) void {
            req.ok(.{});
        }
    };
    const before = commands().len;
    register(.{ .name = "test-only-noop", .help = "", .handler = &S.h });
    try testing.expectEqual(before + 1, commands().len);
    try testing.expect(find("test-only-noop") != null);
    try testing.expect(find("nope") == null);
}
