//! Engine internals: the store, the connection list (pill order), the log,
//! and the operations the UI invokes (main.js's IPC section).
//!
//! Locking: `mutex` guards the store and the connection lists. Each
//! connection has its own mutex; lock order is engine → connection, and no
//! callback is ever invoked with a lock held.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

const api = @import("../conn.zig");
const Log = @import("log.zig");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const Store = profile_mod.Store;
const paths_mod = @import("paths.zig");
const util = @import("util.zig");
const ssh = @import("ssh.zig");
const proc = @import("proc.zig");
const deploy = @import("deploy.zig");
const Conn = @import("supervisor.zig").Conn;

pub const Engine = struct {
    alloc: Allocator,
    io: Io,
    env: EnvMap,
    paths: paths_mod.Paths,
    config_path: []u8,
    askpass_path: []u8,
    log: *Log,
    ssh_path: []u8,
    exe_dir: ?[]u8,
    probe: api.ProbeFn,
    password: ?api.PasswordFn,
    listener: ?api.Listener,
    timing: api.Timing,

    mutex: Io.Mutex = .init,
    store: Store,
    conns: std.ArrayList(*Conn) = .empty,
    /// disconnected connections whose threads may still be tearing down
    dying: std.ArrayList(*Conn) = .empty,
    /// Restart Sessions workers
    workers: std.ArrayList(*Worker) = .empty,
    quit_pipe: proc.WakePipe,
    quitting: std.atomic.Value(bool) = .init(false),

    /// per-call error message buffer (main thread)
    err_buf: [256]u8 = undefined,
    /// set when config.json could not be read or parsed (see configProblem)
    config_problem: ?[]u8 = null,
    /// a broken config.json was moved here; never written by us
    config_aside: ?[]u8 = null,

    pub fn create(alloc: Allocator, io: Io, opts: api.Options) !*Engine {
        const self = try alloc.create(Engine);
        errdefer alloc.destroy(self);
        var env = try opts.env.clone(alloc);
        errdefer env.deinit();
        const p = try paths_mod.resolve(alloc, io, &env, opts.exe_dir);
        errdefer p.deinit(alloc);
        const config_path = try p.configFile(alloc);
        errdefer alloc.free(config_path);
        const log = try Log.init(alloc, io);
        errdefer log.deinit();
        const log_dir = try p.logDir(alloc);
        defer alloc.free(log_dir);
        log.initFile(log_dir) catch {};
        util.makePath(io, p.runtime_dir, 0o700) catch {};
        util.ensurePrivateDir(p.runtime_dir) catch |e| {
            log.err(null, "runtime dir is not a private directory of ours — refusing to use it", &.{
                .{ .key = "dir", .value = .{ .str = p.runtime_dir } },
                .{ .key = "error", .value = .{ .str = @errorName(e) } },
            });
            return error.RuntimeDirNotPrivate;
        };
        const askpass_path = ssh.ensureAskpass(alloc, io, p.runtime_dir) catch try std.fs.path.join(alloc, &.{ p.runtime_dir, "askpass.sh" });
        errdefer alloc.free(askpass_path);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .env = env,
            .paths = p,
            .config_path = config_path,
            .askpass_path = askpass_path,
            .log = log,
            .ssh_path = try alloc.dupe(u8, opts.ssh_path),
            .exe_dir = if (opts.exe_dir) |d| try alloc.dupe(u8, d) else null,
            .probe = opts.probe,
            .password = opts.password,
            .listener = opts.listener,
            .timing = opts.timing,
            .store = Store.init(alloc),
            .quit_pipe = try proc.WakePipe.init(),
        };
        log.info(null, "client started", &.{
            .{ .key = "version", .value = .{ .str = opts.version } },
            .{ .key = "platform", .value = .{ .str = "linux-" ++ @tagName(@import("builtin").cpu.arch) } },
            .{ .key = "passwordStore", .value = if (opts.password_store) |s| .{ .str = s } else .null },
            .{ .key = "logFile", .value = if (log.filePath()) |f| .{ .str = f } else .null },
        });
        self.loadStore();
        return self;
    }

    /// Load config.json. A file that exists but cannot be read or parsed is
    /// never overwritten: it is renamed to `config.json.broken-<time>` (or,
    /// if even that fails, the engine refuses to save until restarted),
    /// the store starts empty, and the problem is logged and kept for the
    /// UI (`configProblem`). main.js only printed `config.json unreadable`
    /// and then overwrote the file on the next save.
    fn loadStore(self: *Engine) void {
        const bytes = util.readFileAlloc(self.io, self.alloc, self.config_path, 16 << 20) catch |e| {
            self.configBroken(@errorName(e));
            return;
        } orelse return;
        defer self.alloc.free(bytes);
        self.store.loadJson(bytes, self.io) catch |e| switch (e) {
            error.OutOfMemory => self.configBroken("out of memory"),
            else => {
                // Whatever was parsed so far is dropped with the file.
                self.store.deinit();
                self.store = Store.init(self.alloc);
                self.configBroken("not valid JSON");
            },
        };
        if (self.config_problem == null and self.store.repairs.items.len > 0) self.configRepaired(bytes);
    }

    /// The file parsed but had values of the wrong type or shape: they are
    /// repaired in memory, reported (log and `configProblem`), and the
    /// original text is kept next to it before anything is written back.
    fn configRepaired(self: *Engine, original: []const u8) void {
        var tbuf: [32]u8 = undefined;
        const iso = util.isoNow(self.io, &tbuf);
        var stamp: [24]u8 = undefined;
        var n: usize = 0;
        for (iso) |ch| switch (ch) {
            '0'...'9', 'T', 'Z' => {
                if (n < stamp.len) stamp[n] = ch;
                n += 1;
            },
            '.' => break,
            else => {},
        };
        const copy_path = std.fmt.allocPrint(self.alloc, "{s}.before-repair-{s}Z", .{ self.config_path, stamp[0..@min(n, stamp.len)] }) catch null;
        var kept = false;
        if (copy_path) |cp| kept = if (util.atomicWrite(self.io, cp, original, 0o600)) |_| true else |_| false;
        for (self.store.repairs.items) |r| {
            self.log.warn(null, "config.json repaired", &.{
                .{ .key = "repair", .value = .{ .str = r } },
                .{ .key = "file", .value = .{ .str = self.config_path } },
            });
        }
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.alloc);
        for (self.store.repairs.items, 0..) |r, i| {
            if (i == 5) {
                list.print(self.alloc, "; and {d} more (see the connection log)", .{self.store.repairs.items.len - 5}) catch {};
                break;
            }
            if (i > 0) list.appendSlice(self.alloc, "; ") catch {};
            list.appendSlice(self.alloc, r) catch {};
        }
        self.config_problem = if (kept and copy_path != null)
            std.fmt.allocPrint(self.alloc, "config.json had values that could not be used and were repaired: {s}. The original was kept as {s}; the repaired version is written on the next save", .{ list.items, copy_path.? }) catch null
        else
            std.fmt.allocPrint(self.alloc, "config.json had values that could not be used and were repaired: {s}. The repaired version is written on the next save", .{list.items}) catch null;
        if (copy_path) |cp| {
            if (kept) self.config_aside = cp else self.alloc.free(cp);
        }
        // Saving is allowed: the original text is kept (or could not be,
        // which is reported); config_aside marks that.
        if (self.config_aside == null) self.config_aside = self.alloc.dupe(u8, "") catch null;
    }

    /// Every profile id something may still refer to: the profiles', and
    /// any 16-hex-digit token in a config file kept aside next to
    /// config.json (`.broken-*`, `.before-repair-*`), so restoring one of
    /// them still finds its passwords. Owned by `alloc` (free each, then
    /// the slice).
    pub fn referencedIds(self: *Engine, alloc: Allocator) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |x| alloc.free(x);
            out.deinit(alloc);
        }
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.store.profiles.items) |p| try out.append(alloc, try alloc.dupe(u8, p.id));
        }
        const dir_path = std.fs.path.dirname(self.config_path) orelse return out.toOwnedSlice(alloc);
        const base = std.fs.path.basename(self.config_path);
        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |ent| {
            if (!std.mem.startsWith(u8, ent.name, base) or ent.name.len == base.len) continue;
            const rest = ent.name[base.len..];
            if (!std.mem.startsWith(u8, rest, ".broken-") and !std.mem.startsWith(u8, rest, ".before-repair-")) continue;
            const full = try std.fs.path.join(alloc, &.{ dir_path, ent.name });
            defer alloc.free(full);
            const bytes = (util.readFileAlloc(self.io, alloc, full, 16 << 20) catch continue) orelse continue;
            defer alloc.free(bytes);
            var i: usize = 0;
            while (i < bytes.len) {
                if (!std.ascii.isHex(bytes[i])) {
                    i += 1;
                    continue;
                }
                var j = i;
                while (j < bytes.len and std.ascii.isHex(bytes[j])) j += 1;
                if (j - i == 16) try out.append(alloc, try alloc.dupe(u8, bytes[i..j]));
                i = j;
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// Ids that several profiles shared in config.json; the secret stored
    /// under each must never be offered again (deviation 7: one id, one
    /// profile).
    pub fn droppedPasswordIds(self: *Engine) []const []const u8 {
        return @ptrCast(self.store.dropped_ids.items);
    }

    fn configBroken(self: *Engine, why: []const u8) void {
        var tbuf: [32]u8 = undefined;
        const iso = util.isoNow(self.io, &tbuf);
        // 2026-11-04T12:34:56.789Z → 20261104T123456Z (no ':' in file names)
        var stamp: [24]u8 = undefined;
        var n: usize = 0;
        for (iso) |ch| switch (ch) {
            '0'...'9', 'T', 'Z' => {
                if (n < stamp.len) stamp[n] = ch;
                n += 1;
            },
            '.' => break,
            else => {},
        };
        const aside = std.fmt.allocPrint(self.alloc, "{s}.broken-{s}Z", .{ self.config_path, stamp[0..@min(n, stamp.len)] }) catch null;
        var kept: ?[]const u8 = null;
        if (aside) |a| {
            const zf = self.alloc.dupeSentinel(u8, self.config_path, 0) catch null;
            const zt = self.alloc.dupeSentinel(u8, a, 0) catch null;
            if (zf != null and zt != null and std.c.rename(zf.?.ptr, zt.?.ptr) == 0) kept = a;
            if (zf) |z| self.alloc.free(z);
            if (zt) |z| self.alloc.free(z);
        }
        if (kept) |k| {
            self.config_aside = @constCast(k);
        } else if (aside) |a| self.alloc.free(a);
        self.config_problem = if (kept) |k|
            std.fmt.allocPrint(self.alloc, "config.json could not be read ({s}); it was kept as {s} and the profile list starts empty", .{ why, k }) catch null
        else
            std.fmt.allocPrint(self.alloc, "config.json could not be read ({s}) and could not be moved aside; nothing will be saved until it is fixed or removed", .{why}) catch null;
        self.log.err(null, "config.json unreadable", &.{
            .{ .key = "error", .value = .{ .str = why } },
            .{ .key = "file", .value = .{ .str = self.config_path } },
            .{ .key = "keptAs", .value = if (kept) |k| .{ .str = k } else .null },
        });
    }

    /// Caller holds `mutex`.
    fn saveStore(self: *Engine) ?[]const u8 {
        // A broken config.json that could not be moved aside is never
        // overwritten.
        if (self.config_problem != null and self.config_aside == null) return "config.json is unreadable and was not overwritten — fix or remove it, then restart";
        const json = self.store.toJson(self.alloc) catch return "out of memory";
        defer self.alloc.free(json);
        util.makePath(self.io, self.paths.config_dir, 0o700) catch {};
        util.atomicWrite(self.io, self.config_path, json, 0o600) catch |e| {
            return std.fmt.bufPrint(&self.err_buf, "could not save {s}: {s}", .{ self.config_path, @errorName(e) }) catch "could not save config.json";
        };
        return null;
    }

    pub fn destroy(self: *Engine) void {
        self.quitting.store(true, .release);
        self.quit_pipe.wake();
        const alloc = self.alloc;
        var live: std.ArrayList(*Conn) = .empty;
        defer live.deinit(alloc);
        var n_conns: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            n_conns = self.conns.items.len;
        }
        self.log.info(null, "client quitting", &.{.{ .key = "connections", .value = .{ .int = @intCast(n_conns) } }});
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            live.appendSlice(self.alloc, self.conns.items) catch {};
            live.appendSlice(self.alloc, self.dying.items) catch {};
            self.conns.clearRetainingCapacity();
            self.dying.clearRetainingCapacity();
        }
        for (live.items) |c| c.requestQuit();
        for (live.items) |c| {
            c.join();
            c.destroy();
        }
        for (self.workers.items) |w| {
            w.thread.join();
            w.destroy();
        }
        self.workers.deinit(self.alloc);
        self.conns.deinit(self.alloc);
        self.dying.deinit(self.alloc);
        self.store.deinit();
        if (self.config_problem) |x| self.alloc.free(x);
        if (self.config_aside) |x| self.alloc.free(x);
        self.quit_pipe.deinit();
        self.log.deinit();
        self.paths.deinit(self.alloc);
        self.alloc.free(self.config_path);
        self.alloc.free(self.askpass_path);
        self.alloc.free(self.ssh_path);
        if (self.exe_dir) |d| self.alloc.free(d);
        self.env.deinit();
        self.alloc.destroy(self);
    }

    pub fn nowMs(self: *Engine) i64 {
        return util.monoMs(self.io);
    }

    pub fn emit(self: *Engine, ev: *const api.Event) void {
        if (self.listener) |l| l.func(l.ctx, ev);
    }

    /// Join and free connections whose teardown finished. Caller holds mutex.
    fn reap(self: *Engine) void {
        var i: usize = 0;
        while (i < self.dying.items.len) {
            const c = self.dying.items[i];
            if (c.isFinished()) {
                _ = self.dying.swapRemove(i);
                c.join();
                c.destroy();
            } else i += 1;
        }
        i = 0;
        while (i < self.workers.items.len) {
            const w = self.workers.items[i];
            if (w.done.load(.acquire)) {
                _ = self.workers.swapRemove(i);
                w.thread.join();
                w.destroy();
            } else i += 1;
        }
    }

    fn findConn(self: *Engine, name: []const u8) ?*Conn {
        for (self.conns.items) |c| if (c.nameIs(name)) return c;
        return null;
    }

    // -- profiles ------------------------------------------------------

    pub fn listProfiles(self: *Engine, alloc: Allocator) !api.ProfileList {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = .init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const a = arena.allocator();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const list = try a.alloc(Profile, self.store.profiles.items.len);
        for (self.store.profiles.items, list) |p, *dst| dst.* = try p.clone(a);
        return .{
            .profiles = list,
            .last_profile = if (self.store.last_profile) |l| try a.dupe(u8, l) else null,
            .file = try a.dupe(u8, self.config_path),
            .arena = arena,
        };
    }

    pub fn getProfile(self: *Engine, alloc: Allocator, name: []const u8) !?Profile {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const p = self.store.find(name) orelse return null;
        return try p.clone(alloc);
    }

    pub fn saveProfile(self: *Engine, input: api.ProfileInput, original_name: ?[]const u8) api.Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reap();
        if (self.store.save(self.io, input, original_name, &self.err_buf) catch return "out of memory") |msg| return msg;
        const name = std.mem.trim(u8, input.name, " \t\r\n");
        const saved = self.store.find(name).?;
        // A live connection for this profile keeps its current tunnel; the
        // new fields take effect on its next attempt.
        if (self.findConn(original_name orelse name)) |c| {
            // Host, port, instance, options apply from the next connect
            // or reconnect, which re-read the store; automatic retries keep
            // what the live tunnel holds (main.js retried with the edited
            // profile on the same local port; here the socket is the
            // host+instance, so a retry must not move it). The name
            // follows at once.
            _ = saved;
            if (original_name) |orig| if (!std.mem.eql(u8, orig, name)) c.rename(name) catch {};
        }
        return self.saveStore();
    }

    pub fn validateProfile(self: *Engine, input: api.ProfileInput, original_name: ?[]const u8) api.Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.validate(input, original_name, &self.err_buf);
    }

    pub fn newProfileId(self: *Engine, out: *[16]u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.store.uniqueId(self.io) catch {
            var raw: [8]u8 = undefined;
            self.io.random(&raw);
            out.* = std.fmt.bytesToHex(raw, .lower);
            return;
        };
        defer self.alloc.free(id);
        @memcpy(out, id[0..16]);
    }

    pub fn deleteProfile(self: *Engine, name: []const u8) api.Result {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.store.delete(name) catch return "out of memory";
        }
        self.disconnect(name, "profile deleted");
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.saveStore();
    }

    pub fn setDownloadDir(self: *Engine, name: []const u8, dir: []const u8) api.Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const p = self.store.find(name) orelse return "no such profile";
        if (std.mem.eql(u8, p.download_dir, dir)) return null;
        const d = self.alloc.dupe(u8, dir) catch return "out of memory";
        self.alloc.free(p.download_dir);
        p.download_dir = d;
        return self.saveStore();
    }

    // -- settings ------------------------------------------------------

    pub fn getSettings(self: *Engine) api.Settings {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.settings;
    }

    pub fn updateSettings(self: *Engine, patch: api.SettingsPatch) api.Settings {
        const s = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.store.settings = profile_mod.sanitizeSettings(self.store.settings, patch);
            _ = self.saveStore();
            break :blk self.store.settings;
        };
        self.emit(&.{ .settings = &s });
        return s;
    }

    // -- connections ---------------------------------------------------

    fn slugOf(p: Profile, buf: []u8) []const u8 {
        return profile_mod.hostSlug(p.host, p.instance, buf) catch "";
    }

    /// Deviation 8: one live connection per host+instance, because they
    /// would share one tunnel socket. A connection is keyed on what it
    /// holds: the host+instance of its current connect cycle (an edit to
    /// its profile applies only from its next connect or reconnect), and
    /// it holds it unless it is parked in `failed` with no tunnel.
    /// Caller holds `mutex`.
    fn slugTaken(self: *Engine, p: Profile, except: ?*Conn) ?[]const u8 {
        var slug_buf: [600]u8 = undefined;
        const slug = slugOf(p, &slug_buf);
        for (self.conns.items) |c| {
            if (c == except) continue;
            if (!c.holdsSocket()) continue;
            var other_buf: [600]u8 = undefined;
            const other = c.slug(&other_buf);
            if (std.mem.eql(u8, other, slug)) {
                var nb: [128]u8 = undefined;
                const other_name = c.copyName(&nb);
                return std.fmt.bufPrint(&self.err_buf, "\"{s}\" is already connected to this host and instance", .{other_name}) catch "another connection already uses this host and instance";
            }
        }
        return null;
    }

    pub fn connect(self: *Engine, name: []const u8, why: []const u8) api.Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reap();
        if (self.quitting.load(.acquire)) return "quitting";
        const p = self.store.find(name) orelse return "no such profile";
        if (p.instance.len > 0 and !profile_mod.validInstance(p.instance)) return "invalid instance name in profile";
        if (!profile_mod.validPort(p.ssh_port)) return profile_mod.PORT_ERROR;
        const existing = self.findConn(name);
        if (existing) |c| if (c.isConnected()) return null; // already connected and healthy
        if (self.slugTaken(p.*, existing)) |msg| return msg;
        const c = existing orelse blk: {
            const nc = Conn.create(self, p.*) catch return "out of memory";
            self.conns.append(self.alloc, nc) catch {
                nc.destroy();
                return "out of memory";
            };
            nc.start() catch {
                _ = self.conns.pop();
                nc.destroy();
                return "could not start the connection thread";
            };
            break :blk nc;
        };
        c.setProfile(p.*) catch return "out of memory";
        self.store.setLastProfile(name) catch {};
        _ = self.saveStore(); // lastProfile
        c.requestConnect(why);
        return null;
    }

    pub fn reconnect(self: *Engine, name: []const u8) api.Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reap();
        const c = self.findConn(name) orelse return "not connected";
        if (self.store.find(name)) |p| {
            if (p.instance.len > 0 and !profile_mod.validInstance(p.instance)) return "invalid instance name in profile";
            if (!profile_mod.validPort(p.ssh_port)) return profile_mod.PORT_ERROR;
            if (self.slugTaken(p.*, c)) |msg| return msg;
            c.setProfile(p.*) catch return "out of memory";
        }
        self.store.setLastProfile(name) catch {};
        _ = self.saveStore();
        c.requestConnect("reconnect");
        return null;
    }

    pub fn disconnect(self: *Engine, name: []const u8, why: []const u8) void {
        const c = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.reap();
            for (self.conns.items, 0..) |c, i| if (c.nameIs(name)) {
                _ = self.conns.orderedRemove(i);
                self.dying.append(self.alloc, c) catch {};
                break :blk c;
            };
            return;
        };
        // Logged unlocked (log subscribers may call back into the engine);
        // `c` stays alive: only its own thread finishing lets reap() free it,
        // and that needs the request below.
        var buf: [16]u8 = undefined;
        self.log.atf(.info, name, &.{.{ .key = "state", .value = .{ .str = c.stateName(&buf) } }}, "disconnecting ({s})", .{why});
        c.requestDisconnect(why);
    }

    pub fn notifyResume(self: *Engine) void {
        var n: i64 = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.conns.items) |c| if (c.hasTunnel()) {
                n += 1;
            };
        }
        self.log.info(null, "system resumed from sleep", &.{.{ .key = "tunnelsKilled", .value = .{ .int = n } }});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.conns.items) |c| c.requestResume();
    }

    pub fn reorder(self: *Engine, names: []const []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var ordered: std.ArrayList(*Conn) = .empty;
        defer ordered.deinit(self.alloc);
        for (names) |n| {
            const c = self.findConn(n) orelse continue;
            if (std.mem.indexOfScalar(*Conn, ordered.items, c) != null) continue;
            ordered.append(self.alloc, c) catch return;
        }
        for (self.conns.items) |c| if (std.mem.indexOfScalar(*Conn, ordered.items, c) == null) {
            ordered.append(self.alloc, c) catch return;
        };
        @memcpy(self.conns.items, ordered.items);
    }

    pub fn snapshot(self: *Engine, alloc: Allocator) !api.Snapshot {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = .init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const list = try arena.allocator().alloc(api.Status, self.conns.items.len);
        for (self.conns.items, list) |c, *dst| dst.* = try c.statusCopy(arena.allocator());
        return .{ .conns = list, .arena = arena };
    }

    pub fn status(self: *Engine, alloc: Allocator, name: []const u8) !?api.Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const c = self.findConn(name) orelse return null;
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = .init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        var s = try c.statusCopy(arena.allocator());
        s.arena = arena;
        return s;
    }

    // -- password ------------------------------------------------------

    pub const PasswordBuf = struct {
        buf: [1024]u8 = undefined,
        len: usize = 0,
        has: bool = false,
        unavailable: ?[]const u8 = null,

        pub fn slice(self: *PasswordBuf) ?[]const u8 {
            return if (self.has) self.buf[0..self.len] else null;
        }
        pub fn wipe(self: *PasswordBuf) void {
            std.crypto.secureZero(u8, &self.buf);
            self.len = 0;
            self.has = false;
        }
    };

    /// Whether the provider knows of a stored password (no keyring call).
    pub fn passwordStored(self: *Engine, id: []const u8) bool {
        const prov = self.password orelse return false;
        const f = prov.has orelse return false;
        return f(prov.ctx, id);
    }

    /// Ask the provider. Never logs the password.
    pub fn lookupPassword(self: *Engine, p: Profile, out: *PasswordBuf) void {
        out.* = .{};
        const prov = self.password orelse return;
        switch (prov.func(prov.ctx, p.id, p.name, &out.buf)) {
            .none => {},
            .found => |n| {
                out.len = @min(n, out.buf.len);
                out.has = true;
            },
            .unavailable => |why| out.unavailable = why,
        }
    }

    // -- Restart Sessions ----------------------------------------------

    pub fn restartSessions(self: *Engine, name: []const u8) api.Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reap();
        const p = self.store.find(name) orelse return "no such profile";
        // The instance name lands in a remote shell command; saved profiles
        // are validated, but re-check in case config.json was edited by hand.
        if (p.instance.len > 0 and !profile_mod.validInstance(p.instance)) return "invalid instance name in profile";
        const w = Worker.create(self, p.*) catch return "out of memory";
        self.workers.append(self.alloc, w) catch {
            w.destroy();
            return "out of memory";
        };
        w.thread = std.Thread.spawn(.{}, Worker.run, .{w}) catch {
            _ = self.workers.pop();
            w.destroy();
            return "could not start a worker thread";
        };
        return null;
    }
};

