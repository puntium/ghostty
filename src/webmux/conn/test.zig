//! Package tests that need no network: a fake `ssh` (a shell script that
//! runs the "remote" command locally against a scratch remote $HOME, and
//! emulates `-N -L` by creating a marker file at the local socket path),
//! stand-in `webmux-host` payloads built into a scratch payload dir, and a
//! test liveness probe — the approach of electron/test/deploy-fake.js.
//! Every path lives under a fresh `/tmp/wm-*` root; HOME and the XDG
//! variables point into it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const conn = @import("../conn.zig");
const Log = @import("log.zig");
const profile_mod = @import("profile.zig");
const ssh = @import("ssh.zig");
const util = @import("util.zig");
const deploy = @import("deploy.zig");

const io = testing.io;

fn sleepMs(ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

const FAKE_SSH =
    \\#!/bin/sh
    \\# fake ssh: records argv, runs the remote command locally
    \\printf 'ARGV %s\n' "$*" >> "$FAKE_LOG"
    \\[ -n "$WEBMUX_SSH_PASSWORD" ] && printf 'PWENV set\n' >> "$FAKE_LOG"
    \\tunnel=0; fwd=""
    \\while [ $# -gt 0 ]; do
    \\  case "$1" in
    \\    -N) tunnel=1; shift;;
    \\    -o|-p|-i) shift 2;;
    \\    -L) fwd="$2"; shift 2;;
    \\    -*) shift;;
    \\    *) break;;
    \\  esac
    \\done
    \\host="$1"; shift
    \\if [ -n "$SSH_ASKPASS" ]; then
    \\  pw=$("$SSH_ASKPASS")
    \\  if [ "$pw" != "$FAKE_PASSWORD" ]; then echo "$host: Permission denied (publickey,password)." >&2; exit 255; fi
    \\fi
    \\case "$host" in
    \\  badhost) echo "ssh: Could not resolve hostname badhost: Name or service not known" >&2; exit 255;;
    \\esac
    \\R="$FAKE_REMOTE_HOME"
    \\if [ -f "$R/ssh-down" ]; then echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255; fi
    \\if [ $tunnel = 1 ]; then
    \\  sock="${fwd%%:*}"
    \\  if [ -n "$FAKE_SOCAT" ]; then exec "$FAKE_SOCAT" UNIX-LISTEN:"$sock",fork,unlink-early UNIX-CONNECT:"${fwd#*:}"; fi
    \\  : > "$sock"
    \\  echo "$fwd" > "$R/last-forward"
    \\  while :; do
    \\    if [ -f "$R/drop-tunnel" ]; then rm -f "$R/drop-tunnel"; echo "client_loop: send disconnect: Broken pipe" >&2; exit 255; fi
    \\    sleep 0.05
    \\  done
    \\fi
    \\if [ -f "$R/slow" ]; then sleep 30; fi
    \\export XDG_RUNTIME_DIR="$FAKE_REMOTE_RUN" TMPDIR="$FAKE_REMOTE_RUN"
    \\cd "$R" && HOME="$R" PATH="$FAKE_STUBS:$PATH" exec sh -c "echo 'motd: welcome'; $1"
    \\
;

/// Stand-in webmux-host: `start` prints chatter then the starter's result
/// object as the last JSON line (exit 1 on failure, like the real starter),
/// keeps an advert, and reports reuse vs (re)start; `ptyhost … shutdown`
/// succeeds once per "running" marker.
const FAKE_HOST =
    \\#!/bin/sh
    \\dir=$(cd "$(dirname "$0")" && pwd)
    \\echo "$0 $* cwd=$(pwd)" >> "$HOME/fake-host.log"
    \\case "$1" in
    \\start)
    \\  echo "starter chatter that is not JSON"
    \\  echo "[1, 2]"
    \\  if [ -f "$HOME/fail-start" ]; then
    \\    echo '{"ok":false,"error":"boom","logTail":"tail one\ntail two"}'
    \\    exit 1
    \\  fi
    \\  h=$(cat "$dir/PAYLOAD_HASH")
    \\  adv="$HOME/.webmux/$3.json"
    \\  action=started
    \\  if [ -f "$adv" ]; then
    \\    if grep -q "$h" "$adv"; then action=reuse; else echo "replacing $(cat "$adv")" >> "$HOME/fake-host.log"; fi
    \\  fi
    \\  mkdir -p "$HOME/.webmux"
    \\  echo "{\"payloadHash\":\"$h\"}" > "$adv"
    \\  echo "{\"ok\":true,\"action\":\"$action\",\"advert\":{\"socket\":\"/remote/$3.http.sock\",\"payloadHash\":\"$h\",\"protocol\":1,\"pid\":4242,\"startedAt\":0}}"
    \\  ;;
    \\ptyhost)
    \\  if [ -f "$HOME/ptyhost-running" ]; then rm -f "$HOME/ptyhost-running"; exit 0; fi
    \\  exit 1 ;;
    \\*) echo "fake webmux-host: unsupported $1" >&2; exit 2 ;;
    \\esac
    \\
;

