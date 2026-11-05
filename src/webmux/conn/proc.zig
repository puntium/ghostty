//! Child processes for the supervisor: spawn (via std.process.spawn), a
//! pollable exit fd (pidfd), interruptible I/O loops, and kill-then-reap.
//!
//! Every blocking wait here polls a "wake" fd as well, so a command from
//! the shell (disconnect, reconnect, quit) interrupts it promptly.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const c = std.c;
const posix = std.posix;
const linux = std.os.linux;
const util = @import("util.zig");

pub const Exit = union(enum) {
    code: u8,
    signal: u32,
    unknown,

    /// `code ?? signal` as main.js formats it: `255`, `SIGTERM`.
    pub fn format(e: Exit, w: *Io.Writer) Io.Writer.Error!void {
        switch (e) {
            .code => |n| try w.print("{d}", .{n}),
            .signal => |s| try w.writeAll(signalName(s)),
            .unknown => try w.writeAll("null"),
        }
    }

    pub fn ok(e: Exit) bool {
        return e == .code and e.code == 0;
    }
};

pub fn signalName(s: u32) []const u8 {
    return switch (s) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        6 => "SIGABRT",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        else => "SIGNAL",
    };
}

pub const Stdio = enum { pipe, ignore };

pub const SpawnOptions = struct {
    stdin: Stdio = .ignore,
    stdout: Stdio = .ignore,
    stderr: Stdio = .pipe,
    cwd: ?[]const u8 = null,
};

pub const Proc = struct {
    io: Io,
    child: std.process.Child,
    pid: posix.pid_t,
    /// Readable once the child has exited (pidfd). -1 if unavailable.
    exit_fd: posix.fd_t,
    reaped: ?Exit = null,

    pub fn stdinFd(p: *Proc) ?posix.fd_t {
        return if (p.child.stdin) |f| f.handle else null;
    }
    pub fn stdoutFd(p: *Proc) ?posix.fd_t {
        return if (p.child.stdout) |f| f.handle else null;
    }
    pub fn stderrFd(p: *Proc) ?posix.fd_t {
        return if (p.child.stderr) |f| f.handle else null;
    }

    pub fn closeStdin(p: *Proc) void {
        if (p.child.stdin) |f| {
            _ = c.close(f.handle);
            p.child.stdin = null;
        }
    }

    /// Send a signal (ignored once reaped).
    pub fn signal(p: *Proc, sig: posix.SIG) void {
        if (p.reaped != null) return;
        posix.kill(p.pid, sig) catch {};
    }

    /// True once the child has exited (does not reap).
    pub fn exited(p: *Proc, timeout_ms: i32) bool {
        if (p.reaped != null) return true;
        if (p.exit_fd < 0) return false;
        var fds = [_]posix.pollfd{.{ .fd = p.exit_fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return false;
        return n > 0;
    }

    /// Reap the child (blocks until it exits) and release its fds.
    pub fn wait(p: *Proc) Exit {
        if (p.reaped) |e| return e;
        const term = p.child.wait(p.io) catch {
            p.reaped = .unknown;
            p.closeExitFd();
            return .unknown;
        };
        const e: Exit = switch (term) {
            .exited => |code| .{ .code = code },
            .signal => |s| .{ .signal = @intCast(@backingInt(s)) },
            else => .unknown,
        };
        p.reaped = e;
        p.closeExitFd();
        return e;
    }

    fn closeExitFd(p: *Proc) void {
        if (p.exit_fd >= 0) _ = c.close(p.exit_fd);
        p.exit_fd = -1;
    }

    /// SIGTERM, then SIGKILL if it is still alive after `grace_ms`; reaps.
    pub fn terminate(p: *Proc, grace_ms: i32) Exit {
        if (p.reaped) |e| return e;
        p.signal(.TERM);
        if (!p.exited(grace_ms)) p.signal(.KILL);
        return p.wait();
    }
};

pub const SpawnError = error{ FileNotFound, AccessDenied, SpawnFailed };

pub fn spawn(io: Io, argv: []const []const u8, env: *const EnvMap, opts: SpawnOptions) SpawnError!Proc {
    const conv = struct {
        fn f(s: Stdio) std.process.SpawnOptions.StdIo {
            return switch (s) {
                .pipe => .pipe,
                .ignore => .ignore,
            };
        }
    };
    const child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = conv.f(opts.stdin),
        .stdout = conv.f(opts.stdout),
        .stderr = conv.f(opts.stderr),
        .cwd = if (opts.cwd) |d| .{ .path = d } else .inherit,
    }) catch |e| return switch (e) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.SpawnFailed,
    };
    const pid = child.id.?;
    const rc = linux.pidfd_open(pid, 0);
    const exit_fd: posix.fd_t = if (linux.errno(rc) == .SUCCESS) @intCast(rc) else -1;
    if (exit_fd >= 0) _ = c.fcntl(exit_fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    for ([_]?Io.File{ child.stdin, child.stdout, child.stderr }) |f| if (f) |file| setNonblock(file.handle);
    return .{ .io = io, .child = child, .pid = pid, .exit_fd = exit_fd };
}

