//! Saved ssh passwords in the Secret Service (org.freedesktop.secrets:
//! GNOME Keyring, KWallet, KeePassXC…), spoken to over D-Bus through GIO,
//! so no libsecret dependency. One item per profile, keyed by the
//! profile id (docs/native-client.md › Local state):
//!
//!   label       "webmux: <profile name>"
//!   attributes  xdg:schema = me.puntium.webmux.gtk.Password
//!               profile-id = <16 hex chars>
//!
//! The secret is transferred with the "plain" session algorithm (the
//! session bus is private to the user; libsecret's DH/AES transport is
//! not implemented). Plaintext lives only in a fixed buffer that is
//! zeroed after use and in the D-Bus messages GIO builds and frees.
//!
//! Every function that talks to the service blocks (up to the D-Bus
//! timeout, or while an unlock prompt is open) and must run on a worker
//! thread: the engine's password callback runs on an engine thread; the
//! UI's store/clear go through `storeAsync`/`clearAsync`, which spawn one.
//!
//! "Has a saved password" (the form's placeholder and checkbox) is a set of
//! profile ids kept in memory and mirrored to `<state>/keyring.json`
//! (ids only, never a secret), so a profile with a password whose keyring
//! is not running fails its connect with a clear message instead of
//! silently trying key auth.
//!
//! A cleared password (the form's "clear saved", or a deleted profile) is
//! never used again, whatever the keyring is doing: its id goes into a
//! second set, `cleared` (also mirrored to keyring.json), at once.
//! `lookup` answers `.none` for a cleared id without asking the keyring,
//! and the item is deleted whenever the keyring is reachable (right away,
//! at the next lookup, store or startup scan); only then does the id leave
//! the set. Storing a new password for the id lifts it.
//!
//! Store and clear run one at a time (`job_mutex`), so a late delete can
//! never remove a password stored after it.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const conn = @import("../../../webmux/conn.zig");
const global = @import("../../../global.zig");
const util = @import("../../../webmux/conn/util.zig");
const dbus = @import("dbus.zig");
const mainloop = @import("../mainloop.zig");

const log = std.log.scoped(.webmux_keyring);
const alloc = std.heap.c_allocator;

const SERVICE = "org.freedesktop.secrets";
const SERVICE_PATH = "/org/freedesktop/secrets";
const IF_SERVICE = "org.freedesktop.Secret.Service";
const IF_COLLECTION = "org.freedesktop.Secret.Collection";
const IF_ITEM = "org.freedesktop.Secret.Item";
const IF_PROMPT = "org.freedesktop.Secret.Prompt";
const IF_PROPS = "org.freedesktop.DBus.Properties";
pub const SCHEMA = "me.puntium.webmux.gtk.Password";

const CALL_TIMEOUT_MS = 10_000;
/// How long an unlock / create-keyring prompt may stay open.
const PROMPT_TIMEOUT_MS = 180_000;

pub const NO_SERVICE = "no Secret Service is running on the session bus (org.freedesktop.secrets) — start GNOME Keyring or KWallet";
pub const STORE_UNAVAILABLE = "the system keyring is unavailable — cannot store a password";

// ---------------------------------------------------------------------------
// The has-password set
// ---------------------------------------------------------------------------

var mutex: std.Io.Mutex = .init;
/// Serializes store/clear/purge (see the top of the file).
var job_mutex: std.Io.Mutex = .init;
var saved: IdSet = .{};
var cleared: IdSet = .{};
var hint_path: ?[]u8 = null;
/// Called on the main thread after the set changed (UI refresh).
pub var on_change: ?*const fn () void = null;

/// Whether the service answered the last time we asked.
pub const Service = enum(u8) { unknown, available, absent };
var service: std.atomic.Value(Service) = .init(.unknown);

pub fn serviceState() Service {
    return service.load(.acquire);
}

fn lock() void {
    mutex.lockUncancelable(global.io());
}
fn unlock() void {
    mutex.unlock(global.io());
}

