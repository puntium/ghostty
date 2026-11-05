//! Connecting IS deploying: the port of electron/deploy.js + platforms.js.
//!
//!   1. probe   — one ssh round trip: uname, libc flavor, which payloads
//!                ~/.webmux/dist already holds
//!   2. payload — pick this host's platform payload from payload.json; if
//!                the host lacks that hash, stream the tarball up and
//!                extract it to ~/.webmux/dist/payload/<hash> (.tmp + mv)
//!   3. start   — `<payload>/webmux-host start --name <instance>`; the
//!                last JSON line of its stdout is the result, whose
//!                advert.socket is what the tunnel forwards to
//!
//! Remote scripts are byte-for-byte deploy.js's (POSIX sh, double quotes,
//! $HOME, wrapped in `exec sh -c '…'`).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const proc = @import("proc.zig");

pub const REMOTE_BASE = "$HOME/.webmux/dist";

pub const PROBE_SCRIPT = "echo \"@@os $(uname -s)\"; " ++
    "echo \"@@cpu $(uname -m)\"; " ++
    "(ls /lib/ld-musl-* || ls /usr/lib/ld-musl-* || ls /lib/*/ld-musl-*) >/dev/null 2>&1 && echo \"@@musl yes\" || echo \"@@musl no\"; " ++
    "for f in " ++ REMOTE_BASE ++ "/payload/*/PAYLOAD_HASH; do [ -f \"$f\" ] && echo \"@@payload $f\"; done; " ++
    "true";

pub fn shWrap(a: Allocator, script: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "exec sh -c '{s}'", .{script});
}

// ---------------------------------------------------------------------------
// Platforms (platforms.js)
// ---------------------------------------------------------------------------

pub const Platform = struct {
    key: []const u8,
    os: []const u8,
    cpus: []const []const u8,
    /// null = libc-agnostic (static musl build)
    musl: ?bool,
};

pub const PLATFORMS = [_]Platform{
    .{ .key = "linux-x64", .os = "Linux", .cpus = &.{ "x86_64", "amd64" }, .musl = null },
    .{ .key = "linux-arm64", .os = "Linux", .cpus = &.{ "aarch64", "arm64" }, .musl = null },
};

pub const Probe = struct {
    os: []const u8 = "",
    cpu: []const u8 = "",
    musl: bool = false,
    /// payload hashes present on the host (dir names)
    payload_hashes: std.ArrayList([]const u8) = .empty,

    pub fn has(p: *const Probe, hash: []const u8) bool {
        for (p.payload_hashes.items) |h| if (std.mem.eql(u8, h, hash)) return true;
        return false;
    }
};

pub fn resolvePlatform(probe: Probe) ?*const Platform {
    for (&PLATFORMS) |*p| {
        if (!std.mem.eql(u8, p.os, probe.os)) continue;
        var cpu_ok = false;
        for (p.cpus) |cpu| if (std.mem.eql(u8, cpu, probe.cpu)) {
            cpu_ok = true;
        };
        if (!cpu_ok) continue;
        if (p.musl) |m| if (m != probe.musl) continue;
        return p;
    }
    return null;
}

pub fn supportedSummary(w: *Io.Writer) !void {
    for (PLATFORMS, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s} {s}", .{ p.os, p.cpus[0] });
        if (p.musl) |m| try w.writeAll(if (m) " (musl)" else " (glibc)");
    }
}

/// Parse the probe's output; shell-profile noise is ignored. Strings point
/// into `out` (which must outlive the Probe) or are allocated with `a`.
pub fn parseProbe(a: Allocator, out: []const u8) !Probe {
    var probe: Probe = .{};
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\x0b\x0c");
        if (!std.mem.startsWith(u8, line, "@@")) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const tag = line[2..sp];
        if (tag.len == 0) continue;
        if (std.mem.indexOfAny(u8, tag, " \t") != null) continue;
        const value = line[sp + 1 ..];
        if (std.mem.eql(u8, tag, "os")) {
            probe.os = std.mem.trim(u8, value, " \t");
        } else if (std.mem.eql(u8, tag, "cpu")) {
            probe.cpu = std.mem.trim(u8, value, " \t");
        } else if (std.mem.eql(u8, tag, "musl")) {
            probe.musl = std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "yes");
        } else if (std.mem.eql(u8, tag, "payload")) {
            // path.basename(path.dirname(value))
            const dir = std.fs.path.dirname(value) orelse "";
            try probe.payload_hashes.append(a, std.fs.path.basename(dir));
        }
    }
    return probe;
}

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

