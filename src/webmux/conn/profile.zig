//! Profiles, client-wide settings and the config store
//! (`$XDG_CONFIG_HOME/webmux-gtk/config.json`): the port of main.js's
//! profile store (PROFILE_DEFAULTS, sanitizeSettings, profiles:save,
//! profiles:delete) minus `passwordEnc` and `localPort`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

/// A connection profile. All strings are owned by whoever owns the Profile
/// (see `clone`/`deinit`).
pub const Profile = struct {
    /// Stable random id (16 hex chars), generated when the profile is first
    /// saved and kept across renames. The Secret Service entry for the
    /// profile's password is keyed by it.
    id: []const u8 = "",
    name: []const u8 = "",
    /// Anything ssh accepts, ~/.ssh/config aliases included.
    host: []const u8 = "",
    /// 0 = ssh default (22 / per ssh_config). Kept as read even above
    /// 65535 (a hand edit): connecting then fails with `PORT_ERROR`
    /// instead of silently using the default port.
    ssh_port: u32 = 0,
    /// Optional `-i` path.
    identity_file: []const u8 = "",
    /// Which webmux instance to run on the host (blank = "default"). It is
    /// interpolated into remote shell commands: see `validInstance`.
    instance: []const u8 = "",
    /// Extra ssh args, whitespace-separated.
    extra_options: []const u8 = "",
    /// Where this profile's last file-browser download was saved.
    download_dir: []const u8 = "",

    pub fn clone(p: Profile, a: Allocator) !Profile {
        return .{
            .id = try a.dupe(u8, p.id),
            .name = try a.dupe(u8, p.name),
            .host = try a.dupe(u8, p.host),
            .ssh_port = p.ssh_port,
            .identity_file = try a.dupe(u8, p.identity_file),
            .instance = try a.dupe(u8, p.instance),
            .extra_options = try a.dupe(u8, p.extra_options),
            .download_dir = try a.dupe(u8, p.download_dir),
        };
    }

    pub fn deinit(p: Profile, a: Allocator) void {
        inline for (.{ "id", "name", "host", "identity_file", "instance", "extra_options", "download_dir" }) |f|
            a.free(@field(p, f));
    }

    /// `instance || 'default'`.
    pub fn instanceOrDefault(p: Profile) []const u8 {
        return if (p.instance.len == 0) "default" else p.instance;
    }
};