const Fixture = struct {
    alloc: Allocator,
    root: []u8,
    env: std.process.Environ.Map,
    engine: ?conn.Engine = null,
    events: Events = .{},
    probe_count: std.atomic.Value(u32) = .init(0),
    password: ?[]const u8 = null,
    password_unavailable: bool = false,
    /// use a real HTTP probe over the unix socket (end-to-end test)
    real_probe: bool = false,

    const Events = struct {
        mutex: Io.Mutex = .init,
        removed: std.ArrayList([]u8) = .empty,
        restart: std.ArrayList(struct { ok: bool, msg: []u8 }) = .empty,
        states: std.ArrayList(conn.State) = .empty,
        settings: u32 = 0,
    };

    fn init(alloc: Allocator) !*Fixture {
        const f = try alloc.create(Fixture);
        errdefer alloc.destroy(f);
        var rnd: [4]u8 = undefined;
        io.random(&rnd);
        const root = try std.fmt.allocPrint(alloc, "/tmp/wm-ct-{x}", .{std.mem.readInt(u32, &rnd, .little)});
        f.* = .{ .alloc = alloc, .root = root, .env = .init(alloc) };
        for ([_][]const u8{ "home", "config", "state", "run", "remote", "rrun", "bin", "stubs", "payload" }) |d| {
            const p = try f.path(d);
            defer alloc.free(p);
            try util.makePath(io, p, 0o700);
        }
        // environment: only what the children need, all pointing into root
        var real = try testing.environ.createMap(alloc);
        defer real.deinit();
        try f.env.put("PATH", real.get("PATH") orelse "/run/current-system/sw/bin:/usr/bin:/bin");
        inline for (.{
            .{ "HOME", "home" },                  .{ "XDG_CONFIG_HOME", "config" },
            .{ "XDG_STATE_HOME", "state" },       .{ "XDG_RUNTIME_DIR", "run" },
            .{ "FAKE_REMOTE_HOME", "remote" },    .{ "FAKE_STUBS", "stubs" },
            .{ "WEBMUX_PAYLOAD_DIR", "payload" }, .{ "FAKE_LOG", "ssh.log" },
            .{ "FAKE_REMOTE_RUN", "rrun" },
        }) |kv| {
            const p = try f.path(kv[1]);
            defer alloc.free(p);
            try f.env.put(kv[0], p);
        }
        try f.env.put("FAKE_PASSWORD", "s3cr3t-pw");
        try f.writeScript("bin/ssh", FAKE_SSH);
        // never let the restart script's pgrep fallback see real processes
        try f.writeScript("stubs/pgrep", "#!/bin/sh\nexit 1\n");
        return f;
    }

    fn deinit(f: *Fixture) void {
        if (f.engine) |e| e.deinit();
        f.engine = null;
        for (f.events.removed.items) |r| f.alloc.free(r);
        f.events.removed.deinit(f.alloc);
        for (f.events.restart.items) |r| f.alloc.free(r.msg);
        f.events.restart.deinit(f.alloc);
        f.events.states.deinit(f.alloc);
        f.env.deinit();
        // rm -rf root
        Io.Dir.cwd().deleteTree(io, f.root) catch {};
        f.alloc.free(f.root);
        f.alloc.destroy(f);
    }

    fn path(f: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(f.alloc, &.{ f.root, rel });
    }

    fn writeScript(f: *Fixture, rel: []const u8, body: []const u8) !void {
        const p = try f.path(rel);
        defer f.alloc.free(p);
        try util.atomicWrite(io, p, body, 0o755);
    }

    /// `path` into a fixture-owned buffer (valid until the next call).
    fn pathTmp(f: *Fixture, rel: []const u8) ![]const u8 {
        const S = struct {
            threadlocal var buf: [1024]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "{s}/{s}", .{ f.root, rel });
    }

    fn writeFile(f: *Fixture, rel: []const u8, body: []const u8) !void {
        const p = try f.path(rel);
        defer f.alloc.free(p);
        if (std.fs.path.dirname(p)) |d| try util.makePath(io, d, 0o700);
        try util.atomicWrite(io, p, body, 0o644);
    }

    fn removeFile(f: *Fixture, rel: []const u8) void {
        const p = f.path(rel) catch return;
        defer f.alloc.free(p);
        util.unlinkPath(p);
    }

    fn exists(f: *Fixture, rel: []const u8) bool {
        const p = f.path(rel) catch return false;
        defer f.alloc.free(p);
        return util.fileExists(p);
    }

    fn read(f: *Fixture, rel: []const u8) ![]u8 {
        const p = try f.path(rel);
        defer f.alloc.free(p);
        return (try util.readFileAlloc(io, f.alloc, p, 16 << 20)) orelse try f.alloc.dupe(u8, "");
    }

    fn sh(f: *Fixture, script: []const u8) !void {
        const res = try std.process.run(f.alloc, io, .{ .argv = &.{ "/bin/sh", "-c", script }, .environ_map = &f.env });
        defer f.alloc.free(res.stdout);
        defer f.alloc.free(res.stderr);
        if (!(res.term == .exited and res.term.exited == 0)) {
            std.debug.print("sh failed: {s}\n{s}\n", .{ script, res.stderr });
            return error.ShellFailed;
        }
    }

    /// Build a payload for this machine's platform (plus an arm64 stand-in)
    /// stamped with `version`, and point payload.json at it.
    fn buildPayload(f: *Fixture, version: []const u8) ![64]u8 {
        var hash: [64]u8 = undefined;
        util.sha256Hex(&.{ FAKE_HOST, version }, &hash);
        var arm: [64]u8 = undefined;
        util.sha256Hex(&.{ FAKE_HOST, version, "arm64" }, &arm);
        const script = try std.fmt.allocPrint(f.alloc,
            \\set -e
            \\cd "{s}/payload"
            \\rm -rf linux-x64 && mkdir -p linux-x64/staging/shims
            \\cat > linux-x64/staging/webmux-host <<'EOF'
            \\{s}EOF
            \\chmod 755 linux-x64/staging/webmux-host
            \\printf '#!/bin/sh\nexit 0\n' > linux-x64/staging/shims/xdg-open && chmod 755 linux-x64/staging/shims/xdg-open
            \\echo {s} > linux-x64/staging/PAYLOAD_HASH
            \\tar czf linux-x64/payload.tar.gz -C linux-x64/staging .
            \\printf '{{"platforms":{{"linux-x64":{{"hash":"{s}","bytes":1}},"linux-arm64":{{"hash":"{s}","bytes":1}}}},"builtAt":"x"}}\n' > payload.json
        , .{ f.root, FAKE_HOST, &hash, &hash, &arm });
        defer f.alloc.free(script);
        try f.sh(script);
        return hash;
    }

    fn timing() conn.Timing {
        return .{
            .probe_timeout_ms = 200,
            .probe_interval_ms = 150,
            .probe_retry_ms = 40,
            .probe_misses = 3,
            .probe_first_answer_ms = 1200,
            .retry_min_ms = 300,
            .retry_max_ms = 1200,
            .restart_timeout_ms = 5000,
            .kill_grace_ms = 1000,
        };
    }

    fn start(f: *Fixture) !conn.Engine {
        const ssh_path = try f.path("bin/ssh");
        defer f.alloc.free(ssh_path);
        const e = try conn.Engine.init(f.alloc, io, .{
            .env = &f.env,
            .exe_dir = f.root,
            .ssh_path = ssh_path,
            .probe = .{ .ctx = f, .func = probeFn },
            .password = .{ .ctx = f, .func = passwordFn },
            .listener = .{ .ctx = f, .func = onEvent },
            .timing = timing(),
            .version = "test",
        });
        f.engine = e;
        return e;
    }

    fn stop(f: *Fixture) void {
        if (f.engine) |e| e.deinit();
        f.engine = null;
    }

    /// Test probe: "the server answers" iff ssh created the forward's local
    /// end and the remote server is not marked dead.
    fn probeFn(ctx: ?*anyopaque, socket_path: []const u8, timeout_ms: u32, why: *[]const u8) bool {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        _ = f.probe_count.fetchAdd(1, .monotonic);
        if (f.real_probe) return httpProbe(socket_path, timeout_ms);
        if (f.exists("remote/server-dead")) {
            why.* = "ConnectionRefused";
            return false;
        }
        return util.fileExists(socket_path);
    }

    fn passwordFn(ctx: ?*anyopaque, id: []const u8, name: []const u8, out: []u8) conn.PasswordLookup {
        _ = id;
        _ = name;
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        if (f.password_unavailable) return .{ .unavailable = "keyring locked" };
        const pw = f.password orelse return .none;
        @memcpy(out[0..pw.len], pw);
        return .{ .found = pw.len };
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const conn.Event) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        f.events.mutex.lockUncancelable(io);
        defer f.events.mutex.unlock(io);
        switch (ev.*) {
            .status => |s| {
                const st = f.events.states.items;
                if (st.len == 0 or st[st.len - 1] != s.state) f.events.states.append(f.alloc, s.state) catch {};
            },
            .removed => |n| f.events.removed.append(f.alloc, f.alloc.dupe(u8, n) catch return) catch {},
            .restart_done => |r| f.events.restart.append(f.alloc, .{ .ok = r.ok, .msg = f.alloc.dupe(u8, r.msg) catch return }) catch {},
            .settings => f.events.settings += 1,
        }
    }

    fn removedCount(f: *Fixture) usize {
        f.events.mutex.lockUncancelable(io);
        defer f.events.mutex.unlock(io);
        return f.events.removed.items.len;
    }

    fn sawState(f: *Fixture, s: conn.State) bool {
        f.events.mutex.lockUncancelable(io);
        defer f.events.mutex.unlock(io);
        return std.mem.indexOfScalar(conn.State, f.events.states.items, s) != null;
    }

    fn clearStates(f: *Fixture) void {
        f.events.mutex.lockUncancelable(io);
        defer f.events.mutex.unlock(io);
        f.events.states.clearRetainingCapacity();
    }

    fn addProfile(f: *Fixture, name: []const u8, host: []const u8, instance: []const u8) !void {
        const r = f.engine.?.saveProfile(.{ .name = name, .host = host, .instance = instance }, null);
        if (r) |msg| {
            std.debug.print("saveProfile: {s}\n", .{msg});
            return error.SaveFailed;
        }
    }

    fn stateOf(f: *Fixture, name: []const u8) ?conn.State {
        var s = (f.engine.?.status(f.alloc, name) catch return null) orelse return null;
        defer s.deinit();
        return s.state;
    }

    /// Poll until the connection reaches `want` (or time runs out).
    fn waitState(f: *Fixture, name: []const u8, want: conn.State, timeout_ms: i64) !void {
        const deadline = util.monoMs(io) + timeout_ms;
        while (util.monoMs(io) < deadline) {
            if (f.stateOf(name) == want) return;
            sleepMs(20);
        }
        var s = (try f.engine.?.status(f.alloc, name)) orelse {
            std.debug.print("waitState({s}): no connection\n", .{@tagName(want)});
            return error.Timeout;
        };
        defer s.deinit();
        std.debug.print("waitState: wanted {s}, have {s} msg={s} stderr={s}\n", .{ @tagName(want), @tagName(s.state), s.msg, s.stderr });
        try f.dumpLog();
        return error.Timeout;
    }

    fn waitFor(f: *Fixture, comptime pred: fn (*Fixture) bool, timeout_ms: i64) !void {
        const deadline = util.monoMs(io) + timeout_ms;
        while (util.monoMs(io) < deadline) {
            if (pred(f)) return;
            sleepMs(20);
        }
        try f.dumpLog();
        return error.Timeout;
    }

    fn logText(f: *Fixture) ![]u8 {
        return f.engine.?.log().text(f.alloc);
    }

    fn logHas(f: *Fixture, needle: []const u8) bool {
        const t = f.logText() catch return false;
        defer f.alloc.free(t);
        return std.mem.indexOf(u8, t, needle) != null;
    }

    fn waitLog(f: *Fixture, needle: []const u8, timeout_ms: i64) !void {
        const deadline = util.monoMs(io) + timeout_ms;
        while (util.monoMs(io) < deadline) {
            if (f.logHas(needle)) return;
            sleepMs(20);
        }
        std.debug.print("log never had: {s}\n", .{needle});
        try f.dumpLog();
        return error.Timeout;
    }

    fn waitLogCount(f: *Fixture, needle: []const u8, n: usize, timeout_ms: i64) !void {
        const deadline = util.monoMs(io) + timeout_ms;
        while (util.monoMs(io) < deadline) {
            const t = try f.logText();
            defer f.alloc.free(t);
            if (countOf(t, needle) >= n) return;
            sleepMs(20);
        }
        std.debug.print("log never had {d}x: {s}\n", .{ n, needle });
        try f.dumpLog();
        return error.Timeout;
    }

    fn dumpLog(f: *Fixture) !void {
        const t = try f.logText();
        defer f.alloc.free(t);
        std.debug.print("---- log ----\n{s}\n-------------\n", .{t});
    }

    fn sshLog(f: *Fixture) ![]u8 {
        return f.read("ssh.log");
    }
};