/// `{ platforms: { <key>: { hash, bytes } }, builtAt }` as written by
/// deploy/build-payload.js. Returns the platform's hash, or null when the
/// manifest is missing/malformed or lacks a valid entry.
pub fn manifestHash(a: Allocator, io: Io, payload_dir: ?[]const u8, key: []const u8, out: *[64]u8) bool {
    const dir = payload_dir orelse return false;
    const path = std.fs.path.join(a, &.{ dir, "payload.json" }) catch return false;
    defer a.free(path);
    const bytes = (util.readFileAlloc(io, a, path, 1 << 20) catch return false) orelse return false;
    defer a.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return false;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return false;
    const plats = root.object.get("platforms") orelse return false;
    if (plats != .object) return false;
    const entry = plats.object.get(key) orelse return false;
    if (entry != .object) return false;
    const h = entry.object.get("hash") orelse return false;
    if (h != .string or !isHash(h.string)) return false;
    @memcpy(out, h.string[0..64]);
    return true;
}

/// All valid platform hashes in the manifest (restart-sessions prefers them).
pub fn manifestHashes(a: Allocator, io: Io, payload_dir: ?[]const u8) ![][64]u8 {
    var list: std.ArrayList([64]u8) = .empty;
    errdefer list.deinit(a);
    const dir = payload_dir orelse return list.toOwnedSlice(a);
    const path = try std.fs.path.join(a, &.{ dir, "payload.json" });
    defer a.free(path);
    const bytes = (util.readFileAlloc(io, a, path, 1 << 20) catch null) orelse return list.toOwnedSlice(a);
    defer a.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return list.toOwnedSlice(a);
    defer parsed.deinit();
    if (parsed.value != .object) return list.toOwnedSlice(a);
    const plats = parsed.value.object.get("platforms") orelse return list.toOwnedSlice(a);
    if (plats != .object) return list.toOwnedSlice(a);
    var it = plats.object.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr.*;
        if (e != .object) continue;
        const h = e.object.get("hash") orelse continue;
        if (h != .string or !isHash(h.string)) continue;
        try list.append(a, h.string[0..64].*);
    }
    return list.toOwnedSlice(a);
}

