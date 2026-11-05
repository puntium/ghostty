//! Where things live locally (docs/native-client.md › Local state), all
//! derived from an environment map so tests never touch the real HOME.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const util = @import("util.zig");

pub const APP_DIR = "webmux-gtk";

/// Resolved directories. Strings are owned (see `deinit`).
pub const Paths = struct {
    /// `$XDG_CONFIG_HOME/webmux-gtk` (default `~/.config/webmux-gtk`).
    config_dir: []u8,
    /// `$XDG_STATE_HOME/webmux-gtk` (default `~/.local/state/webmux-gtk`).
    state_dir: []u8,
    /// `$XDG_RUNTIME_DIR/webmux-gtk` (fallback `/tmp/webmux-gtk-<uid>`),
    /// 0700: tunnel sockets and the askpass helper.
    runtime_dir: []u8,
    /// Payload dir (holding payload.json + <key>/payload.tar.gz), or null
    /// when none was found.
    payload_dir: ?[]u8,

    pub fn deinit(p: Paths, a: Allocator) void {
        a.free(p.config_dir);
        a.free(p.state_dir);
        a.free(p.runtime_dir);
        if (p.payload_dir) |d| a.free(d);
    }

    pub fn configFile(p: Paths, a: Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ p.config_dir, "config.json" });
    }

    pub fn logDir(p: Paths, a: Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ p.state_dir, "logs" });
    }
};

/// XDG base dir: the variable if set to an absolute path, else
/// `$HOME/<fallback>`.
fn xdg(a: Allocator, env: *const EnvMap, name: []const u8, home_rel: []const u8) ![]u8 {
    if (env.get(name)) |v| if (v.len > 0 and v[0] == '/') return std.fs.path.join(a, &.{ v, APP_DIR });
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(a, &.{ home, home_rel, APP_DIR });
}

pub fn resolve(a: Allocator, io: Io, env: *const EnvMap, exe_dir: ?[]const u8) !Paths {
    const config_dir = try xdg(a, env, "XDG_CONFIG_HOME", ".config");
    errdefer a.free(config_dir);
    const state_dir = try xdg(a, env, "XDG_STATE_HOME", ".local/state");
    errdefer a.free(state_dir);
    const runtime_dir = blk: {
        if (env.get("XDG_RUNTIME_DIR")) |v| if (v.len > 0 and v[0] == '/')
            break :blk try std.fs.path.join(a, &.{ v, APP_DIR });
        break :blk try std.fmt.allocPrint(a, "/tmp/{s}-{d}", .{ APP_DIR, std.c.getuid() });
    };
    errdefer a.free(runtime_dir);
    const payload_dir = try findPayloadDir(a, io, env, exe_dir);
    return .{ .config_dir = config_dir, .state_dir = state_dir, .runtime_dir = runtime_dir, .payload_dir = payload_dir };
}

/// `$WEBMUX_PAYLOAD_DIR`, else `<exe dir>/../share/webmux-gtk/payload`,
/// else `electron/payload` found by walking up from the executable (a
/// checkout). The latter two must hold a payload.json to count.
pub fn findPayloadDir(a: Allocator, io: Io, env: *const EnvMap, exe_dir_opt: ?[]const u8) !?[]u8 {
    if (env.get("WEBMUX_PAYLOAD_DIR")) |d| if (d.len > 0) return try a.dupe(u8, d);
    var exe_buf: [4096]u8 = undefined;
    const exe_dir = exe_dir_opt orelse blk: {
        const n = std.process.executableDirPath(io, &exe_buf) catch return null;
        break :blk exe_buf[0..n];
    };
    {
        const share = try std.fs.path.resolve(a, &.{ exe_dir, "..", "share", APP_DIR, "payload" });
        if (hasManifest(a, share)) return share;
        a.free(share);
    }
    var dir: []const u8 = exe_dir;
    while (true) {
        const cand = try std.fs.path.join(a, &.{ dir, "electron", "payload" });
        if (hasManifest(a, cand)) return cand;
        a.free(cand);
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return null;
}

fn hasManifest(a: Allocator, dir: []const u8) bool {
    const f = std.fs.path.join(a, &.{ dir, "payload.json" }) catch return false;
    defer a.free(f);
    return util.fileExists(f);
}

/// The local tunnel socket for a host slug:
/// `<runtime_dir>/<slug>.sock`. Unix socket paths are capped at 108 bytes
/// (107 + NUL); when the slug would overflow, the base part of the slug is
/// shortened (the 8-hex hash suffix, which carries the uniqueness, is
/// always kept).
pub fn socketPath(a: Allocator, runtime_dir: []const u8, slug: []const u8) ![]u8 {
    const max = 107;
    const fixed = runtime_dir.len + 1 + ".sock".len;
    if (fixed + slug.len <= max) return std.fmt.allocPrint(a, "{s}/{s}.sock", .{ runtime_dir, slug });
    if (fixed + 8 > max) return error.RuntimeDirTooLong;
    const hash = slug[slug.len - @min(8, slug.len) ..];
    const room = max - fixed;
    if (room <= 9) return std.fmt.allocPrint(a, "{s}/{s}.sock", .{ runtime_dir, hash });
    const base = slug[0..@min(slug.len - hash.len, room - 9)];
    return std.fmt.allocPrint(a, "{s}/{s}-{s}.sock", .{ runtime_dir, std.mem.trimEnd(u8, base, "-"), hash });
}

test "socketPath keeps the hash and fits 107 bytes" {
    const a = std.testing.allocator;
    const p1 = try socketPath(a, "/run/user/1000/webmux-gtk", "host-a22a7f04");
    defer a.free(p1);
    try std.testing.expectEqualStrings("/run/user/1000/webmux-gtk/host-a22a7f04.sock", p1);
    const long = @as([120]u8, @splat('a')) ++ "-0123abcd";
    const p2 = try socketPath(a, "/run/user/1000/webmux-gtk", long);
    defer a.free(p2);
    try std.testing.expect(p2.len <= 107);
    try std.testing.expect(std.mem.endsWith(u8, p2, "-0123abcd.sock"));
}