fn countOf(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

// ---------------------------------------------------------------------------
// Profiles, validation, store
// ---------------------------------------------------------------------------

test "profile validation (main.js profiles:save rules)" {
    const a = testing.allocator;
    var store = profile_mod.Store.init(a);
    defer store.deinit();
    var eb: [256]u8 = undefined;
    // instance check comes first, as in main.js
    try testing.expectEqualStrings(profile_mod.INSTANCE_ERROR, (try store.save(io, .{ .name = "", .host = "", .instance = "a b" }, null, &eb)).?);
    for ([_][]const u8{ "x;rm -rf ~", "$(id)", "a'b", "a\"b", "a/b", "ä" }) |bad|
        try testing.expectEqualStrings(profile_mod.INSTANCE_ERROR, (try store.save(io, .{ .name = "n", .host = "h", .instance = bad }, null, &eb)).?);
    try testing.expectEqualStrings("name and host are required", (try store.save(io, .{ .name = "  ", .host = "h" }, null, &eb)).?);
    try testing.expectEqualStrings("name and host are required", (try store.save(io, .{ .name = "n", .host = "" }, null, &eb)).?);
    try testing.expect((try store.save(io, .{ .name = " box ", .host = " me@box ", .instance = " dev.1_x-y " }, null, &eb)) == null);
    const p = store.find("box").?;
    try testing.expectEqualStrings("me@box", p.host);
    try testing.expectEqualStrings("dev.1_x-y", p.instance);
    try testing.expectEqual(@as(usize, 16), p.id.len);
    const id = try a.dupe(u8, p.id);
    defer a.free(id);
    // duplicate name
    try testing.expectEqualStrings("a profile named \"box\" already exists", (try store.save(io, .{ .name = "box", .host = "x" }, null, &eb)).?);
    // rename keeps id, downloadDir carries over, lastProfile follows
    a.free(p.download_dir);
    p.download_dir = try a.dupe(u8, "/dl");
    try store.setLastProfile("box");
    try testing.expect((try store.save(io, .{ .name = "box2", .host = "me@box" }, "box", &eb)) == null);
    try testing.expect(store.find("box") == null);
    const r = store.find("box2").?;
    try testing.expectEqualStrings(id, r.id);
    try testing.expectEqualStrings("/dl", r.download_dir);
    try testing.expectEqualStrings("box2", store.last_profile.?);
    try testing.expectEqual(@as(usize, 1), store.profiles.items.len);
    // rename onto an existing name is refused
    try testing.expect((try store.save(io, .{ .name = "other", .host = "o" }, null, &eb)) == null);
    try testing.expectEqualStrings("a profile named \"other\" already exists", (try store.save(io, .{ .name = "other", .host = "x" }, "box2", &eb)).?);
    try store.delete("box2");
    try testing.expect(store.last_profile == null);
    try testing.expect(profile_mod.validInstance(""));
}

test "store JSON round-trip and settings sanitizing" {
    const a = testing.allocator;
    var store = profile_mod.Store.init(a);
    defer store.deinit();
    var eb: [256]u8 = undefined;
    try testing.expect((try store.save(io, .{ .name = "a", .host = "h1", .ssh_port = 2222, .identity_file = "~/.ssh/k", .instance = "i", .extra_options = "-o ProxyJump=b", .download_dir = "/tmp" }, null, &eb)) == null);
    try testing.expect((try store.save(io, .{ .name = "b \"q\"", .host = "h2" }, null, &eb)) == null);
    try store.setLastProfile("a");
    store.settings = profile_mod.sanitizeSettings(store.settings, .{ .theme = "light", .unfocused_fade = 12.5, .min_cols = 100, .max_cols = 80 });
    try testing.expectEqual(@as(u8, 13), store.settings.unfocused_fade); // Math.round
    try testing.expectEqual(@as(u16, 100), store.settings.max_cols); // range stays a range
    const json = try store.toJson(a);
    defer a.free(json);
    try testing.expect(std.mem.startsWith(u8, json, "{\n  \"profiles\": [\n    {\n      \"name\": \"a\",\n      \"host\": \"h1\",\n      \"sshPort\": 2222,"));
    try testing.expect(std.mem.endsWith(u8, json, "}\n"));
    try testing.expect(std.mem.indexOf(u8, json, "passwordEnc") == null and std.mem.indexOf(u8, json, "localPort") == null);

    var back = profile_mod.Store.init(a);
    defer back.deinit();
    try back.loadJson(json, io);
    try testing.expectEqual(@as(usize, 2), back.profiles.items.len);
    const p = back.profiles.items[0];
    try testing.expectEqualStrings("a", p.name);
    try testing.expectEqual(@as(u32, 2222), p.ssh_port);
    try testing.expectEqualStrings("~/.ssh/k", p.identity_file);
    try testing.expectEqualStrings("-o ProxyJump=b", p.extra_options);
    try testing.expectEqualStrings("/tmp", p.download_dir);
    try testing.expectEqualStrings(store.profiles.items[0].id, p.id);
    try testing.expectEqualStrings("b \"q\"", back.profiles.items[1].name);
    try testing.expectEqualStrings("a", back.last_profile.?);
    try testing.expectEqualStrings("light", back.settings.theme.slice());
    const json2 = try back.toJson(a);
    defer a.free(json2);
    try testing.expectEqualStrings(json, json2);

    // hand-edited / odd values: JS Number() semantics, clamps, unknown fields
    var odd = profile_mod.Store.init(a);
    defer odd.deinit();
    try odd.loadJson(
        \\{"profiles":[{"name":"x","host":"y","sshPort":"22","passwordEnc":"zz","localPort":5,"bogus":1}, 7],
        \\ "lastProfile":"x","settings":{"theme":"Bad Theme!","unfocusedFade":"250","minCols":null,"maxCols":true}}
    , io);
    try testing.expectEqual(@as(u32, 22), odd.profiles.items[0].ssh_port);
    try testing.expectEqual(@as(usize, 1), odd.profiles.items.len);
    try testing.expectEqualStrings("dark", odd.settings.theme.slice());
    try testing.expectEqual(@as(u8, 100), odd.settings.unfocused_fade);
    try testing.expectEqual(@as(u16, 40), odd.settings.min_cols); // Number(null) = 0 → clamp 40
    try testing.expectEqual(@as(u16, 40), odd.settings.max_cols); // Number(true) = 1 → 40
    // garbage file → an error (the engine keeps the file aside), defaults
    var bad = profile_mod.Store.init(a);
    defer bad.deinit();
    try testing.expectError(error.InvalidConfig, bad.loadJson("not json", io));
    try testing.expectError(error.InvalidConfig, bad.loadJson("[1,2]", io));
    try testing.expectEqual(@as(u16, 90), bad.settings.min_cols);
    try testing.expectEqual(@as(u16, 200), bad.settings.max_cols);
    try testing.expectEqual(@as(u8, 40), bad.settings.unfocused_fade);
    // ports: hand-edited out-of-range values are kept (connect refuses
    // them), fractions and negatives are not ports
    var ports = profile_mod.Store.init(a);
    defer ports.deinit();
    try ports.loadJson(
        \\{"profiles":[{"name":"big","host":"h","sshPort":99999},{"name":"frac","host":"h","sshPort":22.5},
        \\ {"name":"neg","host":"h","sshPort":-1},{"name":"hex","host":"h","sshPort":"0x16"},{"name":"f","host":"h","sshPort":"22.0"},
        \\ {"name":"ok","host":"h","sshPort":"2222"},{"name":"ok2","host":"h","sshPort":22}]}
    , io);
    // deviation 39: only whole decimal numbers 0–65535; the rest is
    // repaired to the default and reported
    for (ports.profiles.items[0..5]) |pp| try testing.expectEqual(@as(u32, 0), pp.ssh_port);
    try testing.expectEqual(@as(u32, 2222), ports.profiles.items[5].ssh_port);
    try testing.expectEqual(@as(u32, 22), ports.profiles.items[6].ssh_port);
    var port_repairs: usize = 0;
    for (ports.repairs.items) |r| {
        if (std.mem.indexOf(u8, r, "\"sshPort\"") != null) port_repairs += 1;
    }
    try testing.expectEqual(@as(usize, 5), port_repairs);
    try testing.expect(std.mem.indexOf(u8, ports.repairs.items[0], "\"big\": \"sshPort\" 99999 is not a port") != null);
    try testing.expectEqual(@as(?u32, null), profile_mod.parsePort("0"));
    try testing.expectEqual(@as(?u32, null), profile_mod.parsePort("0x16"));
    try testing.expectEqual(@as(?u32, null), profile_mod.parsePort("22.0"));
    try testing.expectEqual(@as(?u32, 0), profile_mod.parsePort(" "));
    try testing.expectEqual(@as(?u32, 65535), profile_mod.parsePort("65535"));
    try testing.expectEqualStrings(profile_mod.PORT_ERROR, (try ports.save(io, .{ .name = "x", .host = "h", .ssh_port = 70000 }, null, &eb)).?);
    try testing.expect((try ports.save(io, .{ .name = "x", .host = "h", .ssh_port = 65535, .id = "00ff00ff00ff00ff" }, null, &eb)) == null);
    try testing.expectEqualStrings("00ff00ff00ff00ff", ports.find("x").?.id);
}

test "log: whole-number floats of any size never crash (G-04)" {
    var buf: [64]u8 = undefined;
    inline for (.{ .{ 1e20, "100000000000000000000" }, .{ 9.223372036854775808e18, "9223372036854775808" }, .{ -1e20, "-100000000000000000000" } }) |c| {
        var w: Io.Writer = .fixed(&buf);
        try util.writeJsNumber(&w, c[0]);
        try testing.expectEqualStrings(c[1], w.buffered());
    }
    const log = try Log.init(testing.allocator, io);
    defer log.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"level":"info","msg":"x","data":{"a":1e20,"b":-9.3e18,"c":1e300}}
    , .{});
    defer parsed.deinit();
    log.pushJson("h", .page, parsed.value);
    const t = try log.text(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expect(std.mem.indexOf(u8, t, "a=100000000000000000000") != null);
}

test "host slug matches main.js appOrigin" {
    var buf: [256]u8 = undefined;
    // reference values computed with node from main.js's appOrigin
    try testing.expectEqualStrings("me-box-example-com-05547d73", try profile_mod.hostSlug("me@Box.example.com", "", &buf));
    try testing.expectEqualStrings("x-1ea96727", try profile_mod.hostSlug("--x--", "dev", &buf));
    try testing.expectEqualStrings("95b88b65", try profile_mod.hostSlug("@@@", "a.b", &buf));
    try testing.expectEqualStrings("host-a22a7f04", try profile_mod.hostSlug("host", "", &buf));
    try testing.expectEqualStrings("host-a22a7f04", try profile_mod.hostSlug("host", "default", &buf));
}