pub fn isHash(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

// ---------------------------------------------------------------------------
// The flow
// ---------------------------------------------------------------------------

pub const Step = enum { probing, pushing, starting };

/// What deploy needs from its caller (deploy.js `ctx`).
pub const Runner = struct {
    ctx: *anyopaque,
    /// Run one remote command over ssh (already parameterized for the
    /// profile), optionally streaming `stdin_file` with push progress.
    run: *const fn (ctx: *anyopaque, a: Allocator, command: []const u8, stdin_file: ?[]const u8) proc.RunError!proc.RunResult,
    /// Progress line for the connection UI (deploy.js ctx.status), plus the
    /// structured step and push progress.
    status: *const fn (ctx: *anyopaque, step: Step, msg: []const u8, sent: u64, total: u64) void,
    /// Diagnostic tail line.
    stderr: *const fn (ctx: *anyopaque, line: []const u8) void,
    /// false once this attempt is cancelled.
    isLive: *const fn (ctx: *anyopaque) bool,
};

pub const StartResult = struct {
    /// "reuse" | "started" (or whatever the starter said)
    action: []const u8,
    socket: []const u8,
    pid: ?i64,
    platform: []const u8,
    payload_hash: [64]u8,
};

pub const Outcome = union(enum) {
    ok: StartResult,
    /// error text (allocated with the deploy allocator)
    failed: []const u8,
    cancelled,
};

pub const Options = struct {
    payload_dir: ?[]const u8,
    instance: []const u8,
};

/// Run the whole flow. All allocations (result strings included) come
/// from `a`; use an arena.
pub fn deploy(a: Allocator, io: Io, r: Runner, opts: Options) !Outcome {
    r.status(r.ctx, .probing, "probing host…", 0, 0);
    const probe_cmd = try shWrap(a, PROBE_SCRIPT);
    const probe_out = switch (try runSsh(a, r, probe_cmd, null)) {
        .ok => |o| o,
        .failed => |f| return .{ .failed = f.msg },
        .cancelled => return .cancelled,
    };
    const probe = try parseProbe(a, probe_out);
    if (probe.os.len == 0 or probe.cpu.len == 0)
        return .{ .failed = "host probe failed — no uname output (unusual remote shell?)" };
    if (!r.isLive(r.ctx)) return .cancelled;

    const platform = resolvePlatform(probe) orelse {
        var aw: Io.Writer.Allocating = .init(a);
        try aw.writer.print("unsupported host platform '{s} {s}{s}' — supported targets: ", .{ probe.os, probe.cpu, if (probe.musl) " (musl)" else "" });
        supportedSummary(&aw.writer) catch return error.OutOfMemory;
        return .{ .failed = aw.written() };
    };
    var hash: [64]u8 = undefined;
    if (!manifestHash(a, io, opts.payload_dir, platform.key, &hash)) {
        return .{ .failed = try std.fmt.allocPrint(a, "this client build has no {s} payload — run `node deploy/build-payload.js` (needs host/dist/webmux-host-{s}) and restart the app", .{ platform.key, platform.key }) };
    }

    if (!probe.has(&hash)) {
        const tarball = try std.fs.path.join(a, &.{ opts.payload_dir.?, platform.key, "payload.tar.gz" });
        if (!util.fileExists(tarball)) return .{ .failed = try std.fmt.allocPrint(a, "payload tarball missing: {s}", .{tarball}) };
        const base = REMOTE_BASE ++ "/payload";
        const script = try std.fmt.allocPrint(a, "rm -rf {s}/.tmp-{s} && mkdir -p {s}/.tmp-{s} && tar xzf - -C {s}/.tmp-{s} && rm -rf {s}/{s} && mv {s}/.tmp-{s} {s}/{s}", .{
            base, &hash, base, &hash, base, &hash, base, &hash, base, &hash, base, &hash,
        });
        switch (try runSsh(a, r, try shWrap(a, script), tarball)) {
            .ok => {},
            .failed => |f| return .{ .failed = f.msg },
            .cancelled => return .cancelled,
        }
        if (!r.isLive(r.ctx)) return .cancelled;
    }

    r.status(r.ctx, .starting, "starting server…", 0, 0);
    const out = switch (try remoteStart(a, r, &hash, opts.instance)) {
        .ok => |res| res,
        .failed => |f| return .{ .failed = f },
        .cancelled => return .cancelled,
    };
    if (!r.isLive(r.ctx)) return .cancelled;
    var res = out;
    res.platform = platform.key;
    res.payload_hash = hash;
    return .{ .ok = res };
}

const SshOutcome = union(enum) {
    ok: []const u8,
    failed: struct { msg: []const u8, stdout: ?[]const u8 },
    cancelled,
};

/// deploy.js runSsh: resolves with stdout on exit 0, otherwise fails with
/// `ssh exited (<code|signal>)` (keeping stdout for the starter).
fn runSsh(a: Allocator, r: Runner, command: []const u8, stdin_file: ?[]const u8) !SshOutcome {
    const res = r.run(r.ctx, a, command, stdin_file) catch |e| switch (e) {
        error.Cancelled => return .cancelled,
        error.OutOfMemory => return error.OutOfMemory,
        error.InputUnreadable => return .{ .failed = .{ .msg = "payload tarball unreadable", .stdout = null } },
        error.FileNotFound, error.AccessDenied, error.SpawnFailed => {
            var buf: [128]u8 = undefined;
            return .{ .failed = .{ .msg = try a.dupe(u8, proc.spawnErrorText(&buf, "ssh", @errorCast(e))), .stdout = null } };
        },
    };
    if (res.exit.ok()) return .{ .ok = res.stdout };
    return .{ .failed = .{ .msg = try std.fmt.allocPrint(a, "ssh exited ({f})", .{res.exit}), .stdout = res.stdout } };
}

/// deploy.js lastJsonLine: the last stdout line that parses as JSON and
/// is an object — in JS terms, which includes arrays (an array result then
/// reads as `ok: undefined`).
pub fn lastJsonLine(a: Allocator, out: []const u8) ?std.json.Value {
    var it = std.mem.splitBackwardsScalar(u8, out, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or (t[0] != '{' and t[0] != '[')) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, t, .{}) catch continue;
        if (v == .object or v == .array) return v;
    }
    return null;
}

const StartOutcome = union(enum) { ok: StartResult, failed: []const u8, cancelled };