/// A set of profile ids. Guarded by `mutex`.
const IdSet = struct {
    items: std.ArrayList([]u8) = .empty,

    fn indexOf(set: *const IdSet, id: []const u8) ?usize {
        for (set.items.items, 0..) |x, i| if (std.mem.eql(u8, x, id)) return i;
        return null;
    }
    fn contains(set: *const IdSet, id: []const u8) bool {
        return set.indexOf(id) != null;
    }
    fn put(set: *IdSet, id: []const u8) void {
        if (set.contains(id) or id.len == 0 or id.len > 64) return;
        const copy = alloc.dupe(u8, id) catch return;
        set.items.append(alloc, copy) catch alloc.free(copy);
    }
    fn remove(set: *IdSet, id: []const u8) void {
        if (set.indexOf(id)) |i| alloc.free(set.items.swapRemove(i));
    }
    fn clearAll(set: *IdSet) void {
        for (set.items.items) |x| alloc.free(x);
        set.items.clearRetainingCapacity();
    }
};

/// Any thread: does this profile have a saved password (as far as we know)?
/// A cleared one never counts.
pub fn has(id: []const u8) bool {
    lock();
    defer unlock();
    return saved.contains(id) and !cleared.contains(id);
}

/// `conn.PasswordFn.has`.
fn hasCallback(_: ?*anyopaque, id: []const u8) bool {
    return has(id);
}

fn anyCleared() bool {
    lock();
    defer unlock();
    return cleared.items.items.len > 0;
}

fn isCleared(id: []const u8) bool {
    lock();
    defer unlock();
    return cleared.contains(id);
}

fn setHas(id: []const u8, value: bool) void {
    {
        lock();
        defer unlock();
        if (value) saved.put(id) else saved.remove(id);
    }
    saveHint();
    notifyChange();
}

/// Main thread: the password of this profile must never be used again
/// (clear saved, profile deleted). Recorded at once and persisted; the
/// keyring item is deleted now if the keyring answers, else later.
pub fn forget(id: []const u8) void {
    if (id.len == 0) return;
    {
        lock();
        defer unlock();
        cleared.put(id);
        saved.remove(id);
    }
    saveHint();
    notifyChange();
    clearAsync(id, 0, null);
}

fn replaceAll(new: []const []const u8) void {
    {
        lock();
        defer unlock();
        saved.clearAll();
        for (new) |id| if (!cleared.contains(id)) saved.put(id);
    }
    saveHint();
    notifyChange();
}

fn notifyChange() void {
    const Changed = struct {
        _: u8 = 0,
        fn run(_: *@This()) void {
            if (on_change) |f| f();
        }
    };
    mainloop.post(Changed{}, Changed.run);
}

const Hint = struct {
    ids: []const []const u8 = &.{},
    /// Cleared passwords whose keyring item may still exist.
    cleared: []const []const u8 = &.{},
};