/// "spawn ssh ENOENT"-style text for a spawn failure (Node's wording).
pub fn spawnErrorText(buf: []u8, prog: []const u8, e: SpawnError) []const u8 {
    const code = switch (e) {
        error.FileNotFound => "ENOENT",
        error.AccessDenied => "EACCES",
        error.SpawnFailed => "failed",
    };
    return std.fmt.bufPrint(buf, "spawn {s} {s}", .{ std.fs.path.basename(prog), code }) catch "spawn failed";
}

pub fn setNonblock(fd: posix.fd_t) void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return;
    const nb: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    _ = c.fcntl(fd, c.F.SETFL, flags | nb);
}

/// Read what is available. Returns null on EAGAIN, 0 on EOF.
pub fn readSome(fd: posix.fd_t, buf: []u8) ?usize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return null,
            else => return 0,
        }
    }
}

/// Splits a byte stream into lines (no empty lines, as main.js filters
/// them), carrying partial lines across reads.
pub const LineSplitter = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn feed(self: *LineSplitter, bytes: []const u8, ctx: anytype, comptime onLine: fn (@TypeOf(ctx), []const u8) void) void {
        for (bytes) |b| {
            if (b == '\n') {
                self.flush(ctx, onLine);
                continue;
            }
            if (self.len == self.buf.len) self.flush(ctx, onLine);
            self.buf[self.len] = b;
            self.len += 1;
        }
    }

    pub fn flush(self: *LineSplitter, ctx: anytype, comptime onLine: fn (@TypeOf(ctx), []const u8) void) void {
        const line = std.mem.trimEnd(u8, self.buf[0..self.len], "\r");
        self.len = 0;
        if (line.len > 0) onLine(ctx, line);
    }
};

/// Drain a wake pipe (non-blocking).
pub fn drain(fd: posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = readSome(fd, &buf) orelse return;
        if (n == 0) return;
    }
}

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Polled alongside the child's fds; when readable `shouldCancel` is
    /// asked (it should drain the fd).
    wake_fd: posix.fd_t,
    shouldCancel: *const fn (ctx: *anyopaque) bool,
    stderrLine: *const fn (ctx: *anyopaque, line: []const u8) void,
    /// Push progress (stdin feeding): bytes sent / total.
    progress: ?*const fn (ctx: *anyopaque, sent: u64, total: u64) void = null,
    spawned: ?*const fn (ctx: *anyopaque, pid: posix.pid_t) void = null,
};

pub const RunResult = struct {
    stdout: []u8,
    exit: Exit,
    pid: posix.pid_t,
};

pub const RunError = error{ Cancelled, OutOfMemory, InputUnreadable } || SpawnError;

pub const RunOptions = struct {
    /// Stream this file to the child's stdin (then close it).
    stdin_file: ?[]const u8 = null,
    /// Kill the child (SIGTERM) after this long.
    timeout_ms: ?i64 = null,
    max_stdout: usize = 4 * 1024 * 1024,
};

