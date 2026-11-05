//! Test helper: a real, fully isolated webmux host (`webmux-host serve`).
//!
//! Everything lives under a fresh `/tmp/wm-XXXXXXXX` directory (unix socket
//! paths are capped at 108 bytes): XDG_RUNTIME_DIR (pty-host socket), TMPDIR
//! (paste/spool dir), HOME (shell cwd), WEBMUX_SOCKET (the HTTP socket; also
//! suppresses the ~/.webmux advert) and a unique WEBMUX_PTYHOST name, as in
//! host/test/e2e.js. The user's real HOME and runtime dir are never used.
//! Sessions run `sh` with `PS1='$ '` and no rc file.
//!
//! `deinit` shuts the pty-host daemon down (`ptyhost --name N shutdown`),
//! stops the server and deletes the directory, so no daemon outlives a test.
//!
//! The binary is $WEBMUX_HOST_BIN, else `host/dist/webmux-host-linux-x64`
//! found by walking up from the current directory. If neither exists,
//! `start` returns error.SkipZigTest.
const TestHost = @This();

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const api = @import("api.zig");

alloc: Allocator,
io: std.Io,
bin: []u8,
dir: []u8,
socket_path: []u8,
name: []u8,
env: std.process.Environ.Map,
server: ?std.process.Child = null,

pub fn start(alloc: Allocator, io: std.Io, environ: std.process.Environ) !*TestHost {
    const bin = try findBinary(alloc, io, environ) orelse return error.SkipZigTest;
    errdefer alloc.free(bin);

    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/wm-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    errdefer alloc.free(dir);
    try mkdir(alloc, dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    for ([_][]const u8{ "run", "tmp", "home" }) |sub| {
        const p = try std.fs.path.join(alloc, &.{ dir, sub });
        defer alloc.free(p);
        try mkdir(alloc, p);
    }

    const socket_path = try std.fs.path.join(alloc, &.{ dir, "h.sock" });
    errdefer alloc.free(socket_path);
    const name = try std.fmt.allocPrint(alloc, "zt-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    errdefer alloc.free(name);

    var env = try environ.createMap(alloc);
    errdefer env.deinit();
    {
        const run = try std.fs.path.join(alloc, &.{ dir, "run" });
        defer alloc.free(run);
        const tmp = try std.fs.path.join(alloc, &.{ dir, "tmp" });
        defer alloc.free(tmp);
        const home = try std.fs.path.join(alloc, &.{ dir, "home" });
        defer alloc.free(home);
        try env.put("XDG_RUNTIME_DIR", run);
        try env.put("TMPDIR", tmp);
        try env.put("HOME", home);
    }
    try env.put("WEBMUX_SOCKET", socket_path);
    try env.put("WEBMUX_PTYHOST", name);
    try env.put("SHELL_CMD", "sh");
    try env.put("PS1", "$ ");
    try env.put("ENV", "");
    _ = env.swapRemove("TMUX");
    _ = env.swapRemove("TMUX_PANE");

    const self = try alloc.create(TestHost);
    self.* = .{
        .alloc = alloc,
        .io = io,
        .bin = bin,
        .dir = dir,
        .socket_path = socket_path,
        .name = name,
        .env = env,
    };
    errdefer self.deinit();
    try self.startServer();
    return self;
}

/// Start (or restart) the HTTP server and wait until `GET /` answers. The
/// pty-host daemon (and its sessions) survive server restarts.
pub fn startServer(self: *TestHost) !void {
    std.debug.assert(self.server == null);
    self.server = try std.process.spawn(self.io, .{
        .argv = &.{ self.bin, "serve" },
        .environ_map = &self.env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var c = try http.Client.init(self.alloc, self.io, self.socket_path);
    defer c.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (api.health(&c, self.alloc, .{ .timeout_ms = 1000 })) |h| {
            h.deinit();
            return;
        } else |_| {}
        try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
    }
    return error.HostDidNotStart;
}

/// SIGTERM the HTTP server and wait for it (attached clients see their
/// sockets drop; sessions keep running in the pty host).
pub fn stopServer(self: *TestHost) void {
    if (self.server) |*child| {
        if (child.id) |pid| _ = linux.kill(pid, linux.SIG.TERM);
        _ = child.wait(self.io) catch {};
        self.server = null;
    }
}

pub fn deinit(self: *TestHost) void {
    const alloc = self.alloc;
    // Pty host first: kills every session and exits the daemon.
    if (std.process.run(alloc, self.io, .{
        .argv = &.{ self.bin, "ptyhost", "--name", self.name, "shutdown" },
        .environ_map = &self.env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    })) |r| {
        alloc.free(r.stdout);
        alloc.free(r.stderr);
    } else |_| {}
    self.stopServer();
    // Wait for the daemon's socket to disappear (it removes it on exit).
    const hostsock = std.fmt.allocPrint(alloc, "{s}/run/webmux/{s}.sock", .{ self.dir, self.name }) catch null;
    if (hostsock) |p| {
        defer alloc.free(p);
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            std.Io.Dir.cwd().access(self.io, p, .{}) catch break;
            std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch {};
        }
    }
    std.Io.Dir.cwd().deleteTree(self.io, self.dir) catch {};
    self.env.deinit();
    alloc.free(self.bin);
    alloc.free(self.dir);
    alloc.free(self.socket_path);
    alloc.free(self.name);
    alloc.destroy(self);
}

pub fn client(self: *TestHost) !http.Client {
    return http.Client.init(self.alloc, self.io, self.socket_path);
}

fn mkdir(alloc: Allocator, path: []const u8) !void {
    const z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(z);
    switch (linux.errno(linux.mkdir(z, 0o700))) {
        .SUCCESS => {},
        else => return error.MkdirFailed,
    }
}

fn findBinary(alloc: Allocator, io: std.Io, environ: std.process.Environ) !?[]u8 {
    var env = try environ.createMap(alloc);
    defer env.deinit();
    if (env.get("WEBMUX_HOST_BIN")) |p| return try alloc.dupe(u8, p);
    var cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    var dir: []const u8 = cwd;
    while (true) {
        const cand = try std.fs.path.join(alloc, &.{ dir, "host", "dist", "webmux-host-linux-x64" });
        if (std.Io.Dir.cwd().access(io, cand, .{})) |_| {
            return cand;
        } else |_| alloc.free(cand);
        dir = std.fs.path.dirname(dir) orelse return null;
    }
    _ = &cwd;
}
