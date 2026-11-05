//! webmux connection engine: everything between "the user clicked Connect
//! on a profile" and "there is a live tunnel to the host's HTTP socket, and
//! it stays live". The port of electron/main.js's profile store and
//! connections section, electron/deploy.js and electron/log.js. No GTK.
//!
//! Threading (docs/native-client.md › Rules 4): every `Engine` method is a
//! non-blocking call meant for the GTK main thread (it may do a small file
//! write, e.g. saving config.json, but never waits on the network or a
//! child process). Each connection runs its own supervisor thread; state
//! changes, deploy progress and Restart Sessions results arrive through
//! `Options.listener`, and log entries through `Engine.subscribeLog`, both
//! invoked **on engine threads** — the shell marshals them to the main loop
//! (e.g. g_idle_add) and must not block in them. Callbacks are invoked with
//! no engine lock held, so they may call any `Engine` query.
//!
//! The process must ignore SIGPIPE (Ghostty's global init already does);
//! the supervisor threads also block it for themselves.
//!
//! Everything the Electron connection UI shows is queryable: `snapshot` /
//! `status` give per-connection state, the status message, ssh's stderr
//! tail, the deploy step and push progress, the retry delay and deadline,
//! and the local socket path once connected.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

const engine_impl = @import("conn/engine.zig");
pub const profile = @import("conn/profile.zig");
pub const Log = @import("conn/log.zig");
pub const deploy = @import("conn/deploy.zig");
pub const ssh = @import("conn/ssh.zig");
pub const paths = @import("conn/paths.zig");

pub const Profile = profile.Profile;
pub const ProfileInput = profile.ProfileInput;
pub const Settings = profile.Settings;
pub const SettingsPatch = profile.SettingsPatch;

/// main.js's per-host key (`webmux://<slug>/` without the scheme):
/// lowercased host with runs of `[^a-z0-9-]` turned into `-`, plus `-` and
/// the first 8 hex chars of sha256(`host\ninstance`). Per-host files
/// (tunnel socket, layout state) are named by it.
pub const hostSlug = profile.hostSlug;

/// main.js's instance-name rule: blank or `[A-Za-z0-9._-]+`.
pub const validInstance = profile.validInstance;

// ---------------------------------------------------------------------------
// Timing: main.js's constants (overridable for tests only)
// ---------------------------------------------------------------------------

pub const Timing = struct {
    /// ms per liveness request (PROBE_TIMEOUT)
    probe_timeout_ms: u32 = 2000,
    /// ms between probes once connected (PROBE_INTERVAL)
    probe_interval_ms: u32 = 5000,
    /// ms between probes before the server first answers (PROBE_RETRY)
    probe_retry_ms: u32 = 500,
    /// consecutive misses while connected → the tunnel is dead (PROBE_MISSES)
    probe_misses: u32 = 3,
    /// ms for a fresh tunnel to reach the server at all (PROBE_FIRST_ANSWER)
    probe_first_answer_ms: u32 = 20000,
    /// auto-retry backoff: doubles from min to max (scheduleRetry)
    retry_min_ms: u32 = 1000,
    retry_max_ms: u32 = 15000,
    /// Restart Sessions' ssh is killed after this long
    restart_timeout_ms: u32 = 30000,
    /// SIGTERM → SIGKILL grace when killing an ssh child
    kill_grace_ms: u32 = 2000,
};

// ---------------------------------------------------------------------------
// Injected dependencies
// ---------------------------------------------------------------------------

/// Liveness probe through the tunnel: `GET /` on the local unix socket,
/// true if the server answered (any HTTP status) within `timeout_ms`. On a
/// miss, `why` may be set to a short static reason (an error name) for the
/// `probe missed` log line. Called on the supervisor thread; may block up
/// to the timeout.
pub const ProbeFn = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, socket_path: []const u8, timeout_ms: u32, why: *[]const u8) bool,
};

pub const PasswordLookup = union(enum) {
    /// No saved password: key-only auth (BatchMode=yes).
    none,
    /// The password was written to the front of the buffer; this is its
    /// length. The engine zeroes the buffer after use.
    found: usize,
    /// The keyring refused (locked, unavailable). The connection parks as
    /// failed with main.js's "could not be decrypted" message; the text
    /// here is logged.
    unavailable: []const u8,
};

