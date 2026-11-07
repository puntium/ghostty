//! A connected unix stream socket with a read buffer, absolute deadlines on
//! every blocking operation, and `interrupt()`: a thread-safe way to make a
//! read or write that is blocked on another thread return promptly with
//! `error.Interrupted`.
//!
//! On Linux this goes through raw syscalls (`std.os.linux`, so it works
//! with or without libc); everywhere else (macOS for the GhosttyKit build)
//! through libc (`std.c`). The socket is non-blocking; every wait is a
//! `poll` bounded by the caller's deadline. Darwin has no `SOCK_CLOEXEC`
//! or `MSG_NOSIGNAL`, so there the close-on-exec flag is set with fcntl and
//! SIGPIPE is suppressed per socket with `SO_NOSIGPIPE`.
//!
//! Threading: one thread reads, any number of threads may write if they
//! serialize among themselves (the WebSocket layer does), and any thread may
//! call `interrupt`. `close` must be called once, by the owner, after every
//! other thread is done with the connection.
const Conn = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const is_linux = builtin.os.tag == .linux;
const sys = if (is_linux) std.os.linux else std.c;
const E = sys.E;

pub const read_buffer_size = 64 * 1024;

/// Absolute CLOCK_MONOTONIC time in nanoseconds, or null for "no deadline".
pub const Deadline = ?i64;

pub const ConnectError = error{
    /// The socket path does not exist.
    FileNotFound,
    /// Nothing is listening on the path (or its backlog is full).
    ConnectionRefused,
    AccessDenied,
    /// Unix socket paths are limited to 107 bytes plus the terminator
    /// (103 on Darwin).
    NameTooLong,
    SystemResources,
    OutOfMemory,
    Unexpected,
};

pub const Error = error{
    /// The deadline passed.
    Timeout,
    /// `interrupt()` was called.
    Interrupted,
    /// The peer closed the connection before the expected data arrived.
    EndOfStream,
    ConnectionReset,
    BrokenPipe,
    /// A line exceeded the caller's limit.
    LineTooLong,
    Unexpected,
};

io: std.Io,
alloc: Allocator,
fd: std.posix.fd_t,

/// Guards `closed` against a concurrent `interrupt`, so `interrupt` never
/// touches an fd number that has been closed (and possibly reused).
mutex: std.Io.Mutex = .init,
closed: bool = false,
interrupted: std.atomic.Value(bool) = .init(false),

rbuf: []u8,
rstart: usize = 0,
rend: usize = 0,

/// The result of a system call: its errno (SUCCESS when it worked) and its
/// return value as a signed integer. Linux syscalls return a usize that
/// encodes the error; libc returns -1 and sets errno. Both go through here.
const Rc = struct { err: E, val: isize };

fn check(r: anytype) Rc {
    const err = sys.errno(r);
    const val: isize = if (is_linux) @bitCast(r) else @intCast(r);
    return .{ .err = err, .val = val };
}

/// Monotonic clock in nanoseconds.
pub fn now() i64 {
    var ts: sys.timespec = undefined;
    _ = sys.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Deadline `ms` milliseconds from now; null stays null (no deadline).
pub fn deadlineIn(ms: ?u32) Deadline {
    const v = ms orelse return null;
    return now() + @as(i64, v) * std.time.ns_per_ms;
}

pub fn connect(alloc: Allocator, io: std.Io, path: []const u8) ConnectError!Conn {
    var addr: sys.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);

    const sr = check(if (is_linux)
        sys.socket(sys.AF.UNIX, sys.SOCK.STREAM | sys.SOCK.CLOEXEC, 0)
    else
        sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0));
    switch (sr.err) {
        .SUCCESS => {},
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    const fd: std.posix.fd_t = @intCast(sr.val);
    errdefer _ = sys.close(fd);

    if (!is_linux) {
        // No SOCK_CLOEXEC and no MSG_NOSIGNAL on Darwin: set the flag on
        // the descriptor and suppress SIGPIPE on this socket instead.
        if (check(sys.fcntl(fd, sys.F.SETFD, @as(c_int, sys.FD_CLOEXEC))).err != .SUCCESS)
            return error.Unexpected;
        const one: c_int = 1;
        if (check(sys.setsockopt(fd, sys.SOL.SOCKET, sys.SO.NOSIGPIPE, &one, @sizeOf(c_int))).err != .SUCCESS)
            return error.Unexpected;
    }

    while (true) {
        const cr = check(sys.connect(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.un)));
        switch (cr.err) {
            .SUCCESS => break,
            .INTR => continue,
            .NOENT, .NOTDIR => return error.FileNotFound,
            .CONNREFUSED, .AGAIN => return error.ConnectionRefused,
            .ACCES, .PERM => return error.AccessDenied,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.Unexpected,
        }
    }

    // Non-blocking from here on: every wait goes through poll().
    const fr = check(sys.fcntl(fd, sys.F.GETFL, @as(c_int, 0)));
    if (fr.err != .SUCCESS) return error.Unexpected;
    const nonblock: u32 = @bitCast(sys.O{ .NONBLOCK = true });
    const flags: u32 = @intCast(fr.val);
    const set = if (is_linux)
        sys.fcntl(fd, sys.F.SETFL, @as(usize, flags | nonblock))
    else
        sys.fcntl(fd, sys.F.SETFL, @as(c_int, @intCast(flags | nonblock)));
    if (check(set).err != .SUCCESS) return error.Unexpected;

    const rbuf = try alloc.alloc(u8, read_buffer_size);
    return .{ .io = io, .alloc = alloc, .fd = fd, .rbuf = rbuf };
}