/// A Restart Sessions run on its own thread.
const Worker = struct {
    engine: *Engine,
    arena: std.heap.ArenaAllocator,
    profile: Profile,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    err_lines: std.ArrayList([]const u8) = .empty,

    fn create(e: *Engine, p: Profile) !*Worker {
        const w = try e.alloc.create(Worker);
        w.* = .{ .engine = e, .arena = .init(e.alloc), .profile = undefined };
        w.profile = p.clone(w.arena.allocator()) catch |err| {
            w.arena.deinit();
            e.alloc.destroy(w);
            return err;
        };
        return w;
    }

    fn destroy(w: *Worker) void {
        const a = w.engine.alloc;
        w.arena.deinit();
        a.destroy(w);
    }

    fn shouldCancel(ctx: *anyopaque) bool {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        return w.engine.quitting.load(.acquire);
    }

    fn stderrLine(ctx: *anyopaque, line: []const u8) void {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        const l = w.arena.allocator().dupe(u8, line) catch return;
        w.err_lines.append(w.arena.allocator(), l) catch {};
    }

    fn run(w: *Worker) void {
        defer w.done.store(true, .release);
        @import("supervisor.zig").blockSigpipe();
        const e = w.engine;
        const a = w.arena.allocator();
        const name = w.profile.name;
        const instance = w.profile.instanceOrDefault();
        var result: api.RestartResult = .{ .name = name, .ok = false, .msg = "" };
        defer e.emit(&.{ .restart_done = &result });

        var pw: Engine.PasswordBuf = .{};
        defer pw.wipe();
        e.lookupPassword(w.profile, &pw);
        if (pw.unavailable != null) {
            result.msg = "saved password could not be decrypted — edit the profile and re-enter it";
            e.log.atf(.@"error", name, &.{}, "restart sessions: {s}", .{result.msg});
            return;
        }
        e.log.info(name, "restart sessions requested", &.{.{ .key = "instance", .value = .{ .str = instance } }});
        const outcome = w.runRestart(a, &pw) catch |err| blk: {
            break :blk deploy.RestartResult{ .ok = false, .msg = @errorName(err) };
        };
        result.ok = outcome.ok;
        result.msg = outcome.msg;
        e.log.atf(if (outcome.ok) .info else .@"error", name, &.{}, "restart sessions: {s}", .{outcome.msg});
    }

    fn runRestart(w: *Worker, a: Allocator, pw: *Engine.PasswordBuf) !deploy.RestartResult {
        const e = w.engine;
        const hashes = try deploy.manifestHashes(a, e.io, e.paths.payload_dir);
        const script = try deploy.restartScript(a, w.profile.instanceOrDefault(), hashes);
        const command = try std.fmt.allocPrint(a, "exec sh -c '{s}'", .{script});
        const argv = try ssh.commandArgv(a, e.ssh_path, w.profile, pw.has, command);
        var env = try ssh.childEnv(e.alloc, &e.env, e.askpass_path, pw.slice());
        pw.wipe();
        defer ssh.wipe(&env);
        const res = proc.run(a, e.io, argv, &env, .{
            .ctx = w,
            .wake_fd = e.quit_pipe.r,
            .shouldCancel = shouldCancel,
            .stderrLine = stderrLine,
        }, .{ .timeout_ms = e.timing.restart_timeout_ms }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.SpawnFailed => {
                var buf: [128]u8 = undefined;
                return .{ .ok = false, .msg = try a.dupe(u8, proc.spawnErrorText(&buf, e.ssh_path, @errorCast(err))) };
            },
            error.Cancelled => return .{ .ok = false, .msg = "cancelled (quitting)" },
            else => |x| return x,
        };
        return deploy.restartOutcome(a, res.stdout, res.exit, w.err_lines.items);
    }
};