fn loadHint() void {
    const path = hint_path orelse return;
    const bytes = (util.readFileAlloc(global.io(), alloc, path, 1 << 20) catch return) orelse return;
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(Hint, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    lock();
    defer unlock();
    for (parsed.value.cleared) |id| cleared.put(id);
    for (parsed.value.ids) |id| if (!cleared.contains(id)) saved.put(id);
}

fn saveHint() void {
    const path = hint_path orelse return;
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    {
        lock();
        defer unlock();
        std.json.Stringify.value(Hint{ .ids = @ptrCast(saved.items.items), .cleared = @ptrCast(cleared.items.items) }, .{ .whitespace = .indent_2 }, &w.writer) catch return;
    }
    w.writer.writeByte('\n') catch return;
    if (std.fs.path.dirname(path)) |dir| util.makePath(global.io(), dir, 0o700) catch {};
    util.atomicWrite(global.io(), path, w.written(), 0o600) catch |e| {
        log.warn("cannot write {s}: {t}", .{ path, e });
    };
}

/// Ids whose item must still be deleted (owned copies).
fn clearedCopy() std.ArrayList([:0]u8) {
    var out: std.ArrayList([:0]u8) = .empty;
    lock();
    defer unlock();
    for (cleared.items.items) |id| {
        const z = alloc.dupeSentinel(u8, id, 0) catch continue;
        out.append(alloc, z) catch alloc.free(z);
    }
    return out;
}

/// With a session open and `job_mutex` held: delete the items of every
/// cleared id; an id leaves the set once its items are gone.
fn purgeLocked(s: *Session) void {
    var ids = clearedCopy();
    defer {
        for (ids.items) |x| alloc.free(x);
        ids.deinit(alloc);
    }
    var changed = false;
    for (ids.items) |id| {
        if (s.deleteItems(id)) {
            lock();
            cleared.remove(id);
            unlock();
            changed = true;
            log.info("cleared password removed from the keyring for profile {s}", .{id});
        }
    }
    if (changed) saveHint();
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

/// Main thread, at startup: remember where the hint lives, load it, and
/// name the backend for the "client started" log line. Only asks the bus
/// daemon (instant); the keyring itself is scanned on a worker thread by
/// `scanAsync`.
pub fn init(state_dir: []const u8) void {
    hint_path = std.fs.path.join(alloc, &.{ state_dir, "keyring.json" }) catch null;
    loadHint();
}

var backend_buf: [96]u8 = undefined;

/// "secret-service (gnome-keyring-d)", "secret-service (activatable)" or
/// "none (no Secret Service on the session bus)". Main thread, startup.
pub fn backendName() []const u8 {
    var err: dbus.CallError = .{};
    const c = dbus.bus(.session, &err) orelse return "none (no session bus)";
    defer c.unref();
    const owner = dbus.call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", dbus.tuple(&.{dbus.str(SERVICE)}), "(u)", 1000, &err);
    if (owner) |r| {
        defer dbus.unref(r);
        const pid_v = dbus.child(r, 0);
        defer dbus.unref(pid_v);
        const pid = glib.Variant.getUint32(pid_v);
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return "secret-service";
        var comm: [32]u8 = undefined;
        const n = readSmall(path, &comm);
        const name = std.mem.trim(u8, comm[0..n], " \n");
        return std.fmt.bufPrint(&backend_buf, "secret-service ({s})", .{if (name.len > 0) name else "unknown"}) catch "secret-service";
    }
    const act = dbus.call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListActivatableNames", null, "(as)", 1000, &err) orelse
        return "none (no Secret Service on the session bus)";
    defer dbus.unref(act);
    const list = dbus.child(act, 0);
    defer dbus.unref(list);
    for (0..dbus.count(list)) |i| {
        const s = dbus.child(list, i);
        defer dbus.unref(s);
        if (std.mem.eql(u8, dbus.getStr(s), SERVICE)) return "secret-service (activatable)";
    }
    return "none (no Secret Service on the session bus)";
}

fn readSmall(path: []const u8, out: []u8) usize {
    const bytes = (util.readFileAlloc(global.io(), alloc, path, 4096) catch return 0) orelse return 0;
    defer alloc.free(bytes);
    const n = @min(bytes.len, out.len);
    @memcpy(out[0..n], bytes[0..n]);
    return n;
}

/// Worker thread: list every webmux item in the keyring and make the
/// has-password set match. Without a service the hint stays as it was.
/// `referenced`: every profile id a stored secret may still belong to
/// (`conn.Engine.referencedIds`; ownership passes to the scan). Items whose
/// id is in none of them, and was not stored during this run, can be
/// reached by no profile: they are deleted (item 5 of the third fix round).
/// Null: no orphan clean-up.
pub fn scanAsync(referenced: ?[][]u8) void {
    const t = std.Thread.spawn(.{}, scan, .{referenced}) catch {
        freeIds(referenced);
        return;
    };
    t.detach();
}

fn freeIds(ids_: ?[][]u8) void {
    const ids = ids_ orelse return;
    for (ids) |x| alloc.free(x);
    alloc.free(ids);
}

/// Ids stored during this run (a scan's list of referenced ids may predate
/// them).
var stored_this_run: IdSet = .{};

fn scan(referenced: ?[][]u8) void {
    defer freeIds(referenced);
    var s = Session.open() catch |e| {
        log.info("keyring scan skipped: {t}", .{e});
        return;
    };
    defer s.close();
    {
        job_mutex.lockUncancelable(global.io());
        defer job_mutex.unlock(global.io());
        purgeLocked(&s);
    }
    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |x| alloc.free(x);
        found.deinit(alloc);
    }
    const items = s.search(null) catch return;
    defer dbus.unref(items);
    for (0..2) |k| {
        const list = dbus.child(items, k);
        defer dbus.unref(list);
        for (0..dbus.count(list)) |i| {
            const p = dbus.child(list, i);
            defer dbus.unref(p);
            const id = s.itemProfileId(dbus.getStr(p)) orelse continue;
            found.append(alloc, id) catch alloc.free(id);
        }
    }
    log.info("keyring scan: {d} saved password(s)", .{found.items.len});
    if (referenced) |refs| {
        var orphans: usize = 0;
        for (found.items) |id| {
            var known = false;
            for (refs) |r| if (std.ascii.eqlIgnoreCase(r, id)) {
                known = true;
            };
            lock();
            if (stored_this_run.contains(id)) known = true;
            if (!known) cleared.put(id);
            unlock();
            if (!known) orphans += 1;
        }
        if (orphans > 0) {
            log.info("keyring scan: {d} saved password(s) belong to no profile: deleting them", .{orphans});
            saveHint();
            job_mutex.lockUncancelable(global.io());
            defer job_mutex.unlock(global.io());
            purgeLocked(&s);
        }
    }
    replaceAll(found.items);
}

// ---------------------------------------------------------------------------
// The engine's password provider
// ---------------------------------------------------------------------------

pub fn passwordFn() conn.PasswordFn {
    return .{ .func = lookupCallback, .has = hasCallback };
}

fn lookupCallback(_: ?*anyopaque, profile_id: []const u8, profile_name: []const u8, out: []u8) conn.PasswordLookup {
    _ = profile_name;
    return lookup(profile_id, out);
}

/// Engine thread: the profile's password into `out`. Never logs it.
pub fn lookup(profile_id: []const u8, out: []u8) conn.PasswordLookup {
    // A cleared password is never used, reachable keyring or not; delete
    // its leftover item while we are here.
    if (isCleared(profile_id)) {
        if (Session.open()) |opened| {
            var s = opened;
            defer s.close();
            job_mutex.lockUncancelable(global.io());
            defer job_mutex.unlock(global.io());
            purgeLocked(&s);
        } else |_| {}
        return .none;
    }
    var s = Session.open() catch |e| switch (e) {
        error.NoService => {
            // We cannot know for sure; the hint says whether a password was
            // saved. Without one this is key auth, as intended.
            return if (has(profile_id)) .{ .unavailable = NO_SERVICE } else .none;
        },
        else => return .{ .unavailable = "the system keyring did not answer" },
    };
    defer s.close();
    // The keyring answers: delete any cleared password still in it (a
    // profile deleted while the keyring was down leaves no orphan).
    if (anyCleared()) {
        job_mutex.lockUncancelable(global.io());
        defer job_mutex.unlock(global.io());
        purgeLocked(&s);
    }
    const items = s.search(profile_id) catch return .{ .unavailable = "the system keyring refused the search" };
    defer dbus.unref(items);
    const unlocked = dbus.child(items, 0);
    defer dbus.unref(unlocked);
    const locked = dbus.child(items, 1);
    defer dbus.unref(locked);

    var path_buf: [256]u8 = undefined;
    var path: ?[:0]const u8 = null;
    if (dbus.count(unlocked) > 0) {
        const p = dbus.child(unlocked, 0);
        defer dbus.unref(p);
        path = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{dbus.getStr(p)}, 0) catch null;
    } else if (dbus.count(locked) > 0) {
        const p = dbus.child(locked, 0);
        defer dbus.unref(p);
        const lp = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{dbus.getStr(p)}, 0) catch return .{ .unavailable = "keyring item path too long" };
        if (!s.unlock(lp)) return .{ .unavailable = "the system keyring is locked (the unlock prompt was dismissed or failed)" };
        path = lp;
    }
    const item = path orelse {
        if (has(profile_id)) setHas(profile_id, false);
        return .none;
    };
    const n = s.getSecret(item, out) catch return .{ .unavailable = "the system keyring did not return the secret" };
    if (!has(profile_id)) setHas(profile_id, true);
    return .{ .found = n };
}