/// Password provider (the shell backs it with libsecret, keyed by
/// `profile_id`). Called on engine threads before every ssh spawn for a
/// profile (each connect attempt, each Restart Sessions); may block. The
/// password goes only into the ssh child's environment for the askpass
/// helper — never into argv, a log line or an error string.
pub const PasswordFn = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, profile_id: []const u8, profile_name: []const u8, out: []u8) PasswordLookup,
    /// Whether a password is saved for the profile, as far as the provider
    /// knows without asking the keyring (for the `connect requested`
    /// line's `auth` field: main.js logs whether one is stored, not whether
    /// it could be read). Main or engine thread; must not block.
    has: ?*const fn (ctx: ?*anyopaque, profile_id: []const u8) bool = null,
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// main.js's connection states. (`degraded` is not here: it is the shell's
/// own verdict, connected-but-sockets-down, as in main.js `snapshot`.)
pub const State = enum {
    /// deploying or waiting for the server to first answer through a fresh
    /// tunnel
    connecting,
    /// the server answered through the tunnel
    connected,
    /// an established connection was interrupted; retrying after a delay
    retry,
    /// parked: a connect that never got through, or a keyring refusal; no
    /// background retry until the user acts
    failed,
};

/// What the supervisor is doing right now (finer than `State`).
pub const Step = enum {
    idle,
    /// deploy: `probing host…`
    probing,
    /// deploy: streaming the payload (see push_sent / push_total)
    pushing,
    /// deploy: `starting server…`
    starting,
    /// tunnel spawned, probing through it
    tunnel,
    /// waiting out a retry delay
    waiting_retry,
};

/// A connection's status. From `snapshot`/`status` it is an owned copy
/// (free with `deinit`); inside a listener callback it is borrowed and
/// valid only during the call.
pub const Status = struct {
    /// profile name (follows renames)
    name: []const u8,
    state: State,
    /// main.js status `msg`: "ssh <host>", deploy progress lines,
    /// "ssh exited (255)", "connection failed", … (empty when connected)
    msg: []const u8,
    /// the last 8 lines of ssh stderr and deploy/probe diagnostics, joined
    /// with '\n' (main.js `stderr`)
    stderr: []const u8,
    step: Step,
    /// push progress in bytes (step == .pushing)
    push_sent: u64 = 0,
    push_total: u64 = 0,
    /// retry state: delay in seconds as main.js reports it, and the
    /// monotonic deadline (`Engine.nowMs` clock); 0 when not retrying
    retry_delay_s: u32 = 0,
    retry_at_ms: i64 = 0,
    /// local tunnel socket, set while connected (null otherwise)
    socket_path: ?[]const u8 = null,
    /// the remote server's advertised socket (last successful deploy)
    remote_socket: ?[]const u8 = null,
    host: []const u8,
    instance: []const u8,
    /// the port of the profile this connect cycle uses (0 = ssh default);
    /// with `host` and `instance`: what the connection is on, which may
    /// differ from the stored profile after an edit (until Reconnect)
    ssh_port: u32 = 0,
    /// this connect-cycle reached connected at least once (drops retry)
    had_connection: bool = false,
    tunnel_pid: ?i32 = null,
    /// set on owned copies from `status`
    arena: ?*std.heap.ArenaAllocator = null,

    /// ms left on the retry countdown at monotonic time `now_ms`.
    pub fn retryRemainingMs(s: *const Status, now_ms: i64) i64 {
        if (s.state != .retry or s.retry_at_ms == 0) return 0;
        return @max(0, s.retry_at_ms - now_ms);
    }

    pub fn deinit(s: *Status) void {
        if (s.arena) |a| {
            const child = a.child_allocator;
            a.deinit();
            child.destroy(a);
        }
    }
};

/// A list of statuses in pill order (owned).
pub const Snapshot = struct {
    conns: []Status,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(s: *Snapshot) void {
        const child = s.arena.child_allocator;
        s.arena.deinit();
        child.destroy(s.arena);
    }
};

pub const RestartResult = struct {
    name: []const u8,
    ok: bool,
    /// user-facing outcome ("sessions restarted — …") or error text
    msg: []const u8,
};

pub const Event = union(enum) {
    /// a connection's status changed (state, message, progress, countdown
    /// start, stderr)
    status: *const Status,
    /// a disconnected connection finished tearing down (its thread exited)
    removed: []const u8,
    /// Restart Sessions finished; on `ok` a live connection's panes refer to
    /// sessions that no longer exist (main.js reloads the page)
    restart_done: *const RestartResult,
    /// the client-wide settings changed
    settings: *const Settings,
};

pub const Listener = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, event: *const Event) void,
};