fn remoteStart(a: Allocator, r: Runner, hash: *const [64]u8, instance: []const u8) !StartOutcome {
    const cmd = try std.fmt.allocPrint(a, "exec {s}/payload/{s}/webmux-host start --name {s}", .{ REMOTE_BASE, hash, instance });
    var exit_msg: ?[]const u8 = null;
    const out: []const u8 = switch (try runSsh(a, r, try shWrap(a, cmd), null)) {
        .ok => |o| o,
        .cancelled => return .cancelled,
        .failed => |f| blk: {
            const so = f.stdout orelse return .{ .failed = try std.fmt.allocPrint(a, "server start failed: {s}", .{f.msg}) };
            exit_msg = f.msg;
            break :blk so;
        },
    };
    const result_v = lastJsonLine(a, out) orelse {
        if (exit_msg) |m| return .{ .failed = try std.fmt.allocPrint(a, "server start failed: {s}", .{m}) };
        return .{ .failed = "webmux-host start produced no result — see diagnostics" };
    };
    if (result_v == .array) return .{ .failed = "server start failed: undefined" };
    const result = result_v.object;
    const ok = if (result.get("ok")) |v| truthy(v) else false;
    if (!ok) {
        if (result.get("logTail")) |lt| if (lt == .string) {
            var it = std.mem.splitScalar(u8, lt.string, '\n');
            while (it.next()) |line| if (line.len > 0) r.stderr(r.ctx, line);
        };
        const e = if (result.get("error")) |v| try jsString(a, v) else "undefined";
        return .{ .failed = try std.fmt.allocPrint(a, "server start failed: {s}", .{e}) };
    }
    if (exit_msg) |m| return .{ .failed = try std.fmt.allocPrint(a, "server start failed: {s}", .{m}) };
    const advert = result.get("advert") orelse return .{ .failed = "webmux-host start returned no advert socket" };
    if (advert != .object) return .{ .failed = "webmux-host start returned no advert socket" };
    const sock = advert.object.get("socket") orelse return .{ .failed = "webmux-host start returned no advert socket" };
    if (sock != .string or sock.string.len == 0) return .{ .failed = "webmux-host start returned no advert socket" };
    const pid: ?i64 = if (advert.object.get("pid")) |p| (if (p == .integer) p.integer else null) else null;
    const action: []const u8 = if (result.get("action")) |v| (if (v == .string) v.string else "ready") else "ready";
    return .{ .ok = .{ .action = action, .socket = sock.string, .pid = pid, .platform = "", .payload_hash = undefined } };
}

fn truthy(v: std.json.Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0 and !std.math.isNan(f),
        .number_string => true,
        .string => |s| s.len > 0,
        .array, .object => true,
    };
}

/// `${value}` in a JS template literal, for the values a starter returns.
fn jsString(a: Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        else => std.json.Stringify.valueAlloc(a, v, .{}) catch "?",
    };
}

// ---------------------------------------------------------------------------
// Restart Sessions (main.js restartRemoteSessions)
// ---------------------------------------------------------------------------

/// The remote script, byte-for-byte main.js's. `instance` must already be
/// validated (shell-inert).
pub fn restartScript(a: Allocator, instance: []const u8, hashes: []const [64]u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    const w = &aw.writer;
    // regex-safe for pgrep -f
    var inst_re: std.ArrayList(u8) = .empty;
    defer inst_re.deinit(a);
    for (instance) |ch| {
        if (ch == '.') try inst_re.appendSlice(a, "[.]") else try inst_re.append(a, ch);
    }
    const host_re = "(ptyhost[.]js|webmux-host ptyhost)";
    write: {
        w.writeAll("r=no-deploy; for f in ") catch break :write;
        for (hashes) |h| w.print("$HOME/.webmux/dist/payload/{s}/webmux-host ", .{&h}) catch break :write;
        w.writeAll("$(ls -t $HOME/.webmux/dist/payload/*/webmux-host 2>/dev/null); do ") catch break :write;
        w.writeAll("[ -x \"$f\" ] || continue; ") catch break :write;
        w.print("if \"$f\" ptyhost --name {s} shutdown; then r=restarted; break; else r=not-running; fi; ", .{instance}) catch break :write;
        w.writeAll("done; ") catch break :write;
        w.writeAll("if [ \"$r\" != restarted ]; then ") catch break :write;
        w.writeAll("node=$(ls -t $HOME/.webmux/dist/node/*/bin/node 2>/dev/null | head -1); ") catch break :write;
        w.writeAll("ph=$(ls -t $HOME/.webmux/dist/payload/*/ptyhost.js 2>/dev/null | head -1); ") catch break :write;
        w.writeAll("if [ -n \"$node\" ] && [ -n \"$ph\" ]; then ") catch break :write;
        w.print("if \"$node\" \"$ph\" --name {s} shutdown; then r=restarted; else r=not-running; fi; ", .{instance}) catch break :write;
        w.writeAll("fi; fi; ") catch break :write;
        w.writeAll("if [ \"$r\" = not-running ]; then ") catch break :write;
        w.print("pids=$(pgrep -u \"$(id -un)\" -f \"{s} --name {s}$\" 2>/dev/null); ", .{ host_re, inst_re.items }) catch break :write;
        if (std.mem.eql(u8, instance, "default"))
            w.print("[ -z \"$pids\" ] && pids=$(pgrep -u \"$(id -un)\" -f \"{s}$\" 2>/dev/null); ", .{host_re}) catch break :write;
        w.writeAll("if [ -n \"$pids\" ]; then kill $pids && r=stale-killed; fi; fi; ") catch break :write;
        w.writeAll("echo \"@@result $r\"") catch break :write;
        return aw.toOwnedSlice();
    }
    return error.OutOfMemory;
}