// ---------------------------------------------------------------------------
// Store / clear (worker threads)
// ---------------------------------------------------------------------------

pub const Done = struct {
    /// null = ok, else a user-facing message (static)
    err: ?[]const u8,
    tag: u64,
};

/// Store `secret` for the profile on a worker thread, then call
/// `done(result)` on the main thread. The secret is copied and the copy
/// wiped when the worker is done.
pub fn storeAsync(profile_id: []const u8, profile_name: []const u8, secret: []const u8, tag: u64, done: *const fn (Done) void) void {
    const job = alloc.create(Job) catch return done(.{ .err = "out of memory", .tag = tag });
    job.* = .{ .tag = tag, .done = done, .kind = .store };
    job.id = alloc.dupeSentinel(u8, profile_id, 0) catch return done(.{ .err = "out of memory", .tag = tag });
    job.label = std.fmt.allocPrintSentinel(alloc, "webmux: {s}", .{profile_name}, 0) catch return done(.{ .err = "out of memory", .tag = tag });
    const n = @min(secret.len, job.secret.len);
    @memcpy(job.secret[0..n], secret[0..n]);
    job.secret_len = n;
    const t = std.Thread.spawn(.{}, Job.run, .{job}) catch return job.finish("cannot start the keyring worker");
    t.detach();
}