pub const Options = struct {
    /// Base environment: XDG/HOME resolution, WEBMUX_PAYLOAD_DIR, and the
    /// environment of every ssh child. Cloned.
    env: *const EnvMap,
    /// The executable's directory for the payload lookup (default: the
    /// running executable's).
    exe_dir: ?[]const u8 = null,
    /// The ssh program (PATH-resolved when it has no '/').
    ssh_path: []const u8 = "ssh",
    probe: ProbeFn,
    password: ?PasswordFn = null,
    listener: ?Listener = null,
    timing: Timing = .{},
    /// For the "client started" log line.
    version: []const u8 = "",
    /// Which keyring backs the password provider, for the "client started"
    /// log line (main.js logs safeStorage's backend).
    password_store: ?[]const u8 = null,
};

/// A profile as listed for the UI (owned copy).
pub const ProfileList = struct {
    profiles: []Profile,
    last_profile: ?[]const u8,
    /// path of config.json
    file: []const u8,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(s: *ProfileList) void {
        const child = s.arena.child_allocator;
        s.arena.deinit();
        child.destroy(s.arena);
    }
};

/// Operation outcome for UI calls: null = ok, else a user-facing error
/// (static or in the engine's per-call buffer; copy it before the next
/// call on the same thread).
pub const Result = ?[]const u8;

// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------