/// main.js: blank or `^[A-Za-z0-9._-]+$` — the instance name lands in remote
/// shell commands, so it must stay shell-inert.
pub fn validInstance(s: []const u8) bool {
    for (s) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

pub const INSTANCE_ERROR = "instance name must be blank (default) or letters, digits, . _ -";

pub const PORT_ERROR = "SSH port must be a whole number from 1 to 65535 (blank = ssh's default)";

pub fn validPort(port: u32) bool {
    return port <= 65535;
}

/// The per-host key (main.js `appOrigin` without the scheme): a slug of
/// the host plus a short hash of host+instance, so sanitization can't
/// collide two hosts. Stable across profile renames. Written into `out`.
pub fn hostSlug(host: []const u8, instance: []const u8, out: []u8) ![]const u8 {
    var hex: [64]u8 = undefined;
    util.sha256Hex(&.{ host, "\n", if (instance.len == 0) "default" else instance }, &hex);
    var w: Io.Writer = .fixed(out);
    // lowercase, runs of [^a-z0-9-] → '-', then trim leading/trailing '-'
    var base_buf: [512]u8 = undefined;
    var n: usize = 0;
    var in_run = false;
    for (host) |ch0| {
        const ch = std.ascii.toLower(ch0);
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-';
        if (ok) {
            in_run = false;
            if (n < base_buf.len) {
                base_buf[n] = ch;
                n += 1;
            }
        } else if (!in_run) {
            in_run = true;
            if (n < base_buf.len) {
                base_buf[n] = '-';
                n += 1;
            }
        }
    }
    const base = std.mem.trim(u8, base_buf[0..n], "-");
    if (base.len > 0) {
        w.print("{s}-{s}", .{ base, hex[0..8] }) catch return error.NoSpaceLeft;
    } else {
        w.writeAll(hex[0..8]) catch return error.NoSpaceLeft;
    }
    return w.buffered();
}

/// Client-wide UI settings (main.js SETTINGS_DEFAULTS / ui/settings.js).
pub const Settings = struct {
    /// Theme id: `[a-z0-9-]{1,32}`; the UI falls back to dark for ids it
    /// doesn't know (`dark`, `light` today).
    theme: Theme = .{},
    /// Unfocused-pane fade, 0..100 (percent).
    unfocused_fade: u8 = 40,
    /// Minimum and maximum column widths in terminal cells, 40..400,
    /// max >= min.
    min_cols: u16 = 90,
    max_cols: u16 = 200,

    pub const Theme = struct {
        buf: [32]u8 = "dark".* ++ @as([28]u8, @splat(0)),
        len: u8 = 4,
        pub fn slice(t: *const Theme) []const u8 {
            return t.buf[0..t.len];
        }
        pub fn set(t: *Theme, s: []const u8) bool {
            if (!validTheme(s)) return false;
            @memcpy(t.buf[0..s.len], s);
            t.len = @intCast(s.len);
            return true;
        }
    };
};

fn validTheme(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    for (s) |ch| switch (ch) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// A partial settings update. Numbers follow JS `Number()` semantics in
/// the JSON path (`sanitizeSettingsJson`); here they are plain floats, and
/// NaN/inf leave the field unchanged.
pub const SettingsPatch = struct {
    theme: ?[]const u8 = null,
    unfocused_fade: ?f64 = null,
    min_cols: ?f64 = null,
    max_cols: ?f64 = null,
};

fn jsRound(x: f64) f64 {
    return @floor(x + 0.5);
}

fn clampRound(x: f64, lo: f64, hi: f64) f64 {
    return jsRound(@min(hi, @max(lo, x)));
}

/// main.js sanitizeSettings(raw, base): unknown or malformed fields keep
/// their base value, numbers are clamped and rounded, and the column range
/// stays a range whichever end moved.
pub fn sanitizeSettings(base: Settings, patch: SettingsPatch) Settings {
    var s = base;
    if (patch.theme) |t| _ = s.theme.set(t);
    if (patch.unfocused_fade) |f| if (std.math.isFinite(f)) {
        s.unfocused_fade = @intFromFloat(clampRound(f, 0, 100));
    };
    if (patch.min_cols) |f| if (std.math.isFinite(f)) {
        s.min_cols = @intFromFloat(clampRound(f, 40, 400));
    };
    if (patch.max_cols) |f| if (std.math.isFinite(f)) {
        s.max_cols = @intFromFloat(clampRound(f, 40, 400));
    };
    if (s.max_cols < s.min_cols) s.max_cols = s.min_cols;
    return s;
}

/// JS `Number(v)` for a JSON value: numbers as is, strings parsed (blank →
/// 0, junk → NaN), booleans 0/1, null 0, arrays/objects NaN (a simplification
/// of JS's `[]` → 0 / `[x]` → Number(x)).
pub fn jsNumber(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch std.math.nan(f64),
        .bool => |b| if (b) 1 else 0,
        .null => 0,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
            if (t.len == 0) break :blk 0;
            if (std.mem.eql(u8, t, "Infinity") or std.mem.eql(u8, t, "+Infinity")) break :blk std.math.inf(f64);
            if (std.mem.eql(u8, t, "-Infinity")) break :blk -std.math.inf(f64);
            if (std.ascii.startsWithIgnoreCase(t, "0x")) {
                const n = std.fmt.parseInt(u64, t[2..], 16) catch break :blk std.math.nan(f64);
                break :blk @floatFromInt(n);
            }
            for (t) |ch| switch (ch) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => break :blk std.math.nan(f64),
            };
            break :blk std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
        },
        .array, .object => std.math.nan(f64),
    };
}

/// sanitizeSettings over a parsed JSON object (config.json, or a PUT-style
/// patch from the shell).
pub fn sanitizeSettingsJson(base: Settings, raw: ?std.json.Value) Settings {
    const v = raw orelse return sanitizeSettings(base, .{});
    if (v != .object) return sanitizeSettings(base, .{});
    const o = v.object;
    var p: SettingsPatch = .{};
    if (o.get("theme")) |t| if (t == .string) {
        p.theme = t.string;
    };
    if (o.get("unfocusedFade")) |x| p.unfocused_fade = jsNumber(x);
    if (o.get("minCols")) |x| p.min_cols = jsNumber(x);
    if (o.get("maxCols")) |x| p.max_cols = jsNumber(x);
    return sanitizeSettings(base, p);
}