/// Delete the profile's item(s) on a worker thread.
pub fn clearAsync(profile_id: []const u8, tag: u64, done: ?*const fn (Done) void) void {
    const job = alloc.create(Job) catch return;
    job.* = .{ .tag = tag, .done = done, .kind = .clear };
    job.id = alloc.dupeSentinel(u8, profile_id, 0) catch return;
    const t = std.Thread.spawn(.{}, Job.run, .{job}) catch return job.finish("cannot start the keyring worker");
    t.detach();
}

const Job = struct {
    kind: enum { store, clear },
    tag: u64,
    done: ?*const fn (Done) void,
    id: ?[:0]u8 = null,
    label: ?[:0]u8 = null,
    secret: [1024]u8 = undefined,
    secret_len: usize = 0,

    fn run(job: *Job) void {
        const err: ?[]const u8 = switch (job.kind) {
            .store => store(job.id.?, job.label.?, job.secret[0..job.secret_len]),
            .clear => clear(job.id.?),
        };
        job.finish(err);
    }

    fn finish(job: *Job, err: ?[]const u8) void {
        std.crypto.secureZero(u8, &job.secret);
        if (job.done) |d| {
            const Post = struct {
                d: *const fn (Done) void,
                r: Done,
                fn run(p: *@This()) void {
                    p.d(p.r);
                }
            };
            mainloop.post(Post{ .d = d, .r = .{ .err = err, .tag = job.tag } }, Post.run);
        }
        if (job.id) |x| alloc.free(x);
        if (job.label) |x| alloc.free(x);
        alloc.destroy(job);
    }
};

/// Blocking: create or replace the profile's item. Returns null or a
/// user-facing error.
pub fn store(profile_id: [:0]const u8, label: [:0]const u8, secret: []const u8) ?[]const u8 {
    job_mutex.lockUncancelable(global.io());
    defer job_mutex.unlock(global.io());
    var s = Session.open() catch |e| return switch (e) {
        error.NoService => STORE_UNAVAILABLE,
        else => "the system keyring did not answer — cannot store a password",
    };
    defer s.close();
    // Old items of a cleared password go first (this id included), so the
    // new one is the only one.
    purgeLocked(&s);
    var coll_buf: [256]u8 = undefined;
    const coll = s.defaultCollection(&coll_buf) orelse return "the system keyring has no usable default collection — cannot store a password";
    if (!s.unlock(coll)) return "the system keyring is locked — cannot store a password";
    const props = dbus.array("{sv}", &.{
        dbus.entry(dbus.str(IF_ITEM ++ ".Label"), dbus.variant(dbus.str(label))),
        dbus.entry(dbus.str(IF_ITEM ++ ".Attributes"), dbus.variant(attrs(profile_id))),
    });
    const r = s.call(coll, IF_COLLECTION, "CreateItem", dbus.tuple(&.{ props, s.secretValue(secret), dbus.boolean(true) }), "(oo)") orelse {
        log.warn("CreateItem failed: {s} {s}", .{ s.err.name(), s.err.message() });
        return "the system keyring refused to store the password";
    };
    defer dbus.unref(r);
    const item = dbus.child(r, 0);
    defer dbus.unref(item);
    if (std.mem.eql(u8, dbus.getStr(item), "/")) {
        const prompt = dbus.child(r, 1);
        defer dbus.unref(prompt);
        var pb: [256]u8 = undefined;
        const pp = std.fmt.bufPrintSentinel(&pb, "{s}", .{dbus.getStr(prompt)}, 0) catch return "keyring prompt path too long";
        const res = s.runPrompt(pp) orelse return "storing the password was cancelled";
        dbus.unref(res);
    }
    {
        lock();
        defer unlock();
        cleared.remove(profile_id);
        stored_this_run.put(profile_id);
    }
    setHas(profile_id, true);
    log.info("password stored for profile {s}", .{profile_id});
    return null;
}