pub const RestartResult = struct {
    ok: bool,
    /// user-facing message (ok) or error text
    msg: []const u8,
};

/// Interpret the restart run (main.js's result mapping).
pub fn restartOutcome(a: Allocator, stdout: []const u8, exit: proc.Exit, err_lines: []const []const u8) !RestartResult {
    var result: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@result ")) {
            const rest = line["@@result ".len..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r") orelse rest.len;
            if (end > 0) {
                result = rest[0..end];
                break;
            }
        }
    }
    if (result) |r| {
        if (std.mem.eql(u8, r, "restarted")) return .{ .ok = true, .msg = "sessions restarted — all shells were stopped, fresh ones start on demand" };
        if (std.mem.eql(u8, r, "stale-killed")) return .{ .ok = true, .msg = "an old session host did not answer the shutdown and was killed — fresh sessions start on demand" };
        if (std.mem.eql(u8, r, "not-running")) return .{ .ok = true, .msg = "no sessions were running — nothing to restart" };
        if (std.mem.eql(u8, r, "no-deploy")) return .{ .ok = false, .msg = "webmux has never been deployed to this host" };
    }
    var aw: Io.Writer.Allocating = .init(a);
    aw.writer.print("ssh exited ({f})", .{exit}) catch return error.OutOfMemory;
    if (err_lines.len > 0) {
        aw.writer.writeAll(" — ") catch return error.OutOfMemory;
        const tail = err_lines[err_lines.len - @min(2, err_lines.len) ..];
        for (tail, 0..) |l, i| {
            if (i > 0) aw.writer.writeAll("; ") catch return error.OutOfMemory;
            aw.writer.writeAll(l) catch return error.OutOfMemory;
        }
    }
    return .{ .ok = false, .msg = aw.written() };
}

test "probe parsing (canned musl/aarch64)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parseProbe(arena.allocator(), "Last login: yesterday\n@@os Linux\n@@cpu aarch64\n@@musl yes\n" ++
        "@@payload /home/u/.webmux/dist/payload/abc123/PAYLOAD_HASH\nnoise @@os Darwin\n");
    try std.testing.expectEqualStrings("Linux", p.os);
    try std.testing.expectEqualStrings("aarch64", p.cpu);
    try std.testing.expect(p.musl);
    try std.testing.expectEqual(@as(usize, 1), p.payload_hashes.items.len);
    try std.testing.expectEqualStrings("abc123", p.payload_hashes.items[0]);
    try std.testing.expectEqualStrings("linux-arm64", resolvePlatform(p).?.key);
    const none = try parseProbe(arena.allocator(), "just noise\n");
    try std.testing.expectEqualStrings("", none.os);
}

test "platform resolution" {
    const T = struct {
        fn key(os: []const u8, cpu: []const u8, musl: bool) ?[]const u8 {
            return if (resolvePlatform(.{ .os = os, .cpu = cpu, .musl = musl })) |p| p.key else null;
        }
    };
    try std.testing.expectEqualStrings("linux-x64", T.key("Linux", "x86_64", false).?);
    try std.testing.expectEqualStrings("linux-x64", T.key("Linux", "x86_64", true).?);
    try std.testing.expectEqualStrings("linux-x64", T.key("Linux", "amd64", false).?);
    try std.testing.expectEqualStrings("linux-arm64", T.key("Linux", "aarch64", true).?);
    try std.testing.expect(T.key("Linux", "armv7l", false) == null);
    try std.testing.expect(T.key("Darwin", "arm64", false) == null);
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try supportedSummary(&w);
    try std.testing.expectEqualStrings("Linux x86_64, Linux aarch64", w.buffered());
}

test "lastJsonLine skips noise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const o = lastJsonLine(arena.allocator(), "chatter\n[1, 2]\n{\"ok\":true,\"advert\":{\"socket\":\"/tmp/x.sock\"}}\n\"str\"\n").?;
    try std.testing.expect(o.object.get("ok").?.bool);
    try std.testing.expect(lastJsonLine(arena.allocator(), "nope\n42\n") == null);
    try std.testing.expect(lastJsonLine(arena.allocator(), "{\"ok\":true}\n[1]\n").? == .array);
}
