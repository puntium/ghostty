//! Connection log: the port of electron/log.js.
//!
//! Two sinks fed from one `push`: a bounded in-memory ring (3000 entries)
//! that the log window renders and tails live, and an append-only file
//! (`$XDG_STATE_HOME/webmux-gtk/logs/webmux.log`, rolled once to `.1` when it
//! has grown past 1 MiB). Entries have the log.js shape
//! `{ seq, t, level, src, conn, msg, data }` and the file gets one
//! `<iso> LEVEL [conn] msg k=v…` line each, byte-for-byte the log.js format.
//!
//! Nothing here may ever see a secret: callers log ssh argument lists (the
//! password travels in the child's environment, never argv) and never the
//! spawn environment.
//!
//! Thread-safe: every public function may be called from any thread.
//! Subscribers are invoked on the thread that pushed the entry, after the
//! log's lock is released, so a subscriber may call back into the log.
const Log = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

pub const MAX_ENTRIES = 3000;
pub const LOG_FILE_MAX = 1024 * 1024;
pub const MAX_MSG = 500;
pub const MAX_DATA_STRING = 300;
pub const MAX_CONN = 80;
pub const MAX_FIELDS = 12;

pub const Level = enum {
    debug,
    info,
    warn,
    @"error",

    pub fn upper(l: Level) []const u8 {
        return switch (l) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
        };
    }

    /// log.js: `LEVELS.includes(level) ? level : 'info'`.
    pub fn parse(s: []const u8) Level {
        return std.meta.stringToEnum(Level, s) orelse .info;
    }
};

/// Who produced the entry: the client itself, or a host page reporting in
/// (in this client: the terminal/file panes, standing in for the Electron
/// page's `POST /log`).
pub const Source = enum { main, page };

