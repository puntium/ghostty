//! The chrome's iface registrations (features.zig): the connection-log and
//! download-folder services. The engine itself is created later, in
//! `hub.start` (Application.startup), and published as `iface.engine`.
const std = @import("std");
const iface = @import("../iface.zig");
const hub = @import("hub.zig");

const alloc = std.heap.c_allocator;

pub fn register() void {
    iface.services.connLog = connLog;
    iface.services.downloadDir = downloadDir;
    iface.services.setDownloadDir = setDownloadDir;
}

/// Append to the connection log as a page entry (src=page), the way the
/// Electron pages POST /log. Without an engine (dev mode) the default
/// logger is used. Any thread.
fn connLog(level: iface.services.LogLevel, conn_name_in: ?[]const u8, msg: []const u8, data: ?[]const u8) void {
    // Features copy the connection name when they are created; after a
    // live rename their entries still carry the old one (C-5).
    var nb: [4096]u8 = undefined;
    const conn_name: ?[]const u8 = if (conn_name_in) |n| resolveAlias(n, &nb) else null;
    const engine = hub.hub.engine orelse {
        std.log.scoped(.webmux_services).info("connlog {t} [{s}] {s} {s}", .{ level, conn_name orelse "-", msg, data orelse "" });
        return;
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    obj.put(a, "level", .{ .string = @tagName(level) }) catch return;
    obj.put(a, "msg", .{ .string = msg }) catch return;
    if (data) |d| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, d, .{})) |v| {
            obj.put(a, "data", v) catch {};
        } else |_| {}
    }
    engine.log().pushJson(conn_name, .page, .{ .object = obj });
}

var dir_buf: [4096]u8 = undefined;

/// Folders remembered for connections that are not saved profiles (dev
/// mode's `dev`): kept for this run only.
var run_dirs: std.StringHashMapUnmanaged([]u8) = .empty;

fn downloadDir(conn_name: []const u8) ?[]const u8 {
    if (run_dirs.get(conn_name)) |d| return d;
    const engine = hub.hub.engine orelse return null;
    const p = (engine.getProfile(alloc, conn_name) catch return null) orelse return null;
    defer p.deinit(alloc);
    if (p.download_dir.len == 0 or p.download_dir.len > dir_buf.len) return null;
    @memcpy(dir_buf[0..p.download_dir.len], p.download_dir);
    return dir_buf[0..p.download_dir.len];
}

fn setDownloadDir(conn_name: []const u8, dir: []const u8) void {
    std.log.scoped(.webmux_chrome).info("download dir [{s}]: {s}", .{ conn_name, dir });
    if (hub.hub.engine) |engine| {
        if (engine.setDownloadDir(conn_name, dir) == null) return;
    }
    // Not a saved profile: remember it for this run.
    const d = alloc.dupe(u8, dir) catch return;
    const gop = run_dirs.getOrPut(alloc, conn_name) catch {
        alloc.free(d);
        return;
    };
    if (gop.found_existing) {
        alloc.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = alloc.dupe(u8, conn_name) catch {
            _ = run_dirs.remove(conn_name);
            alloc.free(d);
            return;
        };
    }
    gop.value_ptr.* = d;
}

// ---------------------------------------------------------------------------
// Rename aliases: old connection name → current one, for log entries from
// features that copied the name before a live rename. Any thread reads.
// ---------------------------------------------------------------------------

const global = @import("../../../global.zig");
var alias_mutex: std.Io.Mutex = .init;
var aliases: std.ArrayList(struct { old: []u8, new: []u8 }) = .empty;

fn resolveAlias(name: []const u8, buf: []u8) []const u8 {
    alias_mutex.lockUncancelable(global.io());
    defer alias_mutex.unlock(global.io());
    for (aliases.items) |a| if (std.mem.eql(u8, a.old, name)) {
        const n = @min(a.new.len, buf.len);
        @memcpy(buf[0..n], a.new[0..n]);
        return buf[0..n];
    };
    return name;
}

/// The current name of a connection that may have been renamed.
pub fn currentName(name: []const u8, buf: []u8) []const u8 {
    return resolveAlias(name, buf);
}

/// Main thread: a live connection was renamed.
pub fn alias(old: []const u8, new: []const u8) void {
    alias_mutex.lockUncancelable(global.io());
    defer alias_mutex.unlock(global.io());
    // Earlier names of the same connection follow it.
    for (aliases.items) |*a| if (std.mem.eql(u8, a.new, old)) {
        const n = alloc.dupe(u8, new) catch continue;
        alloc.free(a.new);
        a.new = n;
    };
    removeKeyLocked(new);
    const o = alloc.dupe(u8, old) catch return;
    const n = alloc.dupe(u8, new) catch {
        alloc.free(o);
        return;
    };
    aliases.append(alloc, .{ .old = o, .new = n }) catch {
        alloc.free(o);
        alloc.free(n);
    };
}

/// Main thread: `name` is a live connection's own name again (a new
/// connection under an old name), or the connection `name` went away.
pub fn unalias(name: []const u8) void {
    alias_mutex.lockUncancelable(global.io());
    defer alias_mutex.unlock(global.io());
    removeKeyLocked(name);
    var i: usize = 0;
    while (i < aliases.items.len) {
        const a = aliases.items[i];
        if (std.mem.eql(u8, a.new, name)) {
            alloc.free(a.old);
            alloc.free(a.new);
            _ = aliases.swapRemove(i);
        } else i += 1;
    }
}

/// A connection now really has this name: it is nobody's alias.
pub fn removeAliasOf(name: []const u8) void {
    alias_mutex.lockUncancelable(global.io());
    defer alias_mutex.unlock(global.io());
    removeKeyLocked(name);
}

fn removeKeyLocked(name: []const u8) void {
    var i: usize = 0;
    while (i < aliases.items.len) {
        const a = aliases.items[i];
        if (std.mem.eql(u8, a.old, name)) {
            alloc.free(a.old);
            alloc.free(a.new);
            _ = aliases.swapRemove(i);
        } else i += 1;
    }
}