// ---------------------------------------------------------------------------
// ssh argv and environment
// ---------------------------------------------------------------------------

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("argv len {d} != {d}\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "ssh argv: key auth, password auth, each optional field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: conn.Profile = .{ .name = "n", .host = "me@box" };
    const common = [_][]const u8{ "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-o", "ConnectTimeout=10" };

    try expectArgv(&(.{ "ssh", "-o", "BatchMode=yes" } ++ common ++ .{ "me@box", "uname" }), try ssh.commandArgv(a, "ssh", base, false, "uname"));
    try expectArgv(&(.{ "ssh", "-o", "NumberOfPasswordPrompts=1" } ++ common ++ .{ "me@box", "uname" }), try ssh.commandArgv(a, "ssh", base, true, "uname"));

    var full = base;
    full.ssh_port = 2222;
    full.identity_file = "/k/id_ed25519";
    full.extra_options = "  -o ProxyJump=bastion\t-4 ";
    try expectArgv(&(.{ "ssh", "-o", "BatchMode=yes" } ++ common ++ .{ "-p", "2222", "-i", "/k/id_ed25519", "-o", "ProxyJump=bastion", "-4", "me@box", "cmd" }), try ssh.commandArgv(a, "ssh", full, false, "cmd"));

    var port_only = base;
    port_only.ssh_port = 22;
    try expectArgv(&(.{ "ssh", "-o", "BatchMode=yes" } ++ common ++ .{ "-p", "22", "me@box", "c" }), try ssh.commandArgv(a, "ssh", port_only, false, "c"));
    var id_only = base;
    id_only.identity_file = "k";
    try expectArgv(&(.{ "ssh", "-o", "BatchMode=yes" } ++ common ++ .{ "-i", "k", "me@box", "c" }), try ssh.commandArgv(a, "ssh", id_only, false, "c"));

    // the tunnel: unix-socket local end, stale-socket unlink
    try expectArgv(&(.{ "ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-o", "NumberOfPasswordPrompts=1" } ++ common ++
        .{ "-p", "2222", "-i", "/k/id_ed25519", "-o", "ProxyJump=bastion", "-4", "-L", "/run/user/1/webmux-gtk/box-1.sock:/run/user/9/webmux/default.http.sock", "me@box" }), try ssh.tunnelArgv(a, "ssh", full, true, "/run/user/1/webmux-gtk/box-1.sock", "/run/user/9/webmux/default.http.sock"));

    const argv = try ssh.tunnelArgv(a, "/x/ssh", base, false, "/l.sock", "/r.sock");
    try testing.expectEqualStrings("ssh -N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ConnectTimeout=10 -L /l.sock:/r.sock me@box", try ssh.joinForLog(a, argv));
}

test "ssh env: password only in the child env, askpass helper" {
    const a = testing.allocator;
    var base = std.process.Environ.Map.init(a);
    defer base.deinit();
    try base.put("PATH", "/bin");
    try base.put("WEBMUX_SSH_PASSWORD", "inherited-must-not-leak");
    var keyonly = try ssh.childEnv(a, &base, "/r/askpass.sh", null);
    defer keyonly.deinit();
    try testing.expect(keyonly.get("SSH_ASKPASS") == null);
    try testing.expect(keyonly.get("WEBMUX_SSH_PASSWORD") == null);
    var pw = try ssh.childEnv(a, &base, "/r/askpass.sh", "hunter2");
    try testing.expectEqualStrings("/r/askpass.sh", pw.get("SSH_ASKPASS").?);
    try testing.expectEqualStrings("force", pw.get("SSH_ASKPASS_REQUIRE").?);
    try testing.expectEqualStrings("hunter2", pw.get("WEBMUX_SSH_PASSWORD").?);
    const v = pw.get("WEBMUX_SSH_PASSWORD").?;
    ssh.wipe(&pw);
    _ = v;
    try testing.expectEqualStrings("#!/bin/sh\nprintf '%s' \"$WEBMUX_SSH_PASSWORD\"\n", ssh.ASKPASS_SCRIPT);
}

// ---------------------------------------------------------------------------
// Log
// ---------------------------------------------------------------------------

test "log: file line format matches log.js formatLine" {
    const a = testing.allocator;
    const log = try Log.init(a, io);
    defer log.deinit();
    log.fixed_time = "2026-11-04T10:00:00.000Z";
    _ = log.push(.{ .level = .info, .conn = "box", .msg = "tunnel spawned", .data = &.{
        .{ .key = "pid", .value = .{ .int = 123 } },
        .{ .key = "socket", .value = .{ .str = "/run/user/1/webmux-gtk/box-1.sock" } },
        .{ .key = "cmd", .value = .{ .str = "ssh -N host" } },
        .{ .key = "empty", .value = .{ .str = "" } },
        .{ .key = "code", .value = .null },
        .{ .key = "ok", .value = .{ .boolean = true } },
        .{ .key = "obj", .value = .{ .json = "{\"a\":1}" } },
        .{ .key = "q", .value = .{ .str = "say \"hi\"\n" } },
        .{ .key = "bad-key", .value = .{ .int = 1 } },
    } });
    _ = log.push(.{ .level = .warn, .msg = "app-wide" });
    _ = log.push(.{ .level = .@"error", .src = .page, .conn = "box", .msg = "socket dropped" });
    _ = log.push(.{ .level = .debug, .conn = "b", .msg = "d", .data = &.{.{ .key = "f", .value = .{ .float = 1.5 } }} });
    const t = try log.text(a);
    defer a.free(t);
    // expected lines produced by node with electron/log.js formatLine
    try testing.expectEqualStrings(
        \\2026-11-04T10:00:00.000Z INFO  [box] tunnel spawned pid=123 socket=/run/user/1/webmux-gtk/box-1.sock cmd="ssh -N host" empty="" code=null ok=true obj="{\"a\":1}" q="say \"hi\"\n"
        \\2026-11-04T10:00:00.000Z WARN  app-wide
        \\2026-11-04T10:00:00.000Z ERROR [box] page: socket dropped
        \\2026-11-04T10:00:00.000Z DEBUG [b] d f=1.5
    , t);
}

test "log: sanitizing, ring bound, since, clear, subscribe" {
    const a = testing.allocator;
    const log = try Log.init(a, io);
    defer log.deinit();
    log.fixed_time = "2026-11-04T10:00:00.000Z";
    const long = @as([700]u8, @splat('m'));
    const long_data = @as([400]u8, @splat('d'));
    var fields: [14]Log.Field = undefined;
    for (&fields, 0..) |*f, i| f.* = .{ .key = ([_][]const u8{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9", "k10", "k11", "k12", "k13" })[i], .value = .{ .int = @intCast(i) } };
    fields[0].value = .{ .str = &long_data };
    const long_conn = @as([100]u8, @splat('n'));
    _ = log.push(.{ .conn = &long_conn, .msg = &long, .data = &fields });
    var snap = try log.since(a, 0);
    defer snap.deinit();
    const e = snap.entries[0];
    try testing.expectEqual(@as(usize, 500), e.msg.len);
    try testing.expectEqual(@as(usize, 80), e.conn.?.len);
    try testing.expectEqual(@as(usize, 12), e.data.len); // first 12 considered
    try testing.expectEqual(@as(usize, 300 + "…".len), e.data[0].value.str.len);

    // page-style JSON input: level whitelist, plain keys
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"level\":\"fatal\",\"msg\":\"hi\",\"data\":{\"ok\":1,\"bad key\":2,\"o\":{\"x\":[1]}}}", .{});
    defer parsed.deinit();
    log.pushJson("box", .page, parsed.value);
    var s2 = try log.since(a, e.seq);
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 1), s2.entries.len);
    try testing.expectEqualStrings("2026-11-04T10:00:00.000Z INFO  [box] page: hi ok=1 o=\"{\\\"x\\\":[1]}\"", s2.lines[0]);

    // subscription
    const Sub = struct {
        var count: usize = 0;
        var last_seq: u64 = 0;
        fn f(_: ?*anyopaque, entry: *const Log.Entry) void {
            count += 1;
            last_seq = entry.seq;
        }
    };
    const id = try log.subscribe(.{ .ctx = null, .func = Sub.f });
    const seq = log.push(.{ .msg = "x" });
    try testing.expectEqual(@as(usize, 1), Sub.count);
    try testing.expectEqual(seq, Sub.last_seq);
    log.unsubscribe(id);
    _ = log.push(.{ .msg = "y" });
    try testing.expectEqual(@as(usize, 1), Sub.count);

    // ring bound
    for (0..Log.MAX_ENTRIES + 10) |_| _ = log.push(.{ .msg = "fill" });
    var s3 = try log.since(a, 0);
    defer s3.deinit();
    try testing.expectEqual(@as(usize, Log.MAX_ENTRIES), s3.entries.len);
    try testing.expect(s3.entries[0].seq > 10);
    // clear leaves one line saying so
    log.clear();
    var s4 = try log.since(a, 0);
    defer s4.deinit();
    try testing.expectEqual(@as(usize, 1), s4.entries.len);
    try testing.expectEqualStrings("log cleared (file untouched)", s4.entries[0].msg);
}