/// One `data` value. `json` is pre-serialized JSON text (an object or
/// array); like log.js it is kept as a (clipped) string and shown quoted.
pub const Value = union(enum) {
    str: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    null,
    json: []const u8,
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// An entry as stored and handed to subscribers. All slices are owned by
/// the log (ring entries) and are valid until the entry leaves the ring;
/// subscribers must copy what they keep.
pub const Entry = struct {
    seq: u64,
    /// ISO-8601 UTC with milliseconds, as JS `Date.toISOString()`.
    t: []const u8,
    level: Level,
    src: Source,
    conn: ?[]const u8,
    msg: []const u8,
    data: []const Field,

    /// The file-format line (no trailing newline): what log.js `formatLine`
    /// produces, and what the log window's copy buttons hand out.
    pub fn format(e: *const Entry, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{s} ", .{e.t});
        const up = e.level.upper();
        try w.writeAll(up);
        for (up.len..5) |_| try w.writeByte(' ');
        try w.writeByte(' ');
        if (e.conn) |c| try w.print("[{s}] ", .{c});
        if (e.src == .page) try w.writeAll("page: ");
        try w.writeAll(e.msg);
        for (e.data) |f| {
            try w.print(" {s}=", .{f.key});
            try fmtValue(f.value, w);
        }
    }

    pub fn lineAlloc(e: *const Entry, alloc: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        e.format(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

/// Small values inline as key=value; anything else is JSON. Strings with
/// anything outside `[\w./:@~-]` get JSON-quoted (log.js `fmtValue`).
fn fmtValue(v: Value, w: *Io.Writer) Io.Writer.Error!void {
    switch (v) {
        .str => |s| {
            if (s.len > 0 and plainString(s)) try w.writeAll(s) else try util.writeJsonString(w, s);
        },
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try util.writeJsNumber(w, f),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        // log.js sanitizeData turns non-scalars into JSON *strings*, which
        // fmtValue then shows quoted.
        .json => |j| try util.writeJsonString(w, j),
    }
}

fn plainString(s: []const u8) bool {
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '/', ':', '@', '~', '-' => {},
        else => return false,
    };
    return true;
}

/// log.js sanitizeData: plain keys (`^[A-Za-z_]\w{0,31}$`), at most 12
/// fields considered, strings and JSON clipped to 300 chars plus `…`.
fn validKey(k: []const u8) bool {
    if (k.len == 0 or k.len > 32) return false;
    if (!(std.ascii.isAlphabetic(k[0]) or k[0] == '_')) return false;
    for (k[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub const Subscriber = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, entry: *const Entry) void,
};

const StoredEntry = struct {
    entry: Entry,
    arena: std.heap.ArenaAllocator,
};

alloc: Allocator,
io: Io,
mutex: Io.Mutex = .init,
/// Ring storage: `ring[(head + i) % MAX_ENTRIES]` for `i < len`.
ring: []?*StoredEntry,
head: usize = 0,
len: usize = 0,
seq: u64 = 0,
file_path: ?[]u8 = null,
file_size: u64 = 0,
subs: std.ArrayList(SubSlot) = .empty,
next_sub: u64 = 1,
/// Test hook: overrides the clock for `t` (ISO string).
fixed_time: ?[]const u8 = null,
/// Bytes before rolling; LOG_FILE_MAX except in tests.
file_max: u64 = LOG_FILE_MAX,

const SubSlot = struct { id: u64, sub: Subscriber };

pub fn init(alloc: Allocator, io: Io) !*Log {
    const self = try alloc.create(Log);
    errdefer alloc.destroy(self);
    const ring = try alloc.alloc(?*StoredEntry, MAX_ENTRIES);
    @memset(ring, null);
    self.* = .{ .alloc = alloc, .io = io, .ring = ring };
    return self;
}

pub fn deinit(self: *Log) void {
    for (self.ring) |slot| if (slot) |s| self.freeStored(s);
    self.alloc.free(self.ring);
    if (self.file_path) |p| self.alloc.free(p);
    self.subs.deinit(self.alloc);
    self.alloc.destroy(self);
}

fn freeStored(self: *Log, s: *StoredEntry) void {
    s.arena.deinit();
    self.alloc.destroy(s);
}

/// Point the file sink at a directory (created if missing). Until called,
/// entries only accumulate in memory.
pub fn initFile(self: *Log, dir: []const u8) !void {
    util.makePath(self.io, dir, 0o700) catch {};
    const path = try std.fs.path.join(self.alloc, &.{ dir, "webmux.log" });
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.file_path) |p| self.alloc.free(p);
    self.file_path = path;
    self.file_size = blk: {
        const st = Io.Dir.cwd().statFile(self.io, path, .{}) catch break :blk 0;
        break :blk st.size;
    };
}

/// The log file path, or null when there is no file sink. Owned by the log.
pub fn filePath(self: *Log) ?[]const u8 {
    return self.file_path;
}

pub const PushOptions = struct {
    level: Level = .info,
    src: Source = .main,
    conn: ?[]const u8 = null,
    msg: []const u8,
    data: []const Field = &.{},
};

/// The one write path. Returns the sequence number of the new entry.
pub fn push(self: *Log, opts: PushOptions) u64 {
    const stored = self.makeEntry(opts) catch return 0;
    var line_buf: [8192]u8 = undefined;
    var line_heap: ?[]u8 = null;
    defer if (line_heap) |l| self.alloc.free(l);

    // Format outside the lock where possible; seq/time need the lock.
    self.mutex.lockUncancelable(self.io);
    self.seq += 1;
    stored.entry.seq = self.seq;
    const line: []const u8 = blk: {
        var w: Io.Writer = .fixed(&line_buf);
        if (stored.entry.format(&w)) |_| {
            w.writeByte('\n') catch {};
            if (w.end < line_buf.len) break :blk w.buffered();
        } else |_| {}
        const l = stored.entry.lineAlloc(self.alloc) catch break :blk "";
        const withnl = std.mem.concat(self.alloc, u8, &.{ l, "\n" }) catch {
            self.alloc.free(l);
            break :blk "";
        };
        self.alloc.free(l);
        line_heap = withnl;
        break :blk withnl;
    };
    self.appendFile(line);
    // ring insert
    if (self.len == MAX_ENTRIES) {
        if (self.ring[self.head]) |old| self.freeStored(old);
        self.ring[self.head] = stored;
        self.head = (self.head + 1) % MAX_ENTRIES;
    } else {
        self.ring[(self.head + self.len) % MAX_ENTRIES] = stored;
        self.len += 1;
    }
    // Copy the subscriber list so callbacks run unlocked.
    var subs_buf: [16]SubSlot = undefined;
    const n = @min(self.subs.items.len, subs_buf.len);
    @memcpy(subs_buf[0..n], self.subs.items[0..n]);
    // Entry may be evicted by a concurrent push once we unlock; hand
    // subscribers a private copy.
    var copy_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer copy_arena.deinit();
    const copy = if (n > 0) cloneEntry(copy_arena.allocator(), &stored.entry) catch null else null;
    const seq = self.seq;
    self.mutex.unlock(self.io);

    if (copy) |c| for (subs_buf[0..n]) |s| s.sub.func(s.sub.ctx, &c);
    return seq;
}

fn makeEntry(self: *Log, opts: PushOptions) !*StoredEntry {
    const s = try self.alloc.create(StoredEntry);
    errdefer self.alloc.destroy(s);
    s.arena = std.heap.ArenaAllocator.init(self.alloc);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    var t_buf: [32]u8 = undefined;
    const t = if (self.fixed_time) |ft| ft else util.isoNow(self.io, &t_buf);

    var fields: std.ArrayList(Field) = .empty;
    for (opts.data[0..@min(opts.data.len, MAX_FIELDS)]) |f| {
        if (!validKey(f.key)) continue;
        const v: Value = switch (f.value) {
            .str => |str| .{ .str = try clip(a, str, MAX_DATA_STRING) },
            .json => |j| .{ .json = try clip(a, j, MAX_DATA_STRING) },
            else => f.value,
        };
        try fields.append(a, .{ .key = try a.dupe(u8, f.key), .value = v });
    }
    s.entry = .{
        .seq = 0,
        .t = try a.dupe(u8, t),
        .level = opts.level,
        .src = opts.src,
        .conn = if (opts.conn) |c| try a.dupe(u8, util.clipChars(c, MAX_CONN)) else null,
        .msg = try a.dupe(u8, util.clipChars(opts.msg, MAX_MSG)),
        .data = fields.items,
    };
    return s;
}

/// Clip to `max` characters, appending `…` when clipped (sanitizeData).
fn clip(a: Allocator, s: []const u8, max: usize) ![]const u8 {
    const c = util.clipChars(s, max);
    if (c.len == s.len) return a.dupe(u8, s);
    return std.mem.concat(a, u8, &.{ c, "…" });
}

fn cloneEntry(a: Allocator, e: *const Entry) !Entry {
    const fields = try a.alloc(Field, e.data.len);
    for (e.data, fields) |src, *dst| {
        dst.key = try a.dupe(u8, src.key);
        dst.value = switch (src.value) {
            .str => |s| .{ .str = try a.dupe(u8, s) },
            .json => |s| .{ .json = try a.dupe(u8, s) },
            else => src.value,
        };
    }
    return .{
        .seq = e.seq,
        .t = try a.dupe(u8, e.t),
        .level = e.level,
        .src = e.src,
        .conn = if (e.conn) |c| try a.dupe(u8, c) else null,
        .msg = try a.dupe(u8, e.msg),
        .data = fields,
    };
}

/// Caller holds the mutex. A full or read-only disk must never take the
/// client down; the ring and the window still work.
fn appendFile(self: *Log, line: []const u8) void {
    const path = self.file_path orelse return;
    if (line.len == 0) return;
    if (self.file_size > self.file_max) {
        var buf: [4096]u8 = undefined;
        const rolled = std.fmt.bufPrint(&buf, "{s}.1", .{path}) catch return;
        Io.Dir.cwd().rename(path, Io.Dir.cwd(), rolled, self.io) catch return;
        self.file_size = 0;
    }
    util.appendToFile(self.io, path, line) catch return;
    self.file_size += line.len;
}

pub fn debug(self: *Log, conn: ?[]const u8, msg: []const u8, data: []const Field) void {
    _ = self.push(.{ .level = .debug, .conn = conn, .msg = msg, .data = data });
}
pub fn info(self: *Log, conn: ?[]const u8, msg: []const u8, data: []const Field) void {
    _ = self.push(.{ .level = .info, .conn = conn, .msg = msg, .data = data });
}
pub fn warn(self: *Log, conn: ?[]const u8, msg: []const u8, data: []const Field) void {
    _ = self.push(.{ .level = .warn, .conn = conn, .msg = msg, .data = data });
}
pub fn err(self: *Log, conn: ?[]const u8, msg: []const u8, data: []const Field) void {
    _ = self.push(.{ .level = .@"error", .conn = conn, .msg = msg, .data = data });
}
pub fn at(self: *Log, level: Level, conn: ?[]const u8, msg: []const u8, data: []const Field) void {
    _ = self.push(.{ .level = level, .conn = conn, .msg = msg, .data = data });
}

/// printf-style message convenience.
pub fn atf(self: *Log, level: Level, conn: ?[]const u8, data: []const Field, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        break :blk buf[0..];
    };
    self.at(level, conn, msg, data);
}

/// A copy of the ring entries with `seq > after_seq` (all of them for 0),
/// each with its file-format line. Free with `Snapshot.deinit`.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    lines: [][]const u8,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

pub fn since(self: *Log, alloc: Allocator, after_seq: u64) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var count: usize = 0;
    for (0..self.len) |i| {
        const s = self.ring[(self.head + i) % MAX_ENTRIES].?;
        if (s.entry.seq > after_seq) count += 1;
    }
    const entries = try a.alloc(Entry, count);
    const lines = try a.alloc([]const u8, count);
    var j: usize = 0;
    for (0..self.len) |i| {
        const s = self.ring[(self.head + i) % MAX_ENTRIES].?;
        if (s.entry.seq <= after_seq) continue;
        entries[j] = try cloneEntry(a, &s.entry);
        lines[j] = try entries[j].lineAlloc(a);
        j += 1;
    }
    return .{ .arena = arena, .entries = entries, .lines = lines };
}

/// Everything currently in memory as the text the file holds (log.js `text`).
pub fn text(self: *Log, alloc: Allocator) ![]u8 {
    var snap = try self.since(alloc, 0);
    defer snap.deinit();
    return std.mem.join(alloc, "\n", snap.lines);
}

/// Empty the ring (the file is untouched) and log that it happened.
pub fn clear(self: *Log) void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (0..self.len) |i| {
            const idx = (self.head + i) % MAX_ENTRIES;
            if (self.ring[idx]) |s| self.freeStored(s);
            self.ring[idx] = null;
        }
        self.head = 0;
        self.len = 0;
    }
    self.info(null, "log cleared (file untouched)", &.{});
}