/// Close the socket and free the buffer. Call once, after every other thread
/// has stopped using the connection (`interrupt` may still race with this
/// safely).
pub fn close(self: *Conn) void {
    self.mutex.lockUncancelable(self.io);
    if (!self.closed) {
        self.closed = true;
        _ = sys.close(self.fd);
    }
    self.mutex.unlock(self.io);
    self.alloc.free(self.rbuf);
    self.rbuf = &.{};
}

/// Make any blocked or future read/write fail with `error.Interrupted`.
/// Thread-safe and idempotent. Implemented with shutdown(2), which wakes a
/// poll() on another thread; nothing is sent to the peer beyond the FIN.
pub fn interrupt(self: *Conn) void {
    self.interrupted.store(true, .release);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.closed) _ = sys.shutdown(self.fd, sys.SHUT.RDWR);
}

pub fn isInterrupted(self: *const Conn) bool {
    return self.interrupted.load(.acquire);
}

fn wait(self: *Conn, events: i16, deadline: Deadline) Error!void {
    while (true) {
        if (self.isInterrupted()) return error.Interrupted;
        var timeout_ms: i32 = -1;
        if (deadline) |d| {
            const left = d - now();
            if (left <= 0) return error.Timeout;
            timeout_ms = @intCast(@min(std.math.maxInt(i32), @divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        }
        var pfd = [_]sys.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
        const pr = check(sys.poll(&pfd, 1, timeout_ms));
        switch (pr.err) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unexpected,
        }
        if (pr.val == 0) continue; // re-check the deadline
        if (self.isInterrupted()) return error.Interrupted;
        return; // ready, or HUP/ERR: the following syscall reports it
    }
}

/// Read straight from the socket (bypassing the buffer). 0 means EOF.
fn rawRead(self: *Conn, buf: []u8, deadline: Deadline) Error!usize {
    while (true) {
        try self.wait(sys.POLL.IN, deadline);
        const rr = check(sys.read(self.fd, buf.ptr, buf.len));
        switch (rr.err) {
            .SUCCESS => {
                if (rr.val == 0 and self.isInterrupted()) return error.Interrupted;
                return @intCast(rr.val);
            },
            .INTR, .AGAIN => continue,
            .CONNRESET => return if (self.isInterrupted()) error.Interrupted else error.ConnectionReset,
            .PIPE => return if (self.isInterrupted()) error.Interrupted else error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
}

/// Write all of `bytes`. Never raises SIGPIPE.
pub fn writeAll(self: *Conn, bytes: []const u8, deadline: Deadline) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        if (self.isInterrupted()) return error.Interrupted;
        const rest = bytes[off..];
        const sr = check(if (is_linux)
            sys.sendto(self.fd, rest.ptr, rest.len, sys.MSG.NOSIGNAL | sys.MSG.DONTWAIT, null, 0)
        else
            sys.send(self.fd, rest.ptr, rest.len, sys.MSG.DONTWAIT));
        switch (sr.err) {
            .SUCCESS => off += @intCast(sr.val),
            .INTR => {},
            .AGAIN => try self.wait(sys.POLL.OUT, deadline),
            .PIPE => return if (self.isInterrupted()) error.Interrupted else error.BrokenPipe,
            .CONNRESET => return if (self.isInterrupted()) error.Interrupted else error.ConnectionReset,
            else => return error.Unexpected,
        }
    }
}

/// Bytes currently buffered and not yet consumed.
pub fn buffered(self: *const Conn) []const u8 {
    return self.rbuf[self.rstart..self.rend];
}

/// Read more from the socket into the buffer. Returns false on EOF.
pub fn fill(self: *Conn, deadline: Deadline) Error!bool {
    if (self.rstart > 0) {
        const n = self.rend - self.rstart;
        std.mem.copyForwards(u8, self.rbuf[0..n], self.rbuf[self.rstart..self.rend]);
        self.rstart = 0;
        self.rend = n;
    }
    if (self.rend == self.rbuf.len) return true; // full; caller consumes first
    const n = try self.rawRead(self.rbuf[self.rend..], deadline);
    if (n == 0) return false;
    self.rend += n;
    return true;
}

/// Read up to `out.len` bytes: buffered bytes first, otherwise one socket
/// read. Returns 0 only at EOF.
pub fn readSome(self: *Conn, out: []u8, deadline: Deadline) Error!usize {
    if (out.len == 0) return 0;
    if (self.rend > self.rstart) {
        const n = @min(out.len, self.rend - self.rstart);
        @memcpy(out[0..n], self.rbuf[self.rstart..][0..n]);
        self.rstart += n;
        return n;
    }
    // Large reads skip the buffer.
    if (out.len >= self.rbuf.len) return self.rawRead(out, deadline);
    self.rstart = 0;
    self.rend = 0;
    if (!try self.fill(deadline)) return 0;
    return self.readSome(out, deadline);
}

/// Fill `out` completely or fail with `error.EndOfStream`.
pub fn readExact(self: *Conn, out: []u8, deadline: Deadline) Error!void {
    var off: usize = 0;
    while (off < out.len) {
        const n = try self.readSome(out[off..], deadline);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

/// Read one line terminated by "\n" (a preceding "\r" is stripped). The
/// returned slice points into the buffer and is valid until the next read.
/// Lines longer than `max` (or than the buffer) fail with LineTooLong. At
/// EOF with nothing buffered, returns null; a partial last line at EOF is
/// returned as is.
pub fn readLine(self: *Conn, max: usize, deadline: Deadline) Error!?[]const u8 {
    var scanned: usize = 0;
    while (true) {
        const avail = self.rbuf[self.rstart..self.rend];
        if (std.mem.indexOfScalarPos(u8, avail, scanned, '\n')) |i| {
            var line = avail[0..i];
            self.rstart += i + 1;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len > max) return error.LineTooLong;
            return line;
        }
        scanned = avail.len;
        if (avail.len > max or avail.len == self.rbuf.len) return error.LineTooLong;
        const before = self.rend - self.rstart;
        if (!try self.fill(deadline)) {
            if (before == 0) return null;
            const line = self.rbuf[self.rstart..self.rend];
            self.rstart = self.rend;
            return line;
        }
        // fill() may have compacted the buffer: rescan from where we were.
        scanned = before;
    }
}

test "connect, write, read, interrupt (loopback unix socket)" {
    // A tiny echo peer on a listening unix socket, through std.Io.net, so
    // the test runs on Linux and Darwin alike.
    const testing = std.testing;
    const io = testing.io;
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/wm-conn-{x}.sock", .{testing.random_seed});
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const addr = try std.Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    const Peer = struct {
        fn run(srv: *std.Io.net.Server, io_: std.Io) void {
            const stream = srv.accept(io_) catch return;
            defer stream.close(io_);
            // Through the Reader interface: `Stream.read` itself does not
            // compile on zig 0.17.0 (a std bug in its destructuring).
            var rbuf: [64]u8 = undefined;
            var r = stream.reader(io_, &rbuf);
            var b: [64]u8 = undefined;
            var iov = [_][]u8{&b};
            const n = r.interface.readVec(&iov) catch return;
            var wbuf: [64]u8 = undefined;
            var w = stream.writer(io_, &wbuf);
            w.interface.writeAll(b[0..n]) catch return;
            w.interface.flush() catch return;
        }
    };
    const t = try std.Thread.spawn(.{}, Peer.run, .{ &server, io });

    var c = try Conn.connect(testing.allocator, io, path);
    defer c.close();
    try c.writeAll("hello\n", deadlineIn(2000));
    const line = (try c.readLine(64, deadlineIn(2000))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("hello", line);
    t.join();

    // The peer has closed: a read returns EOF (0), and after interrupt()
    // every operation fails with Interrupted.
    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try c.readSome(&out, deadlineIn(2000)));
    c.interrupt();
    try testing.expectError(error.Interrupted, c.readSome(&out, deadlineIn(2000)));
    try testing.expectError(error.Interrupted, c.writeAll("x", deadlineIn(2000)));
}

test "deadline: a read with nothing to read times out" {
    const testing = std.testing;
    const io = testing.io;
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/wm-conn-t-{x}.sock", .{testing.random_seed});
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const addr = try std.Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var c = try Conn.connect(testing.allocator, io, path);
    defer c.close();
    var out: [8]u8 = undefined;
    const t0 = now();
    try testing.expectError(error.Timeout, c.readSome(&out, deadlineIn(50)));
    try testing.expect(now() - t0 >= 40 * std.time.ns_per_ms);
}

test "connect errors" {
    const testing = std.testing;
    try testing.expectError(error.FileNotFound, Conn.connect(testing.allocator, testing.io, "/tmp/wm-conn-does-not-exist.sock"));
    var long: [205]u8 = undefined;
    @memset(&long, 'x');
    @memcpy(long[0..5], "/tmp/");
    try testing.expectError(error.NameTooLong, Conn.connect(testing.allocator, testing.io, &long));
}