pub const Engine = struct {
    impl: *engine_impl.Engine,

    /// Load config.json, open the log file, write the askpass helper, log
    /// "client started". No connection is started (connecting is the
    /// user's call).
    pub fn init(alloc: Allocator, io: std.Io, opts: Options) !Engine {
        return .{ .impl = try engine_impl.Engine.create(alloc, io, opts) };
    }

    /// Quit: log "client quitting", stop every connection (kills its ssh
    /// children) and wait for all engine threads.
    pub fn deinit(self: Engine) void {
        self.impl.destroy();
    }

    // -- profiles (main.js profiles:*) ---------------------------------

    /// Profiles in store order, lastProfile, and the config file path.
    pub fn listProfiles(self: Engine, alloc: Allocator) !ProfileList {
        return self.impl.listProfiles(alloc);
    }

    /// profiles:save: trim, validate (instance rule, name+host required,
    /// unique name), insert or replace (`original_name` = the profile being
    /// edited, null for new), carry over id and downloadDir, follow a
    /// rename into lastProfile and a live connection (which keeps its
    /// tunnel; new fields apply from its next attempt), save atomically.
    pub fn saveProfile(self: Engine, input: ProfileInput, original_name: ?[]const u8) Result {
        return self.impl.saveProfile(input, original_name);
    }

    /// profiles:delete: remove, clear lastProfile if it was this one,
    /// disconnect it ('profile deleted'), save.
    pub fn deleteProfile(self: Engine, name: []const u8) Result {
        return self.impl.deleteProfile(name);
    }

    /// The download hook: remember where this profile last saved a file.
    pub fn setDownloadDir(self: Engine, name: []const u8, dir: []const u8) Result {
        return self.impl.setDownloadDir(name, dir);
    }

    /// A copy of one profile (owned by `alloc`; free with Profile.deinit).
    pub fn getProfile(self: Engine, alloc: Allocator, name: []const u8) !?Profile {
        return self.impl.getProfile(alloc, name);
    }

    // -- settings ------------------------------------------------------

    pub fn settings(self: Engine) Settings {
        return self.impl.getSettings();
    }

    /// Merge a partial update (sanitized like main.js), save, and emit a
    /// `.settings` event. Returns the new settings.
    pub fn updateSettings(self: Engine, patch: SettingsPatch) Settings {
        return self.impl.updateSettings(patch);
    }

    // -- connections ---------------------------------------------------

    /// profiles:connect: start (or restart) the connection for a profile.
    /// A connection that is already connected is left alone. Records
    /// lastProfile. Errors: "no such profile", an invalid instance, or the
    /// host+instance already in use by another live connection.
    pub fn connect(self: Engine, name: []const u8) Result {
        return self.impl.connect(name, "connect");
    }

    /// Reconnect (⌘⇧R): re-read the profile and restart the connect cycle,
    /// whatever its state.
    pub fn reconnect(self: Engine, name: []const u8) Result {
        return self.impl.reconnect(name);
    }

    /// conns:disconnect: stop the connection and forget it. Returns at
    /// once; the connection vanishes from `snapshot` immediately and a
    /// `.removed` event follows when its ssh children are gone.
    pub fn disconnect(self: Engine, name: []const u8) void {
        self.impl.disconnect(name, "user");
    }

    /// Wake from suspend: kill every live tunnel (they are dead but don't
    /// know it yet) so reconnection starts now; the exit path decides what
    /// follows (auto-retry only if the cycle was ever connected).
    pub fn notifyResume(self: Engine) void {
        self.impl.notifyResume();
    }

    /// conns:reorder: new pill order; unknown names are ignored, missing
    /// ones keep their relative order at the end.
    pub fn reorder(self: Engine, names: []const []const u8) void {
        self.impl.reorder(names);
    }

    /// Every connection's status in pill order.
    pub fn snapshot(self: Engine, alloc: Allocator) !Snapshot {
        return self.impl.snapshot(alloc);
    }

    /// One connection's status, or null if it has none.
    pub fn status(self: Engine, alloc: Allocator, name: []const u8) !?Status {
        return self.impl.status(alloc, name);
    }

    /// The monotonic clock `Status.retry_at_ms` is on.
    pub fn nowMs(self: Engine) i64 {
        return self.impl.nowMs();
    }

    /// profiles:restart-sessions: shut down the profile's remote pty host
    /// over a one-off ssh (every shell in it dies). Runs on a worker
    /// thread; the outcome arrives as a `.restart_done` event and in the
    /// log. Errors returned here: "no such profile", invalid instance.
    pub fn restartSessions(self: Engine, name: []const u8) Result {
        return self.impl.restartSessions(name);
    }

    // -- log -----------------------------------------------------------

    /// The connection log (ring + file). Use it to push entries from the
    /// shell (e.g. pane socket events with `src = .page`), read the ring
    /// (`since`), clear it, or find the file (`filePath`).
    pub fn log(self: Engine) *Log {
        return self.impl.log;
    }

    /// Live log tail; the callback runs on the pushing thread.
    pub fn subscribeLog(self: Engine, sub: Log.Subscriber) !u64 {
        return self.impl.log.subscribe(sub);
    }

    pub fn unsubscribeLog(self: Engine, id: u64) void {
        self.impl.log.unsubscribe(id);
    }

    /// Path of config.json (for "Open Config File").
    pub fn configPath(self: Engine) []const u8 {
        return self.impl.config_path;
    }

    /// If config.json existed but could not be read or parsed at startup:
    /// a user-facing sentence saying so and where the file was kept aside
    /// (it is never overwritten). Null when the config loaded fine.
    pub fn configProblem(self: Engine) ?[]const u8 {
        return self.impl.config_problem;
    }

    /// Every profile id a stored secret may still belong to (profiles,
    /// and ids in config files kept aside). Owned by `alloc`.
    pub fn referencedIds(self: Engine, alloc: Allocator) ![][]u8 {
        return self.impl.referencedIds(alloc);
    }

    /// Profile ids that config.json gave to more than one profile (they
    /// were re-issued at load): the shell must forget the secrets stored
    /// under them.
    pub fn droppedPasswordIds(self: Engine) []const []const u8 {
        return self.impl.droppedPasswordIds();
    }

    /// The checks `saveProfile` makes, without saving (so the shell can
    /// store a password first and reject the whole save if that fails).
    pub fn validateProfile(self: Engine, input: ProfileInput, original_name: ?[]const u8) Result {
        return self.impl.validateProfile(input, original_name);
    }

    /// A fresh profile id (16 hex chars) for `ProfileInput.id`.
    pub fn newProfileId(self: Engine, out: *[16]u8) void {
        self.impl.newProfileId(out);
    }

    /// Directory for per-host state files (`<state>/webmux-gtk`); the
    /// layout package puts `layout/<host-slug>.json` under it.
    pub fn stateDir(self: Engine) []const u8 {
        return self.impl.paths.state_dir;
    }

    /// The payload directory found at startup, or null.
    pub fn payloadDir(self: Engine) ?[]const u8 {
        return self.impl.paths.payload_dir;
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("conn/log.zig"));
    std.testing.refAllDecls(@import("conn/util.zig"));
    std.testing.refAllDecls(@import("conn/profile.zig"));
    std.testing.refAllDecls(@import("conn/paths.zig"));
    std.testing.refAllDecls(@import("conn/ssh.zig"));
    std.testing.refAllDecls(@import("conn/proc.zig"));
    std.testing.refAllDecls(@import("conn/deploy.zig"));
    std.testing.refAllDecls(@import("conn/engine.zig"));
    std.testing.refAllDecls(@import("conn/supervisor.zig"));
    _ = @import("conn/test.zig");
}