/// Blocking: delete the items of every cleared password (this profile's
/// included, if `forget` recorded it). Without a keyring the ids stay
/// recorded and are deleted later; they are never used meanwhile.
pub fn clear(profile_id: [:0]const u8) ?[]const u8 {
    job_mutex.lockUncancelable(global.io());
    defer job_mutex.unlock(global.io());
    var s = Session.open() catch |e| switch (e) {
        error.NoService => {
            log.info("keyring unavailable: password of profile {s} stays cleared, item deleted later", .{profile_id});
            return null;
        },
        else => return "the system keyring did not answer",
    };
    defer s.close();
    if (!isCleared(profile_id)) {
        // Not via forget (control socket): delete just this one.
        _ = s.deleteItems(profile_id);
        setHas(profile_id, false);
        return null;
    }
    purgeLocked(&s);
    return null;
}

fn attrs(profile_id: ?[:0]const u8) dbus.V {
    if (profile_id) |id| return dbus.array("{ss}", &.{
        dbus.entry(dbus.str("xdg:schema"), dbus.str(SCHEMA)),
        dbus.entry(dbus.str("profile-id"), dbus.str(id)),
    });
    return dbus.array("{ss}", &.{dbus.entry(dbus.str("xdg:schema"), dbus.str(SCHEMA))});
}

// ---------------------------------------------------------------------------
// A Secret Service session
// ---------------------------------------------------------------------------