/// The fields the profile form edits (profiles:save input).
pub const ProfileInput = struct {
    name: []const u8,
    host: []const u8,
    /// 0 = ssh's default; above 65535 is refused (`PORT_ERROR`).
    ssh_port: u32 = 0,
    /// The id for a new profile (null: generate one). Ignored when an
    /// existing profile is replaced (its id is kept). Lets the shell key a
    /// keyring entry before the profile is saved.
    id: ?[]const u8 = null,
    identity_file: []const u8 = "",
    instance: []const u8 = "",
    extra_options: []const u8 = "",
    /// null keeps the existing profile's value (the download hook maintains
    /// it, the form never shows it).
    download_dir: ?[]const u8 = null,
};

/// The in-memory store. Not thread-safe by itself; the Engine locks it.
pub const Store = struct {
    alloc: Allocator,
    profiles: std.ArrayList(Profile) = .empty,
    last_profile: ?[]u8 = null,
    settings: Settings = .{},
    /// What `loadJson` had to repair (user-facing lines, owned). Empty when
    /// the file was clean.
    repairs: std.ArrayList([]u8) = .empty,
    /// Ids that more than one profile carried: every such profile got a new
    /// id, and the secret stored under the old one must never be offered
    /// again (the shell forgets it).
    dropped_ids: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        for (self.profiles.items) |p| p.deinit(self.alloc);
        self.profiles.deinit(self.alloc);
        for (self.repairs.items) |r| self.alloc.free(r);
        self.repairs.deinit(self.alloc);
        for (self.dropped_ids.items) |r| self.alloc.free(r);
        self.dropped_ids.deinit(self.alloc);
        if (self.last_profile) |l| self.alloc.free(l);
    }

    pub fn find(self: *Store, name: []const u8) ?*Profile {
        for (self.profiles.items) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    pub fn findIndex(self: *Store, name: []const u8) ?usize {
        for (self.profiles.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
        return null;
    }

    pub fn setLastProfile(self: *Store, name: ?[]const u8) !void {
        const new = if (name) |n| try self.alloc.dupe(u8, n) else null;
        if (self.last_profile) |l| self.alloc.free(l);
        self.last_profile = new;
    }

    /// Parse config.json. A missing or unreadable file yields an empty
    /// store with default settings (main.js loadStore, minus the legacy
    /// migrations: this client has no history). Unknown fields are dropped.
    /// `error.InvalidConfig` when the text is not a JSON object: the store
    /// stays empty and the caller must not overwrite the file.
    pub fn loadJson(self: *Store, bytes: []const u8, io: Io) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, bytes, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidConfig,
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidConfig;
        if (root.object.get("profiles")) |profs| {
            if (profs != .array) {
                try self.repair("\"profiles\" is not a list: no profile could be read", .{});
            } else for (profs.array.items, 1..) |pv, n| {
                if (pv != .object) {
                    try self.repair("profile #{d} is not an object: dropped", .{n});
                    continue;
                }
                var p = try self.profileFromJsonChecked(pv.object, n);
                errdefer p.deinit(self.alloc);
                try self.profiles.append(self.alloc, p);
            }
        }
        try self.repairIds(io);
        if (root.object.get("lastProfile")) |l| switch (l) {
            .string => |str| if (str.len > 0) try self.setLastProfile(str),
            .null => {},
            else => try self.repair("\"lastProfile\" is not text: cleared", .{}),
        };
        try self.checkSettings(root.object.get("settings"));
        self.settings = sanitizeSettingsJson(.{}, root.object.get("settings"));
    }

    fn repair(self: *Store, comptime fmt: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(line);
        try self.repairs.append(self.alloc, line);
    }

    /// One profile, every field checked for its type (wrong types become
    /// empty, with a repair line).
    fn profileFromJsonChecked(self: *Store, o: std.json.ObjectMap, n: usize) !Profile {
        const a = self.alloc;
        const label: []const u8 = if (o.get("name")) |v| (if (v == .string and v.string.len > 0) util.clipChars(v.string, 80) else "") else "";
        var lb: [96]u8 = undefined;
        const who = if (label.len > 0) (std.fmt.bufPrint(&lb, "\"{s}\"", .{label}) catch "?") else (std.fmt.bufPrint(&lb, "profile #{d}", .{n}) catch "?");
        var p: Profile = .{};
        inline for (.{
            .{ "id", "id" },                       .{ "name", "name" },               .{ "host", "host" },
            .{ "identity_file", "identityFile" }, .{ "instance", "instance" },       .{ "extra_options", "extraOptions" },
            .{ "download_dir", "downloadDir" },
        }) |f| {
            const v = o.get(f[1]);
            const text: []const u8 = if (v) |x| switch (x) {
                .string => |str| str,
                .null => "",
                else => blk: {
                    try self.repair("{s}: \"{s}\" is not text: cleared", .{ who, f[1] });
                    break :blk "";
                },
            } else "";
            @field(p, f[0]) = try a.dupe(u8, text);
        }
        errdefer p.deinit(a);
        if (o.get("sshPort")) |v| {
            if (portFromJson(v)) |port| {
                p.ssh_port = port;
            } else {
                var vb: [64]u8 = undefined;
                try self.repair("{s}: \"sshPort\" {s} is not a port (a whole number 1–65535): set to ssh's default", .{ who, jsonShort(v, &vb) });
            }
        }
        if (p.name.len == 0) {
            a.free(p.name);
            p.name = try std.fmt.allocPrint(a, "profile {d}", .{n});
            try self.repair("profile #{d} has no name: named \"{s}\"", .{ n, p.name });
        }
        if (self.find(p.name) != null) {
            var k: usize = 2;
            while (true) : (k += 1) {
                const cand = try std.fmt.allocPrint(a, "{s} ({d})", .{ p.name, k });
                if (self.find(cand) == null) {
                    try self.repair("two profiles are named \"{s}\": the second is now \"{s}\"", .{ util.clipChars(p.name, 80), cand });
                    a.free(p.name);
                    p.name = cand;
                    break;
                }
                a.free(cand);
            }
        }
        if (p.host.len == 0) try self.repair("\"{s}\" has no host: it cannot connect until one is set", .{util.clipChars(p.name, 80)});
        return p;
    }

    /// Every profile gets an id of its own: missing or malformed ids are
    /// generated, and an id more than one profile carries (a copied block)
    /// is replaced in all of them; the secret stored under it is dropped,
    /// since it cannot be known which host it was saved for.
    fn repairIds(self: *Store, io: Io) !void {
        const a = self.alloc;
        const items = self.profiles.items;
        for (items, 0..) |*p, i| {
            if (!validId(p.id)) {
                if (p.id.len > 0)
                    try self.repair("\"{s}\": its id is malformed: given a new one", .{util.clipChars(p.name, 80)})
                else
                    try self.repair("\"{s}\" has no id: given one", .{util.clipChars(p.name, 80)});
                a.free(p.id);
                p.id = try a.dupe(u8, "");
                continue;
            }
            var shared = false;
            for (items, 0..) |q, j| if (i != j and std.ascii.eqlIgnoreCase(q.id, p.id)) {
                shared = true;
            };
            if (shared) {
                var known = false;
                var exact = false;
                for (self.dropped_ids.items) |d| {
                    if (std.ascii.eqlIgnoreCase(d, p.id)) known = true;
                    if (std.mem.eql(u8, d, p.id)) exact = true;
                }
                // Every spelling is dropped: the keyring matches ids
                // exactly, so a secret may sit under any of them.
                if (known and !exact) try self.dropped_ids.append(a, try a.dupe(u8, p.id));
                if (!known) {
                    var names: std.ArrayList(u8) = .empty;
                    defer names.deinit(a);
                    for (items) |q| if (std.ascii.eqlIgnoreCase(q.id, p.id)) {
                        if (names.items.len > 0) try names.appendSlice(a, ", ");
                        try names.print(a, "\"{s}\"", .{util.clipChars(q.name, 80)});
                    };
                    try self.repair("{s} had the same id: each was given a new one, and a password saved under it was cleared (re-enter it)", .{names.items});
                    try self.dropped_ids.append(a, try a.dupe(u8, p.id));
                }
            }
        }
        // second pass: give fresh ids (after the scan, so every member of a
        // group was seen with its old id)
        for (items) |*p| {
            var reissue = p.id.len == 0;
            for (self.dropped_ids.items) |d| if (std.ascii.eqlIgnoreCase(d, p.id)) {
                reissue = true;
            };
            if (!reissue) continue;
            // (the new id first: freeing first would let the allocator hand
            // the same bytes back, and `uniqueId` would see them in use)
            const id = try self.uniqueId(io);
            a.free(p.id);
            p.id = id;
        }
    }

    /// A new id no profile has.
    pub fn uniqueId(self: *Store, io: Io) ![]u8 {
        while (true) {
            const id = try newId(self.alloc, io);
            var used = false;
            for (self.profiles.items) |q| if (std.ascii.eqlIgnoreCase(q.id, id)) {
                used = true;
            };
            for (self.dropped_ids.items) |d| if (std.ascii.eqlIgnoreCase(d, id)) {
                used = true;
            };
            if (!used) return id;
            self.alloc.free(id);
        }
    }

    pub fn idInUse(self: *Store, id: []const u8) bool {
        for (self.profiles.items) |q| if (std.ascii.eqlIgnoreCase(q.id, id)) return true;
        for (self.dropped_ids.items) |d| if (std.ascii.eqlIgnoreCase(d, id)) return true;
        return false;
    }

    fn checkSettings(self: *Store, raw: ?std.json.Value) !void {
        const v = raw orelse return;
        if (v == .null) return;
        if (v != .object) return self.repair("\"settings\" is not an object: defaults used", .{});
        const o = v.object;
        if (o.get("theme")) |t| {
            var tmp: Settings.Theme = .{};
            if (t != .string or !tmp.set(t.string)) try self.repair("settings: \"theme\" is not a theme name: dark used", .{});
        }
        inline for (.{ .{ "unfocusedFade", 0, 100 }, .{ "minCols", 40, 400 }, .{ "maxCols", 40, 400 } }) |f| {
            if (o.get(f[0])) |x| {
                const ok = switch (x) {
                    .integer => |i| i >= f[1] and i <= f[2],
                    .float => |fl| std.math.isFinite(fl) and fl >= f[1] and fl <= f[2],
                    else => false,
                };
                if (!ok) {
                    var vb: [64]u8 = undefined;
                    try self.repair("settings: \"{s}\" {s} is not a number from {d} to {d}: adjusted", .{ f[0], jsonShort(x, &vb), f[1], f[2] });
                }
            }
        }
    }

    /// Serialize as `JSON.stringify(store, null, 2) + '\n'`.
    pub fn toJson(self: *Store, alloc: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        writeStore(self, &s) catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn writeStore(self: *Store, s: *std.json.Stringify) !void {
        try s.beginObject();
        try s.objectField("profiles");
        try s.beginArray();
        for (self.profiles.items) |p| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(p.name);
            try s.objectField("host");
            try s.write(p.host);
            try s.objectField("sshPort");
            try s.write(p.ssh_port);
            try s.objectField("identityFile");
            try s.write(p.identity_file);
            try s.objectField("instance");
            try s.write(p.instance);
            try s.objectField("extraOptions");
            try s.write(p.extra_options);
            try s.objectField("downloadDir");
            try s.write(p.download_dir);
            try s.objectField("id");
            try s.write(p.id);
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("lastProfile");
        try s.write(self.last_profile);
        try s.objectField("settings");
        try s.beginObject();
        try s.objectField("theme");
        try s.write(self.settings.theme.slice());
        try s.objectField("unfocusedFade");
        try s.write(self.settings.unfocused_fade);
        try s.objectField("minCols");
        try s.write(self.settings.min_cols);
        try s.objectField("maxCols");
        try s.write(self.settings.max_cols);
        try s.endObject();
        try s.endObject();
    }

    pub const SaveError = error{OutOfMemory};

    /// main.js profiles:save. Returns null on success or a user-facing error
    /// string (static, or formatted into `err_buf`). `original_name` is the
    /// name the form was editing (null for a new profile).
    /// The checks of `save`, in main.js's order, without saving.
    pub fn validate(self: *Store, input: ProfileInput, original_name: ?[]const u8, err_buf: *[256]u8) ?[]const u8 {
        const name = std.mem.trim(u8, input.name, " \t\r\n");
        const host = std.mem.trim(u8, input.host, " \t\r\n");
        const instance = std.mem.trim(u8, input.instance, " \t\r\n");
        if (instance.len > 0 and !validInstance(instance)) return INSTANCE_ERROR;
        if (!validPort(input.ssh_port)) return PORT_ERROR;
        if (name.len == 0 or host.len == 0) return "name and host are required";
        if ((original_name == null or !std.mem.eql(u8, name, original_name.?)) and self.find(name) != null) {
            return std.fmt.bufPrint(err_buf, "a profile named \"{s}\" already exists", .{util.clipChars(name, 200)}) catch "a profile with that name already exists";
        }
        return null;
    }

    pub fn save(self: *Store, io: Io, input: ProfileInput, original_name: ?[]const u8, err_buf: *[256]u8) SaveError!?[]const u8 {
        if (self.validate(input, original_name, err_buf)) |msg| return msg;
        const name = std.mem.trim(u8, input.name, " \t\r\n");
        const host = std.mem.trim(u8, input.host, " \t\r\n");
        const instance = std.mem.trim(u8, input.instance, " \t\r\n");
        const existing = self.find(original_name orelse name);
        const a = self.alloc;
        const new_id = blk: {
            if (input.id) |id| if (validId(id) and !self.idInUse(id)) break :blk try a.dupe(u8, id);
            break :blk try self.uniqueId(io);
        };
        var p: Profile = .{
            .id = if (existing) |e| blk: {
                a.free(new_id);
                break :blk try a.dupe(u8, e.id);
            } else new_id,
            .name = try a.dupe(u8, name),
            .host = try a.dupe(u8, host),
            .ssh_port = input.ssh_port,
            // connect.html trims these two before saving
            .identity_file = try a.dupe(u8, std.mem.trim(u8, input.identity_file, " \t\r\n")),
            .instance = try a.dupe(u8, instance),
            .extra_options = try a.dupe(u8, std.mem.trim(u8, input.extra_options, " \t\r\n")),
            .download_dir = try a.dupe(u8, input.download_dir orelse if (existing) |e| e.download_dir else ""),
        };
        errdefer p.deinit(a);
        if (self.findIndex(original_name orelse name)) |idx| {
            self.profiles.items[idx].deinit(a);
            self.profiles.items[idx] = p;
        } else {
            try self.profiles.append(a, p);
        }
        if (original_name) |orig| if (!std.mem.eql(u8, orig, name)) {
            if (self.last_profile) |l| if (std.mem.eql(u8, l, orig)) try self.setLastProfile(name);
        };
        return null;
    }

    /// main.js profiles:delete (the store half).
    pub fn delete(self: *Store, name: []const u8) !void {
        if (self.findIndex(name)) |idx| {
            self.profiles.items[idx].deinit(self.alloc);
            _ = self.profiles.orderedRemove(idx);
        }
        if (self.last_profile) |l| if (std.mem.eql(u8, l, name)) try self.setLastProfile(null);
    }
};

fn jsonStr(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}


/// Deviation 39: a port is a whole number from 1 to 65535 written in
/// decimal (0 or absent = ssh's default). From JSON: an integer, or a
/// string of decimal digits; anything else is not a port (null).
pub fn portFromJson(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= 65535) @intCast(i) else null,
        .string => |str| parsePort(str),
        .null => 0,
        else => null,
    };
}

/// The form's rule: blank = 0 (default); else decimal digits only, 1–65535.
pub fn parsePort(text: []const u8) ?u32 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return 0;
    if (t.len > 5) return null;
    for (t) |ch| if (ch < '0' or ch > '9') return null;
    const n = std.fmt.parseInt(u32, t, 10) catch return null;
    if (n == 0 or n > 65535) return null;
    return n;
}

fn jsonShort(v: std.json.Value, buf: []u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    std.json.Stringify.value(v, .{}, &w) catch {};
    const out = w.buffered();
    if (out.len >= buf.len - 1) return "(a long value)";
    return out;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

pub fn newId(a: Allocator, io: Io) ![]u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return a.dupe(u8, &hex);
}