/// Live subscription; returns an id for `unsubscribe`. The callback runs on
/// whichever thread pushed the entry (supervisor threads, mostly), and the
/// entry it gets is valid only for the duration of the call.
pub fn subscribe(self: *Log, sub: Subscriber) !u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const id = self.next_sub;
    self.next_sub += 1;
    try self.subs.append(self.alloc, .{ .id = id, .sub = sub });
    return id;
}

pub fn unsubscribe(self: *Log, id: u64) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.subs.items, 0..) |s, i| if (s.id == id) {
        _ = self.subs.orderedRemove(i);
        return;
    };
}

/// Push an entry supplied by an untrusted-ish source as JSON
/// (`{ level, msg, data }`, as the Electron pages POST to /log), sanitized
/// like log.js: level whitelist, clipped message, plain keys only, scalars
/// kept, anything else re-serialized and clipped.
pub fn pushJson(self: *Log, conn: ?[]const u8, src: Source, v: std.json.Value) void {
    if (v != .object) return;
    const o = v.object;
    const level: Level = if (o.get("level")) |l| (if (l == .string) Level.parse(l.string) else .info) else .info;
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const msg: []const u8 = if (o.get("msg")) |m| switch (m) {
        .string => |s| s,
        .null => "",
        else => std.json.Stringify.valueAlloc(a, m, .{}) catch "",
    } else "";
    var fields: std.ArrayList(Field) = .empty;
    if (o.get("data")) |d| if (d == .object) {
        var it = d.object.iterator();
        var considered: usize = 0;
        while (it.next()) |kv| {
            considered += 1;
            if (considered > MAX_FIELDS) break;
            const val: Value = switch (kv.value_ptr.*) {
                .string => |s| .{ .str = s },
                .integer => |i| .{ .int = i },
                .float => |f| .{ .float = f },
                .number_string => |s| .{ .json = s },
                .bool => |b| .{ .boolean = b },
                .null => .null,
                else => .{ .json = std.json.Stringify.valueAlloc(a, kv.value_ptr.*, .{}) catch continue },
            };
            fields.append(a, .{ .key = kv.key_ptr.*, .value = val }) catch break;
        }
    };
    _ = self.push(.{ .level = level, .src = src, .conn = conn, .msg = msg, .data = fields.items });
}
