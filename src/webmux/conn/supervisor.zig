//! One supervised connection: main.js's connectConn / startTunnel /
//! runDeploy / spawnTunnel / onTunnelDown / scheduleRetry / probeLoop /
//! onServerUp state machine, run sequentially on the connection's own
//! thread. Where main.js juggles callbacks and a `generation` counter to
//! orphan stale handlers, this thread simply does one thing at a time and
//! every blocking wait also watches a wake pipe for commands from the
//! shell (connect/reconnect, disconnect, resume, quit).
//!
//! States: connecting → connected; a drop of a cycle that was ever
//! connected → retry (backoff 1 s doubling to 15 s, deploy re-run on every
//! attempt); a drop of a cycle that never connected → failed (parked with
//! ssh's stderr, no background retry).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const api = @import("../conn.zig");
const Engine = @import("engine.zig").Engine;
const Log = @import("log.zig");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const paths = @import("paths.zig");
const util = @import("util.zig");
const ssh = @import("ssh.zig");
const proc = @import("proc.zig");
const deploy = @import("deploy.zig");

const TAIL = 8;

pub fn blockSigpipe() void {
    var set = posix.sigemptyset();
    posix.sigaddset(&set, .PIPE);
    posix.sigprocmask(posix.SIG.BLOCK, &set, null);
}