test "log: file sink and rotation" {
    const a = testing.allocator;
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const dir = try std.fmt.allocPrint(a, "/tmp/wm-lg-{x}/logs", .{std.mem.readInt(u32, &rnd, .little)});
    defer a.free(dir);
    defer Io.Dir.cwd().deleteTree(io, std.fs.path.dirname(dir).?) catch {};
    const log = try Log.init(a, io);
    defer log.deinit();
    log.fixed_time = "2026-11-04T10:00:00.000Z";
    try log.initFile(dir);
    log.file_max = 200;
    const file = log.filePath().?;
    try testing.expect(std.mem.endsWith(u8, file, "/logs/webmux.log"));
    _ = log.push(.{ .conn = "box", .msg = "first" });
    const body = (try util.readFileAlloc(io, a, file, 1 << 20)).?;
    defer a.free(body);
    try testing.expectEqualStrings("2026-11-04T10:00:00.000Z INFO  [box] first\n", body);
    // grow past file_max: the next push rolls webmux.log → webmux.log.1
    for (0..6) |_| _ = log.push(.{ .msg = "padding padding padding padding" });
    const rolled_path = try std.fmt.allocPrint(a, "{s}.1", .{file});
    defer a.free(rolled_path);
    const rolled = (try util.readFileAlloc(io, a, rolled_path, 1 << 20)).?;
    defer a.free(rolled);
    try testing.expect(std.mem.startsWith(u8, rolled, "2026-11-04T10:00:00.000Z INFO  [box] first\n"));
    try testing.expect(rolled.len > 200);
    const cur = (try util.readFileAlloc(io, a, file, 1 << 20)).?;
    defer a.free(cur);
    try testing.expect(cur.len < rolled.len);
    try testing.expect(std.mem.endsWith(u8, cur, "padding padding padding padding\n"));
    // a reopened sink picks up the existing size
    const log2 = try Log.init(a, io);
    defer log2.deinit();
    try log2.initFile(dir);
    try testing.expectEqual(@as(u64, cur.len), log2.file_size);
}

// ---------------------------------------------------------------------------
// Engine: store through the API
// ---------------------------------------------------------------------------

test "engine: config.json round-trip, settings, lastProfile, payload lookup" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    var e = try f.start();
    {
        const want = try f.path("payload");
        defer f.alloc.free(want);
        try testing.expectEqualStrings(want, e.payloadDir().?);
    }
    try f.addProfile("box", "me@box", "");
    try testing.expectEqualStrings("a profile named \"box\" already exists", e.saveProfile(.{ .name = "box", .host = "x" }, null).?);
    const s = e.updateSettings(.{ .theme = "light", .min_cols = 120 });
    try testing.expectEqualStrings("light", s.theme.slice());
    try testing.expectEqual(@as(u32, 1), f.events.settings);
    try testing.expect(e.connect("nope") != null);
    f.stop();
    // reload from disk
    e = try f.start();
    var list = try e.listProfiles(testing.allocator);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.profiles.len);
    try testing.expectEqualStrings("me@box", list.profiles[0].host);
    try testing.expect(std.mem.endsWith(u8, list.file, "/config/webmux-gtk/config.json"));
    try testing.expectEqual(@as(u16, 120), e.settings().min_cols);
    try testing.expectEqualStrings("light", e.settings().theme.slice());
    const cfg = try f.read("config/webmux-gtk/config.json");
    defer f.alloc.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "\"lastProfile\": null") != null);
    // the log file exists under XDG_STATE_HOME
    try testing.expect(f.exists("state/webmux-gtk/logs/webmux.log"));
    // askpass helper in the runtime dir
    const ap = try f.read("run/webmux-gtk/askpass.sh");
    defer f.alloc.free(ap);
    try testing.expectEqualStrings(ssh.ASKPASS_SCRIPT, ap);
}

// ---------------------------------------------------------------------------
// Deploy end to end through the engine (fake ssh)
// ---------------------------------------------------------------------------

fn lineWith(hay: []const u8, needle: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, hay, '\n');
    while (it.next()) |l| if (std.mem.indexOf(u8, l, needle) != null) return l;
    return null;
}

test "deploy: fresh push, reuse, outdated server replaced, failures surface stderr" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const h1 = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("box", "me@box", "inst1");

    // 1. fresh host: probe + push + start, then tunnel and connected
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);
    {
        var st = (try e.status(f.alloc, "box")).?;
        defer st.deinit();
        try testing.expect(std.mem.endsWith(u8, st.socket_path.?, ".sock"));
        try testing.expect(std.mem.startsWith(u8, st.socket_path.?, f.root));
        try testing.expectEqualStrings("/remote/inst1.http.sock", st.remote_socket.?);
        try testing.expectEqualStrings("", st.msg);
        try testing.expect(st.had_connection);
    }
    const remote_dir = try std.fmt.allocPrint(f.alloc, "remote/.webmux/dist/payload/{s}", .{&h1});
    defer f.alloc.free(remote_dir);
    const bin_rel = try std.fmt.allocPrint(f.alloc, "{s}/webmux-host", .{remote_dir});
    defer f.alloc.free(bin_rel);
    try testing.expect(f.exists(bin_rel));
    const shim_rel = try std.fmt.allocPrint(f.alloc, "{s}/shims/xdg-open", .{remote_dir});
    defer f.alloc.free(shim_rel);
    try testing.expect(f.exists(shim_rel));
    {
        const hl = try f.read("remote/fake-host.log");
        defer f.alloc.free(hl);
        const want = try std.fmt.allocPrint(f.alloc, "{s}/remote/.webmux/dist/payload/{s}/webmux-host start --name inst1 cwd={s}/remote\n", .{ f.root, &h1, f.root });
        defer f.alloc.free(want);
        try testing.expectEqualStrings(want, hl); // exact start command line
        const sl = try f.sshLog();
        defer f.alloc.free(sl);
        try testing.expectEqual(@as(usize, 4), countOf(sl, "ARGV ")); // probe + push + start + tunnel
        try testing.expect(std.mem.indexOf(u8, sl, "-N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o BatchMode=yes") != null);
        try testing.expect(std.mem.indexOf(u8, sl, "PWENV") == null);
        const fwd = try f.read("remote/last-forward");
        defer f.alloc.free(fwd);
        try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, fwd, "\n"), ".sock:/remote/inst1.http.sock"));
    }
    try testing.expect(f.logHas("[box] connect requested host=me@box instance=inst1 socket="));
    try testing.expect(f.logHas("auth=key"));
    try testing.expect(f.logHas("[box] deploy: probing host…"));
    try testing.expect(f.logHas("[box] deploy: pushing webmux… "));
    try testing.expect(f.logHas("[box] deploy: starting server…"));
    try testing.expect(f.logHas("[box] deploy done: server started ms="));
    try testing.expect(f.logHas("[box] tunnel spawned pid="));
    try testing.expect(f.logHas("[box] probe: server answered through the tunnel afterMs="));
    try testing.expect(f.logHas("[box] state connecting → connected"));
    {
        // one "deploy: pushing" line despite many progress updates
        const t = try f.logText();
        defer f.alloc.free(t);
        try testing.expectEqual(@as(usize, 1), countOf(t, "deploy: pushing"));
    }

    // 2. reconnect: the hash is present → probe + start only, server reused
    f.removeFile("ssh.log");
    try testing.expect(e.reconnect("box") == null);
    try f.waitLog("deploy done: server reuse", 8000);
    try f.waitLogCount("probe: server answered through the tunnel", 2, 8000);
    try f.waitState("box", .connected, 8000);
    {
        const sl = try f.sshLog();
        defer f.alloc.free(sl);
        try testing.expectEqual(@as(usize, 3), countOf(sl, "ARGV ")); // probe + start + tunnel
        try testing.expect(f.logHas("[box] tunnel killed (reconnect)"));
        try testing.expect(f.logHas("[box] tunnel exited (superseded)"));
        try testing.expect(f.logHas("[box] reconnect requested"));
    }

    // 3. a new client build: push v2, the old server is replaced
    const h2 = try f.buildPayload("v2");
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
    f.removeFile("ssh.log");
    try testing.expect(e.reconnect("box") == null);
    try f.waitLogCount("deploy done: server started ms=", 2, 8000);
    try f.waitLogCount("probe: server answered through the tunnel", 3, 8000);
    try f.waitState("box", .connected, 8000);
    {
        const sl = try f.sshLog();
        defer f.alloc.free(sl);
        try testing.expectEqual(@as(usize, 4), countOf(sl, "ARGV "));
        const hl = try f.read("remote/fake-host.log");
        defer f.alloc.free(hl);
        try testing.expect(std.mem.indexOf(u8, hl, "replacing {\"payloadHash\":\"") != null);
        try testing.expect(std.mem.indexOf(u8, hl, &h1) != null);
        const want = try std.fmt.allocPrint(f.alloc, "payload/{s}/webmux-host start --name inst1", .{&h2});
        defer f.alloc.free(want);
        try testing.expect(std.mem.indexOf(u8, hl, want) != null);
    }

    // 4. starter failure: error and logTail surface; never connected → failed
    e.disconnect("box");
    try f.waitFor(struct {
        fn p(x: *Fixture) bool {
            return x.removedCount() == 1;
        }
    }.p, 5000);
    try f.writeFile("remote/fail-start", "");
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .failed, 8000);
    {
        var st = (try e.status(f.alloc, "box")).?;
        defer st.deinit();
        try testing.expectEqualStrings("connection failed", st.msg);
        try testing.expect(std.mem.indexOf(u8, st.stderr, "tail one\ntail two\nserver start failed: boom") != null);
        try testing.expect(st.socket_path == null);
    }
    try testing.expect(f.logHas("[box] deploy failed ms="));
    try testing.expect(f.logHas("error=\"server start failed: boom\""));
    try testing.expect(f.logHas("[box] state connecting → failed msg=\"connection failed\""));
    f.removeFile("remote/fail-start");

    // 5. a platform this build has no payload for → clear error, only the probe ran
    try f.writeFile("payload/payload.json", "{\"platforms\":{\"linux-arm64\":{\"hash\":\"bad\"}}}");
    f.removeFile("ssh.log");
    try testing.expect(e.reconnect("box") == null);
    try f.waitLog("this client build has no linux-", 8000);
    try f.waitState("box", .failed, 8000);
    {
        const sl = try f.sshLog();
        defer f.alloc.free(sl);
        try testing.expectEqual(@as(usize, 1), countOf(sl, "ARGV "));
    }
}

