//! First run (ruling N-13): with no config.json of ours, import the
//! profiles of the Electron client (`$XDG_CONFIG_HOME/webmux/config.json`,
//! Electron's userData for the app name "webmux"), without passwords and
//! `localPort`. Nothing else is migrated; the two clients can be used side
//! by side.
const std = @import("std");
const conn = @import("../../../webmux/conn.zig");
const util = @import("../../../webmux/conn/util.zig");
const global = @import("../../../global.zig");

const log = std.log.scoped(.webmux_chrome);
const alloc = std.heap.c_allocator;

pub fn firstRun(engine: conn.Engine) void {
    const ours = engine.configPath();
    if (util.fileExists(ours)) return;
    // <config>/webmux-gtk/config.json → <config>/webmux/config.json
    const dir = std.fs.path.dirname(ours) orelse return;
    const base = std.fs.path.dirname(dir) orelse return;
    const theirs = std.fs.path.join(alloc, &.{ base, "webmux", "config.json" }) catch return;
    defer alloc.free(theirs);
    const n = importFrom(engine, theirs) catch |err| {
        engine.log().warn(null, "could not import the Electron client's profiles", &.{
            .{ .key = "file", .value = .{ .str = theirs } },
            .{ .key = "error", .value = .{ .str = @errorName(err) } },
        });
        return;
    };
    if (n > 0) engine.log().info(null, "imported profiles from the Electron client", &.{
        .{ .key = "file", .value = .{ .str = theirs } },
        .{ .key = "profiles", .value = .{ .int = @intCast(n) } },
    });
}

fn importFrom(engine: conn.Engine, path: []const u8) !usize {
    const bytes = (try util.readFileAlloc(global.io(), alloc, path, 16 << 20)) orelse return 0;
    defer alloc.free(bytes);
    // Untyped: one odd field must not lose every profile (C-8).
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.NotAnObject;
    const profs = parsed.value.object.get("profiles") orelse return 0;
    if (profs != .array) return 0;
    var n: usize = 0;
    for (profs.array.items) |pv| {
        if (pv != .object) continue;
        const o = pv.object;
        const name = str(o, "name") orelse continue;
        const host = str(o, "host") orelse continue;
        // main.js: Number(sshPort) || 0; a whole number is kept (an
        // out-of-range one is refused by the save, and logged).
        const port: u32 = blk: {
            const v = o.get("sshPort") orelse break :blk 0;
            const f = profile_mod.jsNumber(v);
            if (!std.math.isFinite(f) or f < 0 or f > std.math.maxInt(u32) or @floor(f) != f) break :blk 0;
            break :blk @intFromFloat(f);
        };
        const r = engine.saveProfile(.{
            .name = name,
            .host = host,
            .ssh_port = port,
            .identity_file = str(o, "identityFile") orelse "",
            .instance = str(o, "instance") orelse "",
            .extra_options = str(o, "extraOptions") orelse "",
            .download_dir = str(o, "downloadDir") orelse "",
        }, null);
        if (r) |err| {
            engine.log().warn(name, "profile not imported", &.{.{ .key = "error", .value = .{ .str = err } }});
            continue;
        }
        n += 1;
    }
    return n;
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

const profile_mod = @import("../../../webmux/conn/profile.zig");