pub const Conn = struct {
    engine: *Engine,
    alloc: Allocator,
    io: Io,
    thread: ?std.Thread = null,
    wake: proc.WakePipe,

    /// Guards everything below.
    mutex: Io.Mutex = .init,
    name: []u8,
    profile: Profile,

    // commands (set by the shell's thread, consumed here)
    cmd_connect: ?[]const u8 = null,
    cmd_disconnect: ?[]const u8 = null,
    cmd_resume: bool = false,
    cmd_quit: bool = false,
    finished: bool = false,

    // status
    state: api.State = .connecting,
    msg: std.ArrayList(u8) = .empty,
    tail: [TAIL]?[]u8 = @splat(null),
    tail_len: usize = 0,
    step: api.Step = .idle,
    push_sent: u64 = 0,
    push_total: u64 = 0,
    retry_delay_s: u32 = 0,
    retry_at_ms: i64 = 0,
    socket_path: ?[]u8 = null,
    remote_socket: ?[]u8 = null,
    had_connection: bool = false,
    tunnel_pid: ?posix.pid_t = null,
    deploy_pid: ?posix.pid_t = null,

    // supervisor-thread-only
    retry_delay_ms: u32 = 0,
    last_step: std.ArrayList(u8) = .empty,
    disconnecting: bool = false,

    pub fn create(e: *Engine, p: Profile) !*Conn {
        const c = try e.alloc.create(Conn);
        errdefer e.alloc.destroy(c);
        c.* = .{
            .engine = e,
            .alloc = e.alloc,
            .io = e.io,
            .wake = try proc.WakePipe.init(),
            .name = try e.alloc.dupe(u8, p.name),
            .profile = try p.clone(e.alloc),
        };
        return c;
    }

    pub fn start(c: *Conn) !void {
        c.thread = try std.Thread.spawn(.{}, threadMain, .{c});
    }

    pub fn join(c: *Conn) void {
        if (c.thread) |t| t.join();
        c.thread = null;
    }

    pub fn destroy(c: *Conn) void {
        const a = c.alloc;
        c.wake.deinit();
        a.free(c.name);
        c.profile.deinit(a);
        c.msg.deinit(a);
        for (&c.tail) |*t| if (t.*) |l| {
            a.free(l);
            t.* = null;
        };
        if (c.socket_path) |s| a.free(s);
        if (c.remote_socket) |s| a.free(s);
        c.last_step.deinit(a);
        a.destroy(c);
    }

    fn lock(c: *Conn) void {
        c.mutex.lockUncancelable(c.io);
    }
    fn unlock(c: *Conn) void {
        c.mutex.unlock(c.io);
    }

    // -- queries/commands from the engine (any thread) -----------------

    pub fn nameIs(c: *Conn, name: []const u8) bool {
        c.lock();
        defer c.unlock();
        return std.mem.eql(u8, c.name, name);
    }

    pub fn copyName(c: *Conn, buf: []u8) []const u8 {
        c.lock();
        defer c.unlock();
        const n = @min(buf.len, c.name.len);
        @memcpy(buf[0..n], c.name[0..n]);
        return buf[0..n];
    }

    pub fn rename(c: *Conn, name: []const u8) !void {
        const n = try c.alloc.dupe(u8, name);
        c.lock();
        defer c.unlock();
        c.alloc.free(c.name);
        c.name = n;
    }

    pub fn setProfile(c: *Conn, p: Profile) !void {
        const np = try p.clone(c.alloc);
        c.lock();
        defer c.unlock();
        c.profile.deinit(c.alloc);
        c.profile = np;
    }

    pub fn slug(c: *Conn, buf: []u8) []const u8 {
        c.lock();
        defer c.unlock();
        return profile_mod.hostSlug(c.profile.host, c.profile.instance, buf) catch "";
    }

    /// Whether this connection holds (or is about to bind) its tunnel
    /// socket: anything but parked in `failed` with no tunnel.
    pub fn holdsSocket(c: *Conn) bool {
        c.lock();
        defer c.unlock();
        if (c.finished) return false;
        return c.state != .failed or c.tunnel_pid != null or c.cmd_connect != null;
    }

    pub fn isConnected(c: *Conn) bool {
        c.lock();
        defer c.unlock();
        return c.state == .connected and c.tunnel_pid != null and c.cmd_connect == null;
    }

    pub fn hasTunnel(c: *Conn) bool {
        c.lock();
        defer c.unlock();
        return c.tunnel_pid != null;
    }

    pub fn isFinished(c: *Conn) bool {
        c.lock();
        defer c.unlock();
        return c.finished;
    }

    pub fn stateName(c: *Conn, buf: []u8) []const u8 {
        c.lock();
        defer c.unlock();
        const s = @tagName(c.state);
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }

    pub fn requestConnect(c: *Conn, why: []const u8) void {
        c.lock();
        c.cmd_connect = why;
        c.unlock();
        c.wake.wake();
    }

    pub fn requestDisconnect(c: *Conn, why: []const u8) void {
        c.lock();
        c.cmd_disconnect = why;
        c.unlock();
        c.wake.wake();
    }

    pub fn requestResume(c: *Conn) void {
        c.lock();
        c.cmd_resume = true;
        c.unlock();
        c.wake.wake();
    }

    pub fn requestQuit(c: *Conn) void {
        c.lock();
        c.cmd_quit = true;
        c.unlock();
        c.wake.wake();
    }

    /// Caller holds the lock.
    fn statusLocked(c: *Conn, a: Allocator) !api.Status {
        var joined: std.ArrayList(u8) = .empty;
        for (0..c.tail_len) |i| {
            if (i > 0) try joined.append(a, '\n');
            try joined.appendSlice(a, c.tail[i].?);
        }
        return .{
            .name = try a.dupe(u8, c.name),
            .state = c.state,
            .msg = try a.dupe(u8, c.msg.items),
            .stderr = joined.items,
            .step = c.step,
            .push_sent = c.push_sent,
            .push_total = c.push_total,
            .retry_delay_s = c.retry_delay_s,
            .retry_at_ms = c.retry_at_ms,
            .socket_path = if (c.state == .connected) (if (c.socket_path) |s| try a.dupe(u8, s) else null) else null,
            .remote_socket = if (c.remote_socket) |s| try a.dupe(u8, s) else null,
            .host = try a.dupe(u8, c.profile.host),
            .instance = try a.dupe(u8, c.profile.instanceOrDefault()),
            .ssh_port = c.profile.ssh_port,
            .had_connection = c.had_connection,
            .tunnel_pid = c.tunnel_pid,
        };
    }

    pub fn statusCopy(c: *Conn, a: Allocator) !api.Status {
        c.lock();
        defer c.unlock();
        return c.statusLocked(a);
    }

    // -- supervisor-thread helpers -------------------------------------

    fn log(c: *Conn, level: Log.Level, data: []const Log.Field, comptime fmt: []const u8, args: anytype) void {
        var nb: [128]u8 = undefined;
        const name = c.copyName(&nb);
        c.engine.log.atf(level, name, data, fmt, args);
    }

    fn publish(c: *Conn) void {
        if (c.disconnecting) return;
        var arena = std.heap.ArenaAllocator.init(c.alloc);
        defer arena.deinit();
        const s = blk: {
            c.lock();
            defer c.unlock();
            break :blk c.statusLocked(arena.allocator()) catch return;
        };
        c.engine.emit(&.{ .status = &s });
    }

    fn pushTail(c: *Conn, line: []const u8) void {
        const l = c.alloc.dupe(u8, line) catch return;
        c.lock();
        defer c.unlock();
        if (c.tail_len == TAIL) {
            c.alloc.free(c.tail[0].?);
            for (0..TAIL - 1) |i| c.tail[i] = c.tail[i + 1];
            c.tail[TAIL - 1] = l;
        } else {
            c.tail[c.tail_len] = l;
            c.tail_len += 1;
        }
    }

    fn clearTail(c: *Conn) void {
        c.lock();
        defer c.unlock();
        for (0..c.tail_len) |i| {
            c.alloc.free(c.tail[i].?);
            c.tail[i] = null;
        }
        c.tail_len = 0;
    }

    const StatusUpdate = struct {
        state: api.State,
        msg: []const u8 = "",
        step: api.Step,
        push_sent: u64 = 0,
        push_total: u64 = 0,
        retry_delay_s: u32 = 0,
        retry_at_ms: i64 = 0,
    };

    /// main.js setConnStatus: every state change is a log line; same-state
    /// updates (deploy progress, retry countdowns) are logged by their
    /// producers.
    fn setStatus(c: *Conn, u: StatusUpdate) void {
        const prev = blk: {
            c.lock();
            defer c.unlock();
            const prev = c.state;
            c.state = u.state;
            c.msg.clearRetainingCapacity();
            c.msg.appendSlice(c.alloc, u.msg) catch {};
            c.step = u.step;
            c.push_sent = u.push_sent;
            c.push_total = u.push_total;
            c.retry_delay_s = u.retry_delay_s;
            c.retry_at_ms = u.retry_at_ms;
            break :blk prev;
        };
        if (prev != u.state) {
            const level: Log.Level = switch (u.state) {
                .failed => .@"error",
                .retry => .warn,
                else => .info,
            };
            const data: []const Log.Field = if (u.msg.len > 0) &.{.{ .key = "msg", .value = .{ .str = u.msg } }} else &.{};
            c.log(level, data, "state {s} → {s}", .{ @tagName(prev), @tagName(u.state) });
        }
        c.publish();
    }

    const Cmd = union(enum) {
        none,
        connect: []const u8,
        exit: []const u8,
        resume_,
    };

    /// Take the most important pending command. Drains the wake pipe.
    fn takeCommand(c: *Conn, accept_resume: bool) Cmd {
        proc.drain(c.wake.r);
        c.lock();
        defer c.unlock();
        if (c.cmd_quit) return .{ .exit = "quit" };
        if (c.cmd_disconnect) |w| return .{ .exit = w };
        if (c.cmd_connect) |w| {
            c.cmd_connect = null;
            return .{ .connect = w };
        }
        if (c.cmd_resume) {
            c.cmd_resume = false;
            if (accept_resume) return .resume_;
        }
        return .none;
    }

    /// Is a stopping command (connect/disconnect/quit) pending? (No drain.)
    fn stopPending(c: *Conn) ?[]const u8 {
        c.lock();
        defer c.unlock();
        if (c.cmd_quit) return "quit";
        if (c.cmd_disconnect) |w| return w;
        if (c.cmd_connect) |w| return w;
        return null;
    }

    fn waitWake(c: *Conn, timeout_ms: i32) void {
        var fds = [_]posix.pollfd{.{ .fd = c.wake.r, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&fds, timeout_ms) catch {};
    }

    fn timing(c: *Conn) api.Timing {
        return c.engine.timing;
    }

    // -- the thread ----------------------------------------------------

    const Next = union(enum) {
        /// parked (failed / idle): wait for a command
        wait,
        /// connectConn: a fresh manual connect cycle
        cycle: []const u8,
        /// startTunnel: one attempt (deploy + tunnel + probe loop)
        attempt,
        /// scheduleRetry with main.js's exitCode (null = undefined)
        retry: ?proc.Exit,
        /// a command interrupted the current step: act on it
        command,
        exit,
    };

    fn threadMain(c: *Conn) void {
        blockSigpipe();
        var next: Next = .wait;
        var pw: Engine.PasswordBuf = .{};
        defer pw.wipe();
        var have_pw = false;
        while (true) {
            next = switch (next) {
                .wait => c.waitCommand(),
                .command => c.commandNext(),
                .cycle => |why| blk: {
                    c.connectConn(why, &pw);
                    have_pw = true;
                    break :blk .attempt;
                },
                .attempt => blk: {
                    if (!have_pw) c.engine.lookupPassword(c.profileCopyNoAlloc(), &pw);
                    have_pw = false;
                    break :blk c.attempt(&pw);
                },
                .retry => |code| c.scheduleRetry(code),
                .exit => break,
            };
        }
        c.lock();
        const quit = c.cmd_quit;
        c.unlock();
        if (!quit) {
            var nb: [128]u8 = undefined;
            const name = c.copyName(&nb);
            c.engine.emit(&.{ .removed = name });
        }
        // Last: once set, the engine may join and free this connection
        // (under its lock — so no callback may run after this).
        c.lock();
        c.finished = true;
        c.unlock();
    }

    fn profileCopyNoAlloc(c: *Conn) Profile {
        // For the password lookup only (id + name); borrowed under no lock
        // is unsafe, so copy into fixed buffers.
        const S = struct {
            threadlocal var id_buf: [64]u8 = undefined;
            threadlocal var name_buf: [256]u8 = undefined;
        };
        c.lock();
        defer c.unlock();
        const idn = @min(c.profile.id.len, S.id_buf.len);
        @memcpy(S.id_buf[0..idn], c.profile.id[0..idn]);
        const nn = @min(c.profile.name.len, S.name_buf.len);
        @memcpy(S.name_buf[0..nn], c.profile.name[0..nn]);
        return .{ .id = S.id_buf[0..idn], .name = S.name_buf[0..nn] };
    }

    fn waitCommand(c: *Conn) Next {
        while (true) {
            switch (c.takeCommand(false)) {
                .connect => |why| return .{ .cycle = why },
                .exit => |why| {
                    c.disconnecting = true;
                    _ = why;
                    return .exit;
                },
                .none, .resume_ => c.waitWake(-1),
            }
        }
    }

    fn commandNext(c: *Conn) Next {
        switch (c.takeCommand(false)) {
            .connect => |why| return .{ .cycle = why },
            .exit => {
                c.disconnecting = true;
                return .exit;
            },
            .none, .resume_ => return .wait,
        }
    }

    /// main.js connectConn (the parts after stopTunnel).
    fn connectConn(c: *Conn, why: []const u8, pw: *Engine.PasswordBuf) void {
        c.retry_delay_ms = 0;
        {
            c.lock();
            c.had_connection = false; // a fresh manual attempt parks on failure, no retry loop
            c.unlock();
        }
        c.engine.lookupPassword(c.profileCopyNoAlloc(), pw);
        var arena = std.heap.ArenaAllocator.init(c.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const p = blk: {
            c.lock();
            defer c.unlock();
            break :blk c.profile.clone(a) catch return;
        };
        const sock = c.localSocket(a, p) catch "(runtime dir too long for a socket path)";
        var fields: std.ArrayList(Log.Field) = .empty;
        fields.append(a, .{ .key = "host", .value = .{ .str = p.host } }) catch {};
        fields.append(a, .{ .key = "instance", .value = .{ .str = p.instanceOrDefault() } }) catch {};
        fields.append(a, .{ .key = "socket", .value = .{ .str = sock } }) catch {};
        if (p.ssh_port != 0) fields.append(a, .{ .key = "sshPort", .value = .{ .int = p.ssh_port } }) catch {};
        if (p.identity_file.len > 0) fields.append(a, .{ .key = "identityFile", .value = .{ .str = p.identity_file } }) catch {};
        if (p.extra_options.len > 0) fields.append(a, .{ .key = "extraOptions", .value = .{ .str = p.extra_options } }) catch {};
        // main.js logs whether a password is stored, not whether it could
        // be read (a locked keyring still means password auth).
        const stored = pw.has or pw.unavailable != null or c.engine.passwordStored(p.id);
        fields.append(a, .{ .key = "auth", .value = .{ .str = if (stored) "password" else "key" } }) catch {};
        c.log(.info, fields.items, "{s} requested", .{why});
    }

    fn localSocket(c: *Conn, a: Allocator, p: Profile) ![]u8 {
        var buf: [600]u8 = undefined;
        const s = try profile_mod.hostSlug(p.host, p.instance, &buf);
        return paths.socketPath(a, c.engine.paths.runtime_dir, s);
    }

    /// The status line for a failed/interrupted attempt (main.js failureMsg,
    /// minus the macOS Local Network hint).
    fn failureMsg(buf: []u8, exit: ?proc.Exit) []const u8 {
        const e = exit orelse return "connection failed";
        return std.fmt.bufPrint(buf, "ssh exited ({f})", .{e}) catch "connection failed";
    }

    fn exitFields(exit: proc.Exit, out: *[2]Log.Field) []const Log.Field {
        out[0] = .{ .key = "code", .value = switch (exit) {
            .code => |n| .{ .int = n },
            else => .null,
        } };
        out[1] = .{ .key = "signal", .value = switch (exit) {
            .signal => |s| .{ .str = proc.signalName(s) },
            else => .null,
        } };
        return out;
    }

    fn exitCodeValue(exit: proc.Exit) Log.Value {
        return switch (exit) {
            .code => |n| .{ .int = n },
            .signal => |s| .{ .str = proc.signalName(s) },
            .unknown => .null,
        };
    }

    /// main.js onTunnelDown.
    fn onTunnelDown(c: *Conn, exit: ?proc.Exit) Next {
        if (c.had_connection) return .{ .retry = exit };
        var buf: [64]u8 = undefined;
        c.setStatus(.{ .state = .failed, .msg = failureMsg(&buf, exit), .step = .idle });
        return .wait;
    }

    /// main.js scheduleRetry + the retry timer firing.
    fn scheduleRetry(c: *Conn, exit: ?proc.Exit) Next {
        const t = c.timing();
        c.retry_delay_ms = @min(@max(c.retry_delay_ms *| 2, t.retry_min_ms), t.retry_max_ms);
        const delay = c.retry_delay_ms;
        var data: [1]Log.Field = undefined;
        const fields: []const Log.Field = if (exit) |e| blk: {
            data[0] = .{ .key = "exitCode", .value = exitCodeValue(e) };
            break :blk data[0..1];
        } else &.{};
        var nbuf: [32]u8 = undefined;
        c.log(.warn, fields, "interrupted — retry in {s}s", .{fmtSeconds(&nbuf, delay)});
        var mbuf: [64]u8 = undefined;
        const deadline = util.monoMs(c.io) + delay;
        c.setStatus(.{
            .state = .retry,
            .msg = failureMsg(&mbuf, exit),
            .step = .waiting_retry,
            .retry_delay_s = @intCast((delay + 500) / 1000),
            .retry_at_ms = deadline,
        });
        while (true) {
            switch (c.takeCommand(false)) {
                .connect => |why| {
                    c.log(.info, &.{}, "pending retry cancelled ({s})", .{why});
                    return .{ .cycle = why };
                },
                .exit => |why| {
                    c.disconnecting = true;
                    c.log(.info, &.{}, "pending retry cancelled ({s})", .{why});
                    return .exit;
                },
                .none, .resume_ => {},
            }
            const left = deadline - util.monoMs(c.io);
            if (left <= 0) break;
            c.waitWake(@intCast(@min(left, 60_000)));
        }
        c.log(.info, &.{}, "retrying", .{});
        return .attempt;
    }

    fn fmtSeconds(buf: []u8, ms: u32) []const u8 {
        if (ms % 1000 == 0) return std.fmt.bufPrint(buf, "{d}", .{ms / 1000}) catch "?";
        return std.fmt.bufPrint(buf, "{d}", .{@as(f64, @floatFromInt(ms)) / 1000.0}) catch "?";
    }

    // -- one attempt (startTunnel → runDeploy → spawnTunnel → probeLoop) --

    const Attempt = struct {
        c: *Conn,
        arena: Allocator,
        profile: Profile,
        has_password: bool,
        env: *std.process.Environ.Map,
        started_ms: i64,
        stop_why: ?[]const u8 = null,
        command: []const u8 = "",
    };

    fn attempt(c: *Conn, pw: *Engine.PasswordBuf) Next {
        c.clearTail();
        var arena_state = std.heap.ArenaAllocator.init(c.alloc);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const p = blk: {
            c.lock();
            defer c.unlock();
            break :blk c.profile.clone(a) catch {
                pw.wipe();
                return .wait;
            };
        };

        if (pw.unavailable) |why| {
            // Keyring refused. Retrying won't help — park in failed with no
            // timer and let the user re-enter the password.
            pw.wipe();
            c.pushTail(why);
            c.log(.@"error", &.{.{ .key = "error", .value = .{ .str = why } }}, "saved password could not be decrypted", .{});
            c.setStatus(.{ .state = .failed, .msg = "saved password could not be decrypted — edit the profile and re-enter it", .step = .idle });
            return .wait;
        }
        if (p.instance.len > 0 and !profile_mod.validInstance(p.instance)) {
            pw.wipe();
            c.pushTail(profile_mod.INSTANCE_ERROR);
            c.setStatus(.{ .state = .failed, .msg = "invalid instance name in profile", .step = .idle });
            return .wait;
        }
        if (!profile_mod.validPort(p.ssh_port)) {
            pw.wipe();
            c.pushTail(profile_mod.PORT_ERROR);
            c.log(.@"error", &.{.{ .key = "sshPort", .value = .{ .int = p.ssh_port } }}, "invalid SSH port in profile", .{});
            c.setStatus(.{ .state = .failed, .msg = "invalid SSH port in profile — edit the profile", .step = .idle });
            return .wait;
        }
        if (c.localSocket(a, p)) |_| {} else |e| {
            // No socket path can be built (XDG_RUNTIME_DIR too long): every
            // attempt would fail the same way, so park with the reason.
            pw.wipe();
            var eb: [512]u8 = undefined;
            const why = std.fmt.bufPrint(&eb, "cannot build the tunnel socket path under {s} ({s}): a unix socket path is limited to 107 bytes", .{ util.clipChars(c.engine.paths.runtime_dir, 300), @errorName(e) }) catch "runtime directory too long for a socket path";
            c.pushTail(why);
            c.log(.@"error", &.{.{ .key = "error", .value = .{ .str = why } }}, "no tunnel socket path", .{});
            c.setStatus(.{ .state = .failed, .msg = "the runtime directory is too long for a socket path", .step = .idle });
            return .wait;
        }

        var mbuf: [600]u8 = undefined;
        c.setStatus(.{ .state = .connecting, .msg = std.fmt.bufPrint(&mbuf, "ssh {s}", .{util.clipChars(p.host, 500)}) catch "ssh", .step = .probing });

        var env = ssh.childEnv(c.alloc, &c.engine.env, c.engine.askpass_path, pw.slice()) catch {
            pw.wipe();
            return c.onTunnelDown(null);
        };
        const has_password = pw.has;
        pw.wipe();
        defer ssh.wipe(&env);

        var at: Attempt = .{ .c = c, .arena = a, .profile = p, .has_password = has_password, .env = &env, .started_ms = util.monoMs(c.io) };
        c.last_step.clearRetainingCapacity();
        const outcome = deploy.deploy(a, c.io, .{
            .ctx = &at,
            .run = runnerRun,
            .status = runnerStatus,
            .stderr = runnerStderr,
            .isLive = runnerIsLive,
        }, .{ .payload_dir = c.engine.paths.payload_dir, .instance = p.instanceOrDefault() }) catch {
            return c.onTunnelDown(null);
        };
        const ms = util.monoMs(c.io) - at.started_ms;
        switch (outcome) {
            .cancelled => return .command,
            .failed => |msg| {
                c.log(.@"error", &.{
                    .{ .key = "ms", .value = .{ .int = ms } },
                    .{ .key = "error", .value = .{ .str = msg } },
                }, "deploy failed", .{});
                c.pushTail(msg);
                return c.onTunnelDown(null);
            },
            .ok => |res| {
                c.log(.info, &.{
                    .{ .key = "ms", .value = .{ .int = ms } },
                    .{ .key = "platform", .value = .{ .str = res.platform } },
                    .{ .key = "payload", .value = .{ .str = res.payload_hash[0..12] } },
                    .{ .key = "socket", .value = .{ .str = res.socket } },
                    .{ .key = "pid", .value = if (res.pid) |pid| .{ .int = pid } else .null },
                }, "deploy done: server {s}", .{res.action});
                {
                    const rs = c.alloc.dupe(u8, res.socket) catch null;
                    c.lock();
                    if (c.remote_socket) |old| c.alloc.free(old);
                    c.remote_socket = rs;
                    c.unlock();
                }
                if (c.stopPending() != null) return .command;
                return c.runTunnel(&at, res.socket);
            },
        }
    }

    // deploy.Runner implementation
    fn runnerRun(ctx: *anyopaque, a: Allocator, command: []const u8, stdin_file: ?[]const u8) proc.RunError!proc.RunResult {
        const at: *Attempt = @ptrCast(@alignCast(ctx));
        const c = at.c;
        const argv = try ssh.commandArgv(a, c.engine.ssh_path, at.profile, at.has_password, command);
        at.command = command;
        const res = proc.run(a, c.io, argv, at.env, .{
            .ctx = at,
            .wake_fd = c.wake.r,
            .shouldCancel = runnerShouldCancel,
            .stderrLine = runnerStderr,
            .progress = runnerProgress,
            .spawned = struct {
                fn f(cx: *anyopaque, pid: posix.pid_t) void {
                    const at2: *Attempt = @ptrCast(@alignCast(cx));
                    at2.c.lock();
                    at2.c.deploy_pid = pid;
                    at2.c.unlock();
                    at2.c.log(.debug, &.{
                        .{ .key = "pid", .value = .{ .int = pid } },
                        .{ .key = "command", .value = .{ .str = util.clipChars(at2.command, 120) } },
                    }, "deploy step: ssh", .{});
                }
            }.f,
        }, .{ .stdin_file = stdin_file }) catch |e| {
            c.lock();
            c.deploy_pid = null;
            c.unlock();
            return e;
        };
        c.lock();
        c.deploy_pid = null;
        c.unlock();
        var ef: [2]Log.Field = undefined;
        const fields = exitFields(res.exit, &ef);
        c.log(.debug, &.{ .{ .key = "pid", .value = .{ .int = res.pid } }, fields[0], fields[1] }, "deploy step: ssh exited", .{});
        return res;
    }

    fn runnerShouldCancel(ctx: *anyopaque) bool {
        const at: *Attempt = @ptrCast(@alignCast(ctx));
        const c = at.c;
        proc.drain(c.wake.r);
        const why = c.stopPending() orelse {
            // resume only concerns live tunnels
            c.lock();
            c.cmd_resume = false;
            c.unlock();
            return false;
        };
        c.lock();
        const pid = c.deploy_pid;
        c.unlock();
        c.log(.info, &.{.{ .key = "pid", .value = if (pid) |x| .{ .int = x } else .null }}, "deploy step killed ({s})", .{why});
        at.stop_why = why;
        return true;
    }

    fn runnerStatus(ctx: *anyopaque, step: deploy.Step, msg: []const u8, sent: u64, total: u64) void {
        const at: *Attempt = @ptrCast(@alignCast(ctx));
        const c = at.c;
        if (c.stopPending() != null) return;
        // progress messages differ only by a percentage; log each step once
        const key = stepKey(msg);
        if (!std.mem.eql(u8, key, c.last_step.items)) {
            c.last_step.clearRetainingCapacity();
            c.last_step.appendSlice(c.alloc, key) catch {};
            c.log(.info, &.{}, "deploy: {s}", .{msg});
        }
        c.setStatus(.{ .state = .connecting, .msg = msg, .step = switch (step) {
            .probing => .probing,
            .pushing => .pushing,
            .starting => .starting,
        }, .push_sent = sent, .push_total = total });
    }

    /// `msg.replace(/\s*\d+%.*$/, '')`
    fn stepKey(msg: []const u8) []const u8 {
        var i: usize = 0;
        while (i < msg.len) : (i += 1) {
            if (!std.ascii.isDigit(msg[i])) continue;
            var j = i;
            while (j < msg.len and std.ascii.isDigit(msg[j])) j += 1;
            if (j < msg.len and msg[j] == '%') {
                var k = i;
                while (k > 0 and std.ascii.isWhitespace(msg[k - 1])) k -= 1;
                return msg[0..k];
            }
            i = j;
        }
        return msg;
    }

    fn runnerProgress(ctx: *anyopaque, sent: u64, total: u64) void {
        const pct = sent * 100 / @max(total, 1);
        var buf: [96]u8 = undefined;
        const mb = @as(f64, @floatFromInt(total)) / 1024.0 / 1024.0;
        const msg = std.fmt.bufPrint(&buf, "pushing webmux… {d}% of {d:.1} MB", .{ pct, mb }) catch "pushing webmux…";
        runnerStatus(ctx, .pushing, msg, sent, total);
    }

    fn runnerStderr(ctx: *anyopaque, line: []const u8) void {
        const at: *Attempt = @ptrCast(@alignCast(ctx));
        at.c.log(.warn, &.{}, "ssh: {s}", .{line});
        at.c.pushTail(line);
    }

    fn runnerIsLive(ctx: *anyopaque) bool {
        const at: *Attempt = @ptrCast(@alignCast(ctx));
        return at.c.stopPending() == null;
    }

    // -- the tunnel + probe loop ---------------------------------------

    fn runTunnel(c: *Conn, at: *Attempt, remote_sock: []const u8) Next {
        const a = at.arena;
        const t = c.timing();
        const local = c.localSocket(a, at.profile) catch return c.onTunnelDown(null);
        util.makePath(c.io, c.engine.paths.runtime_dir, 0o700) catch {};
        // The password was looked up when this attempt began; if it was
        // cleared since (during the deploy steps), it must not reach the
        // tunnel: start the attempt over with a fresh lookup.
        if (at.has_password and c.engine.password != null and c.engine.password.?.has != null and !c.engine.passwordStored(at.profile.id)) {
            c.log(.info, &.{}, "saved password was cleared during the attempt — starting over without it", .{});
            return .attempt;
        }
        const argv = ssh.tunnelArgv(a, c.engine.ssh_path, at.profile, at.has_password, local, remote_sock) catch return c.onTunnelDown(null);
        var p = proc.spawn(c.io, argv, at.env, .{ .stdin = .ignore, .stdout = .ignore, .stderr = .pipe }) catch |e| {
            // spawn failure (no ssh binary)
            var buf: [128]u8 = undefined;
            const msg = proc.spawnErrorText(&buf, c.engine.ssh_path, e);
            c.log(.@"error", &.{.{ .key = "error", .value = .{ .str = msg } }}, "tunnel spawn error", .{});
            c.pushTail(msg);
            return c.onTunnelDown(null);
        };
        // The password was only needed for the spawn.
        ssh.zeroPassword(at.env);
        const spawned_at = util.monoMs(c.io);
        const cmd = ssh.joinForLog(a, argv) catch "";
        c.log(.info, &.{
            .{ .key = "pid", .value = .{ .int = p.pid } },
            .{ .key = "socket", .value = .{ .str = local } },
            .{ .key = "remoteSock", .value = .{ .str = remote_sock } },
            .{ .key = "cmd", .value = .{ .str = cmd } },
        }, "tunnel spawned", .{});
        {
            const sp = c.alloc.dupe(u8, local) catch null;
            c.lock();
            if (c.socket_path) |old| c.alloc.free(old);
            c.socket_path = sp;
            c.tunnel_pid = p.pid;
            c.step = .tunnel;
            c.unlock();
        }
        c.publish();

        var err_split: proc.LineSplitter = .{};
        const LineCtx = struct {
            c: *Conn,
            fn line(self: *const @This(), l: []const u8) void {
                self.c.log(.warn, &.{}, "ssh: {s}", .{l});
                self.c.pushTail(l);
            }
        };
        const lctx: LineCtx = .{ .c = c };
        var chunk: [4096]u8 = undefined;

        var misses: u32 = 0;
        var answered = false;
        const started = util.monoMs(c.io);
        var next_probe: i64 = started;
        var killed = false;

        const result: Next = loop: while (true) {
            const now = util.monoMs(c.io);
            var timeout: i32 = if (killed) -1 else @intCast(std.math.clamp(next_probe - now, 0, 60_000));
            if (p.exit_fd < 0 and (timeout < 0 or timeout > 200)) timeout = 200;
            var fds = [_]posix.pollfd{
                .{ .fd = c.wake.r, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = p.stderrFd() orelse -1, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = p.exit_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, timeout) catch {};

            // commands
            if (fds[0].revents != 0) {
                proc.drain(c.wake.r);
                if (c.stopPending()) |why| {
                    // stopTunnel: this cycle is superseded (connect/reconnect)
                    // or over (disconnect/quit); commandNext acts on it.
                    c.log(.info, &.{.{ .key = "pid", .value = .{ .int = p.pid } }}, "tunnel killed ({s})", .{why});
                    const exit = p.terminate(@intCast(t.kill_grace_ms));
                    var ef: [2]Log.Field = undefined;
                    const f = exitFields(exit, &ef);
                    c.log(.info, &.{
                        .{ .key = "pid", .value = .{ .int = p.pid } },                               f[0], f[1],
                        .{ .key = "uptimeMs", .value = .{ .int = util.monoMs(c.io) - spawned_at } },
                    }, "tunnel exited (superseded)", .{});
                    break :loop .command;
                }
                if (c.takeResume() and !killed) {
                    // Lid-open: the pre-sleep tunnel is dead but doesn't know
                    // it yet; kill it so reconnection starts now. The exit
                    // path decides what follows.
                    c.log(.info, &.{.{ .key = "pid", .value = .{ .int = p.pid } }}, "killing pre-sleep tunnel to reconnect now", .{});
                    c.retry_delay_ms = 0;
                    killed = true;
                    p.signal(.TERM);
                }
            }

            // ssh stderr
            if (fds[1].revents != 0) if (p.stderrFd()) |fd| {
                while (proc.readSome(fd, &chunk)) |got| {
                    if (got == 0) {
                        err_split.flush(&lctx, LineCtx.line);
                        _ = std.c.close(fd);
                        p.child.stderr = null;
                        break;
                    }
                    err_split.feed(chunk[0..got], &lctx, LineCtx.line);
                }
            };

            // exit
            const gone = if (p.exit_fd >= 0) fds[2].revents != 0 else p.exited(0) or p.stderrFd() == null;
            if (gone) {
                if (p.stderrFd()) |fd| while (proc.readSome(fd, &chunk)) |got| {
                    if (got == 0) break;
                    err_split.feed(chunk[0..got], &lctx, LineCtx.line);
                };
                err_split.flush(&lctx, LineCtx.line);
                const exit = p.wait();
                var ef: [2]Log.Field = undefined;
                const f = exitFields(exit, &ef);
                c.log(.warn, &.{
                    .{ .key = "pid", .value = .{ .int = p.pid } },                               f[0], f[1],
                    .{ .key = "uptimeMs", .value = .{ .int = util.monoMs(c.io) - spawned_at } },
                }, "tunnel exited", .{});
                break :loop c.onTunnelDown(exit);
            }

            // probe
            if (!killed and util.monoMs(c.io) >= next_probe) {
                var why: []const u8 = "";
                const ok = c.engine.probe.func(c.engine.probe.ctx, local, t.probe_timeout_ms, &why);
                const after = util.monoMs(c.io);
                if (ok) {
                    if (!answered) {
                        answered = true;
                        c.log(.info, &.{.{ .key = "afterMs", .value = .{ .int = after - started } }}, "probe: server answered through the tunnel", .{});
                    } else if (misses > 0) {
                        c.log(.info, &.{.{ .key = "misses", .value = .{ .int = misses } }}, "probe: server answering again", .{});
                    }
                    misses = 0;
                    c.onServerUp();
                    next_probe = after + t.probe_interval_ms;
                } else {
                    const state = blk: {
                        c.lock();
                        defer c.unlock();
                        break :blk c.state;
                    };
                    if (state != .connected) {
                        // Not up yet. `webmux-host start` just verified the
                        // socket answers, so a forward that never reaches it
                        // is broken.
                        if (after - started > t.probe_first_answer_ms) {
                            c.giveUp(&p, misses, started, "server did not answer through the tunnel");
                            killed = true;
                        } else next_probe = after + t.probe_retry_ms;
                    } else {
                        misses += 1;
                        c.log(.warn, &.{.{ .key = "error", .value = .{ .str = if (why.len > 0) why else "no answer" } }}, "probe missed ({d}/{d})", .{ misses, t.probe_misses });
                        if (misses >= t.probe_misses) {
                            c.giveUp(&p, misses, started, "server unreachable through the tunnel — reconnecting");
                            killed = true;
                        } else next_probe = after + t.probe_interval_ms;
                    }
                }
            }
            if (killed and !p.exited(0)) {
                // escalate if SIGTERM is ignored
                if (!p.exited(@intCast(t.kill_grace_ms))) p.signal(.KILL);
            }
        };
        // the tunnel is gone either way
        if (p.reaped == null) _ = p.terminate(@intCast(t.kill_grace_ms));
        util.unlinkPath(local);
        c.lock();
        c.tunnel_pid = null;
        c.unlock();
        return result;
    }

    fn takeResume(c: *Conn) bool {
        c.lock();
        defer c.unlock();
        const r = c.cmd_resume;
        c.cmd_resume = false;
        return r;
    }

    fn giveUp(c: *Conn, p: *proc.Proc, misses: u32, started: i64, why: []const u8) void {
        c.log(.@"error", &.{
            .{ .key = "misses", .value = .{ .int = misses } },
            .{ .key = "pid", .value = .{ .int = p.pid } },
            .{ .key = "afterMs", .value = .{ .int = util.monoMs(c.io) - started } },
        }, "probe: {s}", .{why});
        c.pushTail(why);
        c.retry_delay_ms = 0; // a link we declared dead should be retried at once
        p.signal(.TERM); // exit → onTunnelDown decides retry vs failed
    }

    /// main.js onServerUp (the conn half; loading/revealing the page is the
    /// shell's, on the `.connected` status event).
    fn onServerUp(c: *Conn) void {
        c.retry_delay_ms = 0; // healthy — next failure retries immediately
        const was = blk: {
            c.lock();
            defer c.unlock();
            c.had_connection = true; // from here on, a drop is an interruption → auto-retry
            break :blk c.state;
        };
        if (was != .connected) c.setStatus(.{ .state = .connected, .step = .tunnel });
    }
};