test "supervisor: a connect that never succeeds parks as failed with ssh stderr, no retry" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("typo", "badhost", "");
    try testing.expect(e.connect("typo") == null);
    try f.waitState("typo", .failed, 5000);
    var st = (try e.status(f.alloc, "typo")).?;
    defer st.deinit();
    try testing.expectEqualStrings("connection failed", st.msg);
    try testing.expect(std.mem.indexOf(u8, st.stderr, "ssh: Could not resolve hostname badhost: Name or service not known") != null);
    try testing.expect(std.mem.indexOf(u8, st.stderr, "ssh exited (255)") != null);
    try testing.expect(!st.had_connection);
    // nothing churns in the background
    const probes = f.probe_count.load(.monotonic);
    sleepMs(800);
    try testing.expectEqual(conn.State.failed, f.stateOf("typo").?);
    try testing.expect(!f.sawState(.retry));
    try testing.expectEqual(probes, f.probe_count.load(.monotonic));
    try testing.expect(f.logHas("[typo] ssh: ssh: Could not resolve hostname badhost"));
    // disconnect from failed
    e.disconnect("typo");
    try f.waitFor(struct {
        fn p(x: *Fixture) bool {
            return x.removedCount() == 1;
        }
    }.p, 3000);
    try testing.expect(f.logHas("[typo] disconnecting (user) state=failed"));
    try testing.expect((try e.status(f.alloc, "typo")) == null);
}

test "supervisor: interrupted established connection retries with backoff and recovers" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("box", "me@box", "");
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);

    // the link drops and ssh can't get back in for a while
    try f.writeFile("remote/ssh-down", "");
    try f.writeFile("remote/drop-tunnel", "");
    try f.waitState("box", .retry, 5000);
    {
        var st = (try e.status(f.alloc, "box")).?;
        defer st.deinit();
        try testing.expectEqualStrings("ssh exited (255)", st.msg);
        try testing.expect(st.retry_delay_s >= 0);
        try testing.expect(st.retry_at_ms > 0);
        try testing.expect(st.retryRemainingMs(e.nowMs()) <= 1200);
        try testing.expect(std.mem.indexOf(u8, st.stderr, "client_loop: send disconnect: Broken pipe") != null);
    }
    try f.waitLog("[box] tunnel exited pid=", 3000);
    try f.waitLog("[box] interrupted — retry in 0.3s exitCode=255", 3000);
    // retries fail (ssh-down) and the delay doubles: 0.3 → 0.6 → 1.2 (cap)
    try f.waitLog("[box] interrupted — retry in 0.6s", 5000);
    try f.waitLog("[box] interrupted — retry in 1.2s", 5000);
    try testing.expect(f.logHas("[box] retrying"));
    try testing.expect(f.logHas("[box] deploy failed"));
    try testing.expect(!f.sawState(.failed)); // an established cycle never parks
    // the host comes back: the next retry heals it
    f.removeFile("remote/ssh-down");
    try f.waitState("box", .connected, 8000);
    try testing.expect(f.logHas("[box] state retry → connecting"));
}

test "supervisor: probe misses kill the tunnel; a fresh tunnel that never answers is killed too" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("box", "me@box", "");
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);

    // the remote server dies; ssh -N stays up
    try f.writeFile("remote/server-dead", "");
    try f.waitLog("[box] probe missed (1/3) error=ConnectionRefused", 3000);
    try f.waitLog("[box] probe missed (3/3)", 3000);
    try f.waitLog("[box] probe: server unreachable through the tunnel — reconnecting misses=3", 3000);
    try f.waitState("box", .retry, 3000);
    {
        var st = (try e.status(f.alloc, "box")).?;
        defer st.deinit();
        try testing.expectEqualStrings("ssh exited (SIGTERM)", st.msg);
        try testing.expect(std.mem.indexOf(u8, st.stderr, "server unreachable through the tunnel — reconnecting") != null);
    }
    // killed link → retry at once (delay reset to 0, then the 0.3 minimum)
    try f.waitLog("[box] interrupted — retry in 0.3s exitCode=SIGTERM", 3000);
    // the retry deploys and tunnels, but the server never answers → first-answer deadline
    try f.waitLog("[box] probe: server did not answer through the tunnel", 6000);
    try testing.expect(!f.sawState(.failed));
    f.removeFile("remote/server-dead");
    try f.waitState("box", .connected, 8000);
    try testing.expect(f.logHas("[box] state retry → connecting"));
}

test "supervisor: notifyResume kills live tunnels; the cycle retries and reconnects" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("box", "me@box", "");
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);
    f.clearStates();
    e.notifyResume();
    try f.waitLog("system resumed from sleep tunnelsKilled=1", 2000);
    try f.waitLog("[box] killing pre-sleep tunnel to reconnect now pid=", 2000);
    try f.waitLog("[box] interrupted — retry in 0.3s", 3000);
    try f.waitState("box", .connected, 8000);
    try testing.expect(f.sawState(.retry));
}

test "supervisor: disconnect during deploy, connected, retry and failed" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("box", "me@box", "");
    const Removed = struct {
        fn n(comptime k: usize) fn (*Fixture) bool {
            return struct {
                fn p(x: *Fixture) bool {
                    return x.removedCount() >= k;
                }
            }.p;
        }
    };

    // during a (slow) deploy step
    try f.writeFile("remote/slow", "");
    try testing.expect(e.connect("box") == null);
    try f.waitLog("[box] deploy step: ssh pid=", 3000);
    sleepMs(100);
    const t0 = util.monoMs(io);
    e.disconnect("box");
    try testing.expect((try e.status(f.alloc, "box")) == null); // gone from the snapshot at once
    try f.waitFor(Removed.n(1), 4000);
    try testing.expect(util.monoMs(io) - t0 < 3000); // did not wait out the 30 s step
    try testing.expect(f.logHas("[box] disconnecting (user) state=connecting"));
    try testing.expect(f.logHas("[box] deploy step killed (user) pid="));
    f.removeFile("remote/slow");

    // while connected
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);
    e.disconnect("box");
    try f.waitFor(Removed.n(2), 4000);
    try testing.expect(f.logHas("[box] disconnecting (user) state=connected"));
    try testing.expect(f.logHas("[box] tunnel killed (user) pid="));
    {
        // the tunnel's local socket is cleaned up
        var buf: [256]u8 = undefined;
        const slug = try profile_mod.hostSlug("me@box", "", &buf);
        const sock = try std.fmt.allocPrint(f.alloc, "run/webmux-gtk/{s}.sock", .{slug});
        defer f.alloc.free(sock);
        try testing.expect(!f.exists(sock));
    }

    // while waiting to retry
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);
    try f.writeFile("remote/ssh-down", "");
    try f.writeFile("remote/drop-tunnel", "");
    try f.waitState("box", .retry, 5000);
    e.disconnect("box");
    try f.waitFor(Removed.n(3), 4000);
    try testing.expect(f.logHas("[box] disconnecting (user) state=retry"));
    try f.waitLog("[box] pending retry cancelled (user)", 2000);
    f.removeFile("remote/ssh-down");

    // while parked as failed
    try f.writeFile("remote/ssh-down", "");
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .failed, 5000);
    e.disconnect("box");
    try f.waitFor(Removed.n(4), 4000);
    f.removeFile("remote/ssh-down");

    // deleting a connected profile disconnects it
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);
    try testing.expect(e.deleteProfile("box") == null);
    try f.waitFor(Removed.n(5), 4000);
    try testing.expect(f.logHas("[box] disconnecting (profile deleted) state=connected"));
}

test "supervisor: password auth via askpass, never in argv or the log" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("pw", "me@pwbox", "");
    f.password = "s3cr3t-pw";
    try testing.expect(e.connect("pw") == null);
    try f.waitState("pw", .connected, 8000);
    try testing.expect(f.logHas("auth=password"));
    {
        const sl = try f.sshLog();
        defer f.alloc.free(sl);
        try testing.expect(std.mem.indexOf(u8, sl, "-o NumberOfPasswordPrompts=1") != null);
        try testing.expect(std.mem.indexOf(u8, sl, "BatchMode") == null);
        try testing.expect(std.mem.indexOf(u8, sl, "PWENV set") != null);
        try testing.expect(std.mem.indexOf(u8, sl, "s3cr3t") == null);
    }
    // wrong password: one attempt, fails fast into failed with ssh's verdict
    f.password = "wrong-one";
    try testing.expect(e.reconnect("pw") == null);
    try f.waitState("pw", .failed, 5000);
    {
        var st = (try e.status(f.alloc, "pw")).?;
        defer st.deinit();
        try testing.expect(std.mem.indexOf(u8, st.stderr, "Permission denied (publickey,password).") != null);
        try testing.expect(std.mem.indexOf(u8, st.stderr, "wrong-one") == null);
    }
    // keyring refuses: park with main.js's message, no ssh spawned
    f.password_unavailable = true;
    f.removeFile("ssh.log");
    try testing.expect(e.reconnect("pw") == null);
    try f.waitLog("[pw] saved password could not be decrypted error=\"keyring locked\"", 3000);
    try f.waitState("pw", .failed, 3000);
    // a stored password is password auth even when it cannot be read (C-7)
    try f.waitLog("[pw] reconnect requested host=me@pwbox", 3000);
    {
        const t0 = try f.logText();
        defer f.alloc.free(t0);
        var last: []const u8 = "";
        var it = std.mem.splitScalar(u8, t0, '\n');
        while (it.next()) |l| if (std.mem.indexOf(u8, l, "[pw] reconnect requested") != null) {
            last = l;
        };
        try testing.expect(std.mem.indexOf(u8, last, "auth=password") != null);
    }
    {
        var st = (try e.status(f.alloc, "pw")).?;
        defer st.deinit();
        try testing.expectEqualStrings("saved password could not be decrypted — edit the profile and re-enter it", st.msg);
        try testing.expect(!f.exists("ssh.log"));
    }
    // the password never reached the log ring or the log file
    const t = try f.logText();
    defer f.alloc.free(t);
    try testing.expect(std.mem.indexOf(u8, t, "s3cr3t") == null and std.mem.indexOf(u8, t, "wrong-one") == null);
    f.stop();
    const file = try f.read("state/webmux-gtk/logs/webmux.log");
    defer f.alloc.free(file);
    try testing.expect(std.mem.indexOf(u8, file, "s3cr3t") == null and std.mem.indexOf(u8, file, "wrong-one") == null);
    try testing.expect(std.mem.indexOf(u8, file, "client quitting connections=1") != null);
}