const Session = struct {
    c: *gio.DBusConnection,
    path: [:0]u8,
    err: dbus.CallError = .{},

    fn open() error{ NoService, Failed }!Session {
        var err: dbus.CallError = .{};
        const c = dbus.bus(.session, &err) orelse {
            service.store(.absent, .release);
            return error.NoService;
        };
        errdefer c.unref();
        const r = dbus.call(c, SERVICE, SERVICE_PATH, IF_SERVICE, "OpenSession", dbus.tuple(&.{ dbus.str("plain"), dbus.variant(dbus.str("")) }), "(vo)", CALL_TIMEOUT_MS, &err) orelse {
            if (err.noService()) {
                service.store(.absent, .release);
                return error.NoService;
            }
            log.warn("OpenSession failed: {s} {s}", .{ err.name(), err.message() });
            return error.Failed;
        };
        defer dbus.unref(r);
        service.store(.available, .release);
        const p = dbus.child(r, 1);
        defer dbus.unref(p);
        const path = alloc.dupeSentinel(u8, dbus.getStr(p), 0) catch return error.Failed;
        return .{ .c = c, .path = path };
    }

    fn close(s: *Session) void {
        if (s.call(s.path, "org.freedesktop.Secret.Session", "Close", null, null)) |r| dbus.unref(r);
        alloc.free(s.path);
        s.c.unref();
    }

    fn call(s: *Session, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?dbus.V, comptime reply: ?[:0]const u8) ?dbus.V {
        return dbus.call(s.c, SERVICE, path, iface, method, params, reply, CALL_TIMEOUT_MS, &s.err);
    }

    /// (oayays) for a secret value.
    fn secretValue(s: *Session, secret: []const u8) dbus.V {
        return dbus.tuple(&.{ dbus.objpath(s.path), dbus.bytes(""), dbus.bytes(secret), dbus.str("text/plain") });
    }

    /// SearchItems → (unlocked ao, locked ao); null id = every webmux item.
    fn search(s: *Session, profile_id: ?[]const u8) !dbus.V {
        var idz: [80]u8 = undefined;
        const id: ?[:0]const u8 = if (profile_id) |p| (std.fmt.bufPrintSentinel(&idz, "{s}", .{p}, 0) catch return error.Failed) else null;
        return s.call(SERVICE_PATH, IF_SERVICE, "SearchItems", dbus.tuple(&.{attrs(id)}), "(aoao)") orelse {
            log.warn("SearchItems failed: {s} {s}", .{ s.err.name(), s.err.message() });
            return error.Failed;
        };
    }

    /// Delete every item of a profile; true when none is left.
    fn deleteItems(s: *Session, profile_id: [:0]const u8) bool {
        const items = s.search(profile_id) catch return false;
        defer dbus.unref(items);
        var ok = true;
        for (0..2) |k| {
            const list = dbus.child(items, k);
            defer dbus.unref(list);
            for (0..dbus.count(list)) |i| {
                const p = dbus.child(list, i);
                defer dbus.unref(p);
                var pb: [256]u8 = undefined;
                const path = std.fmt.bufPrintSentinel(&pb, "{s}", .{dbus.getStr(p)}, 0) catch {
                    ok = false;
                    continue;
                };
                const r = s.call(path, IF_ITEM, "Delete", null, "(o)") orelse {
                    log.warn("Delete failed: {s} {s}", .{ s.err.name(), s.err.message() });
                    ok = false;
                    continue;
                };
                defer dbus.unref(r);
                const prompt = dbus.child(r, 0);
                defer dbus.unref(prompt);
                if (!std.mem.eql(u8, dbus.getStr(prompt), "/")) {
                    var qb: [256]u8 = undefined;
                    const pp = std.fmt.bufPrintSentinel(&qb, "{s}", .{dbus.getStr(prompt)}, 0) catch {
                        ok = false;
                        continue;
                    };
                    if (s.runPrompt(pp)) |res| dbus.unref(res) else ok = false;
                }
            }
        }
        return ok;
    }

    /// The `profile-id` attribute of an item (owned), or null.
    fn itemProfileId(s: *Session, item: []const u8) ?[]const u8 {
        var pb: [256]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}", .{item}, 0) catch return null;
        const r = s.call(path, IF_PROPS, "Get", dbus.tuple(&.{ dbus.str(IF_ITEM), dbus.str("Attributes") }), "(v)") orelse return null;
        defer dbus.unref(r);
        const v = dbus.child(r, 0);
        defer dbus.unref(v);
        const dict = glib.Variant.getVariant(v);
        defer dbus.unref(dict);
        for (0..dbus.count(dict)) |i| {
            const e = dbus.child(dict, i);
            defer dbus.unref(e);
            const k = dbus.child(e, 0);
            defer dbus.unref(k);
            if (!std.mem.eql(u8, dbus.getStr(k), "profile-id")) continue;
            const val = dbus.child(e, 1);
            defer dbus.unref(val);
            return alloc.dupe(u8, dbus.getStr(val)) catch null;
        }
        return null;
    }

    /// Unlock an item or collection, running the prompt if one is needed.
    fn unlock(s: *Session, path: [:0]const u8) bool {
        const r = s.call(SERVICE_PATH, IF_SERVICE, "Unlock", dbus.tuple(&.{dbus.array("o", &.{dbus.objpath(path)})}), "(aoo)") orelse {
            log.warn("Unlock failed: {s} {s}", .{ s.err.name(), s.err.message() });
            return false;
        };
        defer dbus.unref(r);
        const done = dbus.child(r, 0);
        defer dbus.unref(done);
        if (dbus.count(done) > 0) return true;
        const prompt = dbus.child(r, 1);
        defer dbus.unref(prompt);
        const pp_s = dbus.getStr(prompt);
        if (std.mem.eql(u8, pp_s, "/")) return true;
        var pb: [256]u8 = undefined;
        const pp = std.fmt.bufPrintSentinel(&pb, "{s}", .{pp_s}, 0) catch return false;
        const res = s.runPrompt(pp) orelse return false;
        dbus.unref(res);
        return true;
    }

    /// The default collection's path into `buf`, creating it ("Login",
    /// alias default) if the service has none.
    fn defaultCollection(s: *Session, buf: []u8) ?[:0]const u8 {
        if (s.call(SERVICE_PATH, IF_SERVICE, "ReadAlias", dbus.tuple(&.{dbus.str("default")}), "(o)")) |r| {
            defer dbus.unref(r);
            const p = dbus.child(r, 0);
            defer dbus.unref(p);
            const path = dbus.getStr(p);
            if (!std.mem.eql(u8, path, "/")) return std.fmt.bufPrintSentinel(buf, "{s}", .{path}, 0) catch null;
        }
        const props = dbus.array("{sv}", &.{dbus.entry(dbus.str(IF_COLLECTION ++ ".Label"), dbus.variant(dbus.str("Login")))});
        const r = s.call(SERVICE_PATH, IF_SERVICE, "CreateCollection", dbus.tuple(&.{ props, dbus.str("default") }), "(oo)") orelse {
            log.warn("CreateCollection failed: {s} {s}", .{ s.err.name(), s.err.message() });
            return null;
        };
        defer dbus.unref(r);
        const p = dbus.child(r, 0);
        defer dbus.unref(p);
        if (!std.mem.eql(u8, dbus.getStr(p), "/")) return std.fmt.bufPrintSentinel(buf, "{s}", .{dbus.getStr(p)}, 0) catch null;
        const prompt = dbus.child(r, 1);
        defer dbus.unref(prompt);
        var pb: [256]u8 = undefined;
        const pp = std.fmt.bufPrintSentinel(&pb, "{s}", .{dbus.getStr(prompt)}, 0) catch return null;
        const res = s.runPrompt(pp) orelse return null;
        defer dbus.unref(res);
        // result: v containing the collection path
        const inner = glib.Variant.getVariant(res);
        defer dbus.unref(inner);
        return std.fmt.bufPrintSentinel(buf, "{s}", .{dbus.getStr(inner)}, 0) catch null;
    }

    /// GetSecret on an item: the value into `out`; returns its length.
    fn getSecret(s: *Session, item: [:0]const u8, out: []u8) !usize {
        const r = s.call(item, IF_ITEM, "GetSecret", dbus.tuple(&.{dbus.objpath(s.path)}), "((oayays))") orelse {
            log.warn("GetSecret failed: {s} {s}", .{ s.err.name(), s.err.message() });
            return error.Failed;
        };
        defer dbus.unref(r);
        const sec = dbus.child(r, 0);
        defer dbus.unref(sec);
        const val = dbus.child(sec, 2);
        defer dbus.unref(val);
        const b = dbus.getBytes(val);
        const n = @min(b.len, out.len);
        @memcpy(out[0..n], b[0..n]);
        // The reply is ours alone now; scrub its copy of the plaintext.
        std.crypto.secureZero(u8, @constCast(b));
        return n;
    }

    /// Run a prompt and wait for Completed. Returns the result variant
    /// (unref it), or null if dismissed, failed or timed out. Uses a private
    /// main context on this (worker) thread.
    fn runPrompt(s: *Session, prompt: [:0]const u8) ?dbus.V {
        const ctx = glib.MainContext.new();
        defer ctx.unref();
        ctx.pushThreadDefault();
        defer ctx.popThreadDefault();
        var state: PromptState = .{};
        const sub = s.c.signalSubscribe(SERVICE, IF_PROMPT, "Completed", prompt, null, .{}, PromptState.onCompleted, &state, null);
        defer s.c.signalUnsubscribe(sub);
        const r = s.call(prompt, IF_PROMPT, "Prompt", dbus.tuple(&.{dbus.str("")}), "()") orelse {
            log.warn("Prompt failed: {s} {s}", .{ s.err.name(), s.err.message() });
            return null;
        };
        dbus.unref(r);
        log.info("keyring prompt open: waiting for the user", .{});
        var waited: u32 = 0;
        while (!state.done and waited < PROMPT_TIMEOUT_MS) {
            if (glib.MainContext.iteration(ctx, 0) == 0) {
                global.io().sleep(.fromMilliseconds(20), .awake) catch {};
                waited += 20;
            }
        }
        if (!state.done) {
            _ = s.call(prompt, IF_PROMPT, "Dismiss", null, null);
            return null;
        }
        if (state.dismissed) {
            if (state.result) |res| dbus.unref(res);
            return null;
        }
        return state.result;
    }
};

const PromptState = struct {
    done: bool = false,
    dismissed: bool = false,
    result: ?dbus.V = null,

    fn onCompleted(_: *gio.DBusConnection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, params: *glib.Variant, ud: ?*anyopaque) callconv(.c) void {
        const st: *PromptState = @ptrCast(@alignCast(ud.?));
        if (st.done) return;
        st.done = true;
        const d = dbus.child(params, 0);
        defer dbus.unref(d);
        st.dismissed = glib.Variant.getBoolean(d) != 0;
        st.result = dbus.child(params, 1);
    }
};
