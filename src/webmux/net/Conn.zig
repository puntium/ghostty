//! A connected unix stream socket with a read buffer, absolute deadlines on
//! every blocking operation, and `interrupt()`: a thread-safe way to make a
//! read or write that is blocked on another thread return promptly with
//! `error.Interrupted`.
//!
//! Linux only (raw syscalls through `std.os.linux`, so it works with or
//! without libc). The socket is non-blocking; every wait is a `poll` bounded
//! by the caller's deadline.
//!
//! Threading: one thread reads, any number of threads may write if they
//! serialize among themselves (the WebSocket layer does), and any thread may
//! call `interrupt`. `close` must be called once, by the owner, after every
//! other thread is done with the connection.
const Conn = @This();

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const read_buffer_size = 64 * 1024;

/// Absolute CLOCK_MONOTONIC time in nanoseconds, or null for "no deadline".
pub const Deadline = ?i64;

pub const ConnectError = error{
    /// The socket path does not exist.
    FileNotFound,
    /// Nothing is listening on the path (or its backlog is full).
    ConnectionRefused,
    AccessDenied,
    /// Unix socket paths are limited to 107 bytes plus the terminator.
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
fd: linux.fd_t,

/// Guards `closed` against a concurrent `interrupt`, so `interrupt` never
/// touches an fd number that has been closed (and possibly reused).
mutex: std.Io.Mutex = .init,
closed: bool = false,
interrupted: std.atomic.Value(bool) = .init(false),

rbuf: []u8,
rstart: usize = 0,
rend: usize = 0,

/// Monotonic clock in nanoseconds.
pub fn now() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Deadline `ms` milliseconds from now; null stays null (no deadline).
pub fn deadlineIn(ms: ?u32) Deadline {
    const v = ms orelse return null;
    return now() + @as(i64, v) * std.time.ns_per_ms;
}

pub fn connect(alloc: Allocator, io: std.Io, path: []const u8) ConnectError!Conn {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);

    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    while (true) {
        const crc = linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un));
        switch (linux.errno(crc)) {
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
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.Unexpected;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, flags | nonblock)) != .SUCCESS)
        return error.Unexpected;

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
        _ = linux.close(self.fd);
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
    if (!self.closed) _ = linux.shutdown(self.fd, linux.SHUT.RDWR);
}

pub fn isInterrupted(self: *const Conn) bool {
    return self.interrupted.load(.acquire);
}

/// Half-close the write side (the peer reads EOF).
pub fn shutdownWrite(self: *Conn) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.closed) _ = linux.shutdown(self.fd, linux.SHUT.WR);
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
        var pfd = [_]linux.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
        const rc = linux.poll(&pfd, 1, timeout_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unexpected,
        }
        if (rc == 0) continue; // re-check the deadline
        if (self.isInterrupted()) return error.Interrupted;
        return; // ready, or HUP/ERR: the following syscall reports it
    }
}

/// Read straight from the socket (bypassing the buffer). 0 means EOF.
fn rawRead(self: *Conn, buf: []u8, deadline: Deadline) Error!usize {
    while (true) {
        try self.wait(linux.POLL.IN, deadline);
        const rc = linux.read(self.fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0 and self.isInterrupted()) return error.Interrupted;
                return rc;
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
        const rc = linux.sendto(self.fd, rest.ptr, rest.len, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            .AGAIN => try self.wait(linux.POLL.OUT, deadline),
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