test "engine: rename follows a live connection; host+instance collisions refused" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("a", "me@box", "");
    try f.addProfile("b", "me@box", "default"); // same host+instance as "a"
    try f.addProfile("c", "me@box", "other");
    try testing.expect(e.connect("a") == null);
    try f.waitState("a", .connected, 8000);
    try testing.expectEqualStrings("\"a\" is already connected to this host and instance", e.connect("b").?);
    try testing.expect(e.connect("c") == null);
    try f.waitState("c", .connected, 8000);
    // connect on a connected profile is a no-op
    try testing.expect(e.connect("a") == null);
    // rename keeps the connection and its pill position
    try testing.expect(e.saveProfile(.{ .name = "a2", .host = "me@box" }, "a") == null);
    try testing.expectEqual(conn.State.connected, f.stateOf("a2").?);
    try testing.expect(f.stateOf("a") == null);
    e.reorder(&.{ "c", "zzz" });
    var snap = try e.snapshot(f.alloc);
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 2), snap.conns.len);
    try testing.expectEqualStrings("c", snap.conns[0].name);
    try testing.expectEqualStrings("a2", snap.conns[1].name);
    var list = try e.listProfiles(f.alloc);
    defer list.deinit();
    try testing.expectEqualStrings("c", list.last_profile.?);
}

test "engine: a live connection keeps what it holds; an edit cannot make two share a socket (C-1)" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    const e = try f.start();
    try f.addProfile("a", "me@box", "");
    try f.addProfile("b", "me@box", "");
    try testing.expect(e.connect("a") == null);
    try f.waitState("a", .connected, 8000);
    // edit a's host while connected: the tunnel (and its socket) stay
    try testing.expect(e.saveProfile(.{ .name = "a", .host = "me@other" }, "a") == null);
    {
        var st = (try e.status(f.alloc, "a")).?;
        defer st.deinit();
        try testing.expectEqualStrings("me@box", st.host);
    }
    // so b, on a's old host, is still refused
    try testing.expectEqualStrings("\"a\" is already connected to this host and instance", e.connect("b").?);
    // an interruption retries what a holds, not the edit
    try f.writeFile("remote/drop-tunnel", "");
    try f.waitState("a", .retry, 3000);
    try f.waitState("a", .connected, 8000);
    {
        var st = (try e.status(f.alloc, "a")).?;
        defer st.deinit();
        try testing.expectEqualStrings("me@box", st.host);
    }
    try testing.expectEqualStrings("\"a\" is already connected to this host and instance", e.connect("b").?);
    // reconnect adopts the edit and releases the old host
    try testing.expect(e.reconnect("a") == null);
    try f.waitLog("[a] reconnect requested host=me@other", 3000);
    try f.waitState("a", .connected, 8000);
    try testing.expect(e.connect("b") == null);
    try f.waitState("b", .connected, 8000);
    var sa = (try e.status(f.alloc, "a")).?;
    defer sa.deinit();
    var sb = (try e.status(f.alloc, "b")).?;
    defer sb.deinit();
    try testing.expect(!std.mem.eql(u8, sa.socket_path.?, sb.socket_path.?));
    // and a reconnect onto a host another connection holds is refused
    try testing.expect(e.saveProfile(.{ .name = "a", .host = "me@box" }, "a") == null);
    try testing.expectEqualStrings("\"b\" is already connected to this host and instance", e.reconnect("a").?);
    // a failed connection holds nothing
    e.disconnect("b");
    try testing.expect(e.saveProfile(.{ .name = "b", .host = "badhost" }, "b") == null);
    try testing.expect(e.connect("b") == null);
    try f.waitState("b", .failed, 5000);
    try testing.expect(e.saveProfile(.{ .name = "b", .host = "me@third" }, "b") == null);
    try testing.expect(e.saveProfile(.{ .name = "c", .host = "badhost" }, null) == null);
    try testing.expect(e.connect("c") == null);
}

test "engine: a broken config.json is kept aside, logged, never overwritten (C-3)" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try util.makePath(io, try f.pathTmp("config/webmux-gtk"), 0o700);
    try f.writeFile("config/webmux-gtk/config.json", "{\"profiles\":[{\"name\":\"keepme\",\"host\":\"h\"}],,,\n");
    const e = try f.start();
    try testing.expect(e.configProblem() != null);
    try testing.expect(std.mem.indexOf(u8, e.configProblem().?, "config.json.broken-") != null);
    try testing.expect(f.logHas("config.json unreadable error=\"not valid JSON\""));
    var list = try e.listProfiles(f.alloc);
    list.deinit();
    try f.addProfile("n1", "h", "");
    // the original text survives next to the new file
    var dir = try Io.Dir.cwd().openDir(io, try f.pathTmp("config/webmux-gtk"), .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var aside: ?[]u8 = null;
    defer if (aside) |x| f.alloc.free(x);
    while (try it.next(io)) |ent| if (std.mem.startsWith(u8, ent.name, "config.json.broken-")) {
        aside = try std.fmt.allocPrint(f.alloc, "config/webmux-gtk/{s}", .{ent.name});
    };
    const old = try f.read(aside.?);
    defer f.alloc.free(old);
    try testing.expect(std.mem.indexOf(u8, old, "keepme") != null);
    const cur = try f.read("config/webmux-gtk/config.json");
    defer f.alloc.free(cur);
    try testing.expect(std.mem.indexOf(u8, cur, "n1") != null);
}

test "engine: out-of-range port refused at connect; a too-long runtime dir parks with a reason (C-6, C-8)" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    _ = try f.buildPayload("v1");
    try util.makePath(io, try f.pathTmp("config/webmux-gtk"), 0o700);
    try f.writeFile("config/webmux-gtk/config.json", "{\"profiles\":[{\"name\":\"p\",\"host\":\"me@box\",\"sshPort\":99999}]}\n");
    // (the hand-edited port is repaired at load, see the repair test)
    // a runtime dir long enough that no socket path fits in 107 bytes
    const long = try std.fmt.allocPrint(f.alloc, "{s}/run/{s}", .{ f.root, "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" });
    defer f.alloc.free(long);
    try util.makePath(io, long, 0o700);
    try f.env.put("XDG_RUNTIME_DIR", long);
    const e = try f.start();
    try testing.expect(std.mem.indexOf(u8, e.configProblem().?, "is not a port") != null);
    try f.addProfile("q", "me@box", "");
    try testing.expect(e.connect("q") == null);
    try f.waitState("q", .failed, 3000);
    var st = (try e.status(f.alloc, "q")).?;
    defer st.deinit();
    try testing.expectEqualStrings("the runtime directory is too long for a socket path", st.msg);
    try testing.expect(std.mem.indexOf(u8, st.stderr, "limited to 107 bytes") != null);
}

test "engine: config.json with wrong types and shared ids is repaired, reported, kept (N2, N9)" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try util.makePath(io, try f.pathTmp("config/webmux-gtk"), 0o700);
    const orig =
        \\{"profiles":[{"name":"one","host":"hostO","id":"0123456789abcdef"},
        \\ {"name":"two","host":"hostT","id":"0123456789ABCDEF"},
        \\ {"name":"three","host":42,"id":"zz"}, {"name":"one","host":"x"}, 7],
        \\ "lastProfile":5,"settings":{"theme":3,"unfocusedFade":"x"}}
    ;
    try f.writeFile("config/webmux-gtk/config.json", orig);
    const e = try f.start();
    const prob = e.configProblem().?;
    try testing.expect(std.mem.indexOf(u8, prob, "\"one\", \"two\" had the same id") != null);
    try testing.expect(std.mem.indexOf(u8, prob, "before-repair-") != null);
    try testing.expect(f.logHas("config.json repaired repair=\"\\\"three\\\": \\\"host\\\" is not text: cleared\""));
    // the shared id is reported for the keyring and nobody keeps it
    // both spellings: the keyring matches ids exactly
    const dropped = e.droppedPasswordIds();
    try testing.expectEqual(@as(usize, 2), dropped.len);
    // a missing id is reported too
    try testing.expect(f.logHas("\\\"one (2)\\\" has no id: given one"));
    // ids in the kept original still count as referenced (restoring it
    // must find its passwords)
    {
        const refs = try e.referencedIds(f.alloc);
        defer {
            for (refs) |r| f.alloc.free(r);
            f.alloc.free(refs);
        }
        var seen = false;
        for (refs) |r| if (std.mem.eql(u8, r, "0123456789ABCDEF")) {
            seen = true;
        };
        try testing.expect(seen);
    }
    var list = try e.listProfiles(f.alloc);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 4), list.profiles.len);
    for (list.profiles, 0..) |p, i| {
        try testing.expect(profile_mod.validId(p.id));
        try testing.expect(!std.ascii.eqlIgnoreCase(p.id, "0123456789abcdef"));
        for (list.profiles[i + 1 ..]) |q| try testing.expect(!std.ascii.eqlIgnoreCase(p.id, q.id));
    }
    try testing.expectEqualStrings("one (2)", list.profiles[3].name);
    // nothing was written back yet; the original text is kept aside
    const now = try f.read("config/webmux-gtk/config.json");
    defer f.alloc.free(now);
    try testing.expectEqualStrings(orig, now);
    // a new profile never gets an id in use, and an explicit one that is
    // taken is replaced
    try testing.expect(e.saveProfile(.{ .name = "n", .host = "h", .id = list.profiles[0].id }, null) == null);
    var p2 = (try e.getProfile(f.alloc, "n")).?;
    defer p2.deinit(f.alloc);
    try testing.expect(!std.mem.eql(u8, p2.id, list.profiles[0].id));
}

