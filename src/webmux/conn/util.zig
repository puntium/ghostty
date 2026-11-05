//! Small helpers shared by the conn package: time, JSON/JS-compatible
//! formatting, file primitives (atomic write, append, mkdir -p with mode).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = std.c;

/// Monotonic milliseconds (CLOCK_MONOTONIC).
pub fn monoMs(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// Wall-clock milliseconds since the Unix epoch.
pub fn wallMs(io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

/// JS `new Date().toISOString()`: `2026-11-04T12:34:56.789Z`.
pub fn isoNow(io: Io, buf: *[32]u8) []const u8 {
    return isoFromMs(wallMs(io), buf);
}

pub fn isoFromMs(ms: i64, buf: *[32]u8) []const u8 {
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const millis: u64 = @intCast(@mod(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        millis,
    }) catch unreachable;
}

/// JSON.stringify for a string: quotes, `\"`, `\\`, the short escapes and
/// `\u00XX` for other control characters. Everything else verbatim.
pub fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...7, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// JS `String(number)` for the values we log (integers print without a
/// fraction).
pub fn writeJsNumber(w: *Io.Writer, f: f64) Io.Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("NaN");
    if (std.math.isInf(f)) return w.writeAll(if (f > 0) "Infinity" else "-Infinity");
    // Whole numbers below 1e21 print without a fraction, like JS; i128
    // holds every one of them (2^63 ≤ |f| < 1e21 does not fit an i64).
    if (@floor(f) == f and @abs(f) < 1e21) return w.print("{d}", .{@as(i128, @intFromFloat(f))});
    return w.print("{d}", .{f});
}

/// The first `max` UTF-8 code points of `s` (JS `slice(0, max)`, counting
/// code points rather than UTF-16 units).
pub fn clipChars(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n == max) return s[0..i];
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + len);
        n += 1;
    }
    return s;
}

pub fn sha256Hex(data: []const []const u8, out: *[64]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (data) |d| h.update(d);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
}

fn toZ(buf: []u8, s: []const u8) ![:0]const u8 {
    if (s.len + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// `mkdir -p` for an absolute path; every directory it creates gets `mode`.
/// An existing final directory has its mode left alone unless
/// `force_mode_last` (then it is chmod'ed to `mode`).
pub fn makePath(io: Io, path: []const u8, mode: u32) !void {
    _ = io;
    var buf: [4096]u8 = undefined;
    if (path.len == 0) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const z = try toZ(&buf, path[0..i]);
            if (c.mkdir(z, @intCast(mode)) != 0) {
                const e = std.posix.errno(@as(c_int, -1));
                if (e != .EXIST) return error.MakePathFailed;
            }
        }
    }
}

/// A directory we own, not a symlink, mode forced to 0700 — the runtime dir
/// holds the tunnel sockets and the askpass helper.
pub fn ensurePrivateDir(path: []const u8) !void {
    const linux = std.os.linux;
    var buf: [4096]u8 = undefined;
    const z = try toZ(&buf, path);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z, 0x100, .{ .TYPE = true, .MODE = true, .UID = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
    if (!linux.S.ISDIR(st.mode)) return error.NotADirectory;
    if (st.uid != c.getuid()) return error.NotOwned;
    try chmod(path, 0o700);
}

pub fn chmod(path: []const u8, mode: u32) !void {
    var buf: [4096]u8 = undefined;
    const z = try toZ(&buf, path);
    if (c.chmod(z, @intCast(mode)) != 0) return error.ChmodFailed;
}

/// Append bytes to a file, creating it (0600) if needed.
pub fn appendToFile(io: Io, path: []const u8, bytes: []const u8) !void {
    _ = io;
    var buf: [4096]u8 = undefined;
    const z = try toZ(&buf, path);
    const fd = c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try writeAllFd(fd, bytes);
}

pub fn writeAllFd(fd: c.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}

/// Write a file atomically: `<path>.tmp-<pid>` with `mode`, fsync, rename.
pub fn atomicWrite(io: Io, path: []const u8, bytes: []const u8, mode: u32) !void {
    _ = io;
    var tmp_buf: [4096]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}.tmp-{d}", .{ path, c.getpid() }, 0);
    var dst_buf: [4096]u8 = undefined;
    const dst = try toZ(&dst_buf, path);
    const fd = c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, @intCast(mode)));
    if (fd < 0) return error.OpenFailed;
    var ok = false;
    defer if (!ok) {
        _ = c.unlink(tmp);
    };
    {
        defer _ = c.close(fd);
        try writeAllFd(fd, bytes);
        if (c.fsync(fd) != 0) return error.SyncFailed;
    }
    if (c.rename(tmp, dst) != 0) return error.RenameFailed;
    ok = true;
}

/// Read a whole file (null if it does not exist).
pub fn readFileAlloc(io: Io, alloc: Allocator, path: []const u8, limit: usize) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(limit)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

pub fn fileExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = toZ(&buf, path) catch return false;
    return c.access(z, 0) == 0;
}

pub fn unlinkPath(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = toZ(&buf, path) catch return;
    _ = c.unlink(z);
}

pub fn fileSize(path: []const u8) ?u64 {
    var buf: [4096]u8 = undefined;
    const z = toZ(&buf, path) catch return null;
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, c.SEEK.END);
    if (end < 0) return null;
    return @intCast(end);
}

test "iso timestamps" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", isoFromMs(0, &buf));
    try std.testing.expectEqualStrings("2026-11-04T22:52:12.604Z", isoFromMs(1793832732604, &buf));
}

test "clipChars counts code points" {
    try std.testing.expectEqualStrings("ab", clipChars("abc", 2));
    try std.testing.expectEqualStrings("a—", clipChars("a—b", 2));
    try std.testing.expectEqualStrings("abc", clipChars("abc", 10));
}