/// Run a command to completion: collect stdout, hand stderr lines to the
/// hooks, optionally feed a file to stdin, honour cancellation and a
/// timeout. A cancelled run kills the child and returns error.Cancelled.
pub fn run(alloc: Allocator, io: Io, argv: []const []const u8, env: *const EnvMap, hooks: Hooks, opts: RunOptions) RunError!RunResult {
    var input_fd: c.fd_t = -1;
    var input_total: u64 = 0;
    if (opts.stdin_file) |path| {
        input_total = util.fileSize(path) orelse return error.InputUnreadable;
        var pbuf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return error.InputUnreadable;
        input_fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
        if (input_fd < 0) return error.InputUnreadable;
    }
    defer if (input_fd >= 0) {
        _ = c.close(input_fd);
    };

    var p = try spawn(io, argv, env, .{ .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    if (hooks.spawned) |f| f(hooks.ctx, p.pid);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    if (input_fd < 0) p.closeStdin() // child.stdin.end()
    else if (hooks.progress) |f| f(hooks.ctx, 0, input_total);

    const Ctx = struct {
        hooks: Hooks,
        fn line(self: *const @This(), l: []const u8) void {
            self.hooks.stderrLine(self.hooks.ctx, l);
        }
    };
    const lctx: Ctx = .{ .hooks = hooks };
    var err_split: LineSplitter = .{};
    var chunk: [65536]u8 = undefined;
    var in_buf: [65536]u8 = undefined;
    var in_len: usize = 0;
    var in_off: usize = 0;
    var sent: u64 = 0;
    var input_eof = input_fd < 0;
    const deadline: ?i64 = if (opts.timeout_ms) |t| util.monoMs(io) + t else null;
    var timed_out = false;

    loop: while (true) {
        var fds: [5]posix.pollfd = undefined;
        var n: usize = 0;
        fds[n] = .{ .fd = hooks.wake_fd, .events = posix.POLL.IN, .revents = 0 };
        n += 1;
        const i_out = n;
        fds[n] = .{ .fd = p.stdoutFd() orelse -1, .events = posix.POLL.IN, .revents = 0 };
        n += 1;
        const i_err = n;
        fds[n] = .{ .fd = p.stderrFd() orelse -1, .events = posix.POLL.IN, .revents = 0 };
        n += 1;
        const i_exit = n;
        fds[n] = .{ .fd = p.exit_fd, .events = posix.POLL.IN, .revents = 0 };
        n += 1;
        const i_in = n;
        fds[n] = .{ .fd = p.stdinFd() orelse -1, .events = posix.POLL.OUT, .revents = 0 };
        n += 1;

        var timeout: i32 = -1;
        if (deadline) |d| {
            const left = d - util.monoMs(io);
            if (left <= 0) {
                if (!timed_out) {
                    timed_out = true;
                    p.signal(.TERM);
                }
                timeout = 200;
            } else timeout = @intCast(@min(left, 60_000));
        }
        // Without a pidfd, fall back to polling for exit.
        if (p.exit_fd < 0 and timeout < 0) timeout = 100;
        _ = posix.poll(fds[0..n], timeout) catch {};

        if (fds[0].revents != 0) {
            if (hooks.shouldCancel(hooks.ctx)) {
                _ = p.terminate(2000);
                return error.Cancelled;
            }
        }
        if (fds[i_out].revents != 0) if (p.stdoutFd()) |fd| {
            while (readSome(fd, &chunk)) |got| {
                if (got == 0) {
                    closeChildStream(&p, .stdout);
                    break;
                }
                if (out.items.len + got <= opts.max_stdout) try out.appendSlice(alloc, chunk[0..got]);
            }
        };
        if (fds[i_err].revents != 0) if (p.stderrFd()) |fd| {
            while (readSome(fd, &chunk)) |got| {
                if (got == 0) {
                    err_split.flush(&lctx, Ctx.line);
                    closeChildStream(&p, .stderr);
                    break;
                }
                err_split.feed(chunk[0..got], &lctx, Ctx.line);
            }
        };
        if (fds[i_in].revents != 0) if (p.stdinFd()) |fd| {
            if (fds[i_in].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
                // remote side gone (EPIPE) — the exit status reports it
                p.closeStdin();
            } else {
                while (true) {
                    if (in_off == in_len and !input_eof) {
                        const r = c.read(input_fd, &in_buf, in_buf.len);
                        if (r <= 0) {
                            input_eof = true;
                        } else {
                            in_len = @intCast(r);
                            in_off = 0;
                        }
                    }
                    if (in_off == in_len) {
                        if (input_eof) p.closeStdin();
                        break;
                    }
                    const w = c.write(fd, in_buf[in_off..in_len].ptr, in_len - in_off);
                    if (w < 0) {
                        const e = posix.errno(w);
                        if (e == .INTR) continue;
                        if (e != .AGAIN) p.closeStdin();
                        break;
                    }
                    in_off += @intCast(w);
                    const before = sent;
                    sent += @intCast(w);
                    if (hooks.progress) |f| if (input_total > 0 and sent * 100 / input_total != before * 100 / input_total) f(hooks.ctx, sent, input_total);
                }
            }
        };

        const child_gone = (p.exit_fd >= 0 and fds[i_exit].revents != 0) or (p.exit_fd < 0 and p.stdoutFd() == null and p.stderrFd() == null);
        if (child_gone or (p.stdoutFd() == null and p.stderrFd() == null and p.stdinFd() == null)) {
            if (p.stdoutFd() == null and p.stderrFd() == null) break :loop;
            if (child_gone) {
                // Exited, but a grandchild may hold the pipes open: take
                // what is buffered and stop.
                if (p.stdoutFd()) |fd| while (readSome(fd, &chunk)) |got| {
                    if (got == 0) break;
                    if (out.items.len + got <= opts.max_stdout) try out.appendSlice(alloc, chunk[0..got]);
                };
                if (p.stderrFd()) |fd| while (readSome(fd, &chunk)) |got| {
                    if (got == 0) break;
                    err_split.feed(chunk[0..got], &lctx, Ctx.line);
                };
                err_split.flush(&lctx, Ctx.line);
                break :loop;
            }
        }
    }
    const exit = p.wait();
    return .{ .stdout = try out.toOwnedSlice(alloc), .exit = exit, .pid = p.pid };
}

fn closeChildStream(p: *Proc, which: enum { stdout, stderr }) void {
    switch (which) {
        .stdout => if (p.child.stdout) |f| {
            _ = c.close(f.handle);
            p.child.stdout = null;
        },
        .stderr => if (p.child.stderr) |f| {
            _ = c.close(f.handle);
            p.child.stderr = null;
        },
    }
}

/// A self-pipe used to interrupt polls from other threads.
pub const WakePipe = struct {
    r: posix.fd_t,
    w: posix.fd_t,

    pub fn init() !WakePipe {
        var fds: [2]posix.fd_t = undefined;
        if (c.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }) != 0) return error.PipeFailed;
        return .{ .r = fds[0], .w = fds[1] };
    }
    pub fn deinit(self: WakePipe) void {
        _ = c.close(self.r);
        _ = c.close(self.w);
    }
    pub fn wake(self: WakePipe) void {
        const b = [_]u8{1};
        _ = c.write(self.w, &b, 1);
    }
};