test "store: re-issuing shared ids with an allocator that reuses freed memory at once" {
    // c_allocator hands a freed 16-byte chunk straight back: re-issuing must
    // not compare the new id against the old one's freed bytes (it hung).
    var st = profile_mod.Store.init(std.heap.c_allocator);
    defer st.deinit();
    try st.loadJson(
        \\{"profiles":[{"name":"one","host":"o","id":"0123456789abcdef"},{"name":"two","host":"t","id":"0123456789abcdef"}]}
    , io);
    try testing.expect(!std.mem.eql(u8, st.profiles.items[0].id, st.profiles.items[1].id));
    try testing.expectEqual(@as(usize, 1), st.dropped_ids.items.len);
}

test "restart sessions: restarted, nothing running, never deployed" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const h = try f.buildPayload("v1");
    const e = try f.start();
    // a unique instance name: the pgrep fallback is stubbed anyway
    try f.addProfile("box", "me@box", "wmtest.inst");
    const Done = struct {
        fn n(comptime k: usize) fn (*Fixture) bool {
            return struct {
                fn p(x: *Fixture) bool {
                    x.events.mutex.lockUncancelable(io);
                    defer x.events.mutex.unlock(io);
                    return x.events.restart.items.len >= k;
                }
            }.p;
        }
    };
    // never deployed
    try testing.expect(e.restartSessions("box") == null);
    try f.waitFor(Done.n(1), 5000);
    try testing.expect(!f.events.restart.items[0].ok);
    try testing.expectEqualStrings("webmux has never been deployed to this host", f.events.restart.items[0].msg);
    try testing.expect(f.logHas("[box] restart sessions requested instance=wmtest.inst"));
    try testing.expect(f.logHas("ERROR [box] restart sessions: webmux has never been deployed to this host"));

    // deployed and a pty host running → restarted, via the shipped payload's CLI
    try testing.expect(e.connect("box") == null);
    try f.waitState("box", .connected, 8000);
    try f.writeFile("remote/ptyhost-running", "");
    try testing.expect(e.restartSessions("box") == null);
    try f.waitFor(Done.n(2), 5000);
    try testing.expect(f.events.restart.items[1].ok);
    try testing.expectEqualStrings("sessions restarted — all shells were stopped, fresh ones start on demand", f.events.restart.items[1].msg);
    {
        const hl = try f.read("remote/fake-host.log");
        defer f.alloc.free(hl);
        const want = try std.fmt.allocPrint(f.alloc, "payload/{s}/webmux-host ptyhost --name wmtest.inst shutdown", .{&h});
        defer f.alloc.free(want);
        try testing.expect(std.mem.indexOf(u8, hl, want) != null);
    }
    // nothing running now
    try testing.expect(e.restartSessions("box") == null);
    try f.waitFor(Done.n(3), 5000);
    try testing.expect(f.events.restart.items[2].ok);
    try testing.expectEqualStrings("no sessions were running — nothing to restart", f.events.restart.items[2].msg);
    // unknown profile / bad instance are refused up front
    try testing.expectEqualStrings("no such profile", e.restartSessions("nope").?);
}

test "restart script matches main.js byte for byte" {
    const a = testing.allocator;
    const h = [_][64]u8{@as([64]u8, @splat('a'))};
    const s = try deploy.restartScript(a, "default", &h);
    defer a.free(s);
    // produced by node from main.js restartRemoteSessions with the same inputs
    try testing.expectEqualStrings(
        \\r=no-deploy; for f in $HOME/.webmux/dist/payload/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/webmux-host $(ls -t $HOME/.webmux/dist/payload/*/webmux-host 2>/dev/null); do [ -x "$f" ] || continue; if "$f" ptyhost --name default shutdown; then r=restarted; break; else r=not-running; fi; done; if [ "$r" != restarted ]; then node=$(ls -t $HOME/.webmux/dist/node/*/bin/node 2>/dev/null | head -1); ph=$(ls -t $HOME/.webmux/dist/payload/*/ptyhost.js 2>/dev/null | head -1); if [ -n "$node" ] && [ -n "$ph" ]; then if "$node" "$ph" --name default shutdown; then r=restarted; else r=not-running; fi; fi; fi; if [ "$r" = not-running ]; then pids=$(pgrep -u "$(id -un)" -f "(ptyhost[.]js|webmux-host ptyhost) --name default$" 2>/dev/null); [ -z "$pids" ] && pids=$(pgrep -u "$(id -un)" -f "(ptyhost[.]js|webmux-host ptyhost)$" 2>/dev/null); if [ -n "$pids" ]; then kill $pids && r=stale-killed; fi; fi; echo "@@result $r"
    , s);
    const s2 = try deploy.restartScript(a, "a.b", &.{});
    defer a.free(s2);
    try testing.expect(std.mem.indexOf(u8, s2, "--name a[.]b$") != null);
    try testing.expect(std.mem.indexOf(u8, s2, "[ -z \"$pids\" ]") == null); // the default-only fallback
}

// ---------------------------------------------------------------------------
// End to end with the real host binary (skipped without socat / payloads)
// ---------------------------------------------------------------------------

/// A minimal liveness probe: `GET /` over the unix socket, any HTTP status
/// line within the timeout counts (what main.js's probe accepts).
fn httpProbe(socket_path: []const u8, timeout_ms: u32) bool {
    const c = std.c;
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return false;
    util.writeAllFd(fd, "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n") catch return false;
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, @intCast(timeout_ms)) catch return false;
    if (n == 0) return false;
    var buf: [16]u8 = undefined;
    const got = c.read(fd, &buf, buf.len);
    return got >= 5 and std.mem.eql(u8, buf[0..5], "HTTP/");
}

fn findInPath(a: Allocator, env: *const std.process.Environ.Map, prog: []const u8) ?[]u8 {
    var it = std.mem.splitScalar(u8, env.get("PATH") orelse return null, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = std.fs.path.join(a, &.{ dir, prog }) catch return null;
        if (util.fileExists(p)) return p;
        a.free(p);
    }
    return null;
}

test "end to end: real webmux-host payload, real tunnel relay, real HTTP probe" {
    const f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const socat = findInPath(f.alloc, &f.env, "socat") orelse return error.SkipZigTest;
    defer f.alloc.free(socat);
    // the checkout's electron/payload, found the way the engine finds it
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", f.alloc);
    defer f.alloc.free(cwd);
    var empty = std.process.Environ.Map.init(f.alloc);
    defer empty.deinit();
    const payload = (try @import("paths.zig").findPayloadDir(f.alloc, io, &empty, cwd)) orelse return error.SkipZigTest;
    defer f.alloc.free(payload);
    var hash: [64]u8 = undefined;
    if (!deploy.manifestHash(f.alloc, io, payload, "linux-x64", &hash)) return error.SkipZigTest;
    if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;

    try f.env.put("WEBMUX_PAYLOAD_DIR", payload);
    try f.env.put("FAKE_SOCAT", socat);
    f.real_probe = true;
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const inst = try std.fmt.allocPrint(f.alloc, "wmct{x}", .{std.mem.readInt(u32, &rnd, .little)});
    defer f.alloc.free(inst);
    defer {
        // stop the real server and pty host we started under the fake HOME
        const script = std.fmt.allocPrint(f.alloc,
            \\R="{s}/remote"; export HOME="$R" XDG_RUNTIME_DIR="{s}/rrun" TMPDIR="{s}/rrun"
            \\"$R/.webmux/dist/payload/{s}/webmux-host" ptyhost --name {s} shutdown >/dev/null 2>&1
            \\pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$R/.webmux/{s}.json" 2>/dev/null)
            \\[ -n "$pid" ] && kill $pid 2>/dev/null
            \\sleep 0.3; pkill -f "$R/[.]webmux/" 2>/dev/null; true
        , .{ f.root, f.root, f.root, &hash, inst, inst }) catch unreachable;
        defer f.alloc.free(script);
        f.sh(script) catch {};
    }

    const e = try f.start();
    try testing.expectEqualStrings(payload, e.payloadDir().?);
    try f.addProfile("real", "me@localbox", inst);
    try testing.expect(e.connect("real") == null);
    try f.waitState("real", .connected, 20000);
    var st = (try e.status(f.alloc, "real")).?;
    defer st.deinit();
    // the starter's advertised socket, forwarded to our local unix socket
    const want_remote = try std.fmt.allocPrint(f.alloc, "{s}/rrun/webmux/{s}.http.sock", .{ f.root, inst });
    defer f.alloc.free(want_remote);
    try testing.expectEqualStrings(want_remote, st.remote_socket.?);
    try testing.expect(httpProbe(st.socket_path.?, 2000));
    try testing.expect(f.logHas("deploy done: server started"));
    // reconnect reuses the running server (same payload)
    try testing.expect(e.reconnect("real") == null);
    try f.waitLog("deploy done: server reuse", 20000);
    try f.waitLogCount("probe: server answered through the tunnel", 2, 20000);
    try f.waitState("real", .connected, 20000);
    // Restart Sessions against the real CLI
    try testing.expect(e.restartSessions("real") == null);
    try f.waitFor(struct {
        fn p(x: *Fixture) bool {
            x.events.mutex.lockUncancelable(io);
            defer x.events.mutex.unlock(io);
            return x.events.restart.items.len >= 1;
        }
    }.p, 20000);
    try testing.expect(f.events.restart.items[0].ok);
}
