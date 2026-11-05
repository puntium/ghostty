//! ssh command lines and environment (main.js sshBaseArgs, sshTunnelArgs,
//! sshEnvFor, ensureAskpass), with the tunnel's local end changed to a unix
//! socket (docs/native-client.md › Tunnel).
//!
//! The password never appears in argv: with one, ssh is told to make one
//! password attempt and to ask the askpass helper, which echoes
//! `$WEBMUX_SSH_PASSWORD` from the child's own environment.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const Profile = @import("profile.zig").Profile;
const util = @import("util.zig");

pub const ASKPASS_SCRIPT = "#!/bin/sh\nprintf '%s' \"$WEBMUX_SSH_PASSWORD\"\n";
pub const PASSWORD_ENV = "WEBMUX_SSH_PASSWORD";

/// Options shared by the tunnel and the deploy steps: auth, endpoint and
/// timeouts, but no forwarding. Appends to `out`; strings are borrowed from
/// `p` or static, except the port, which is allocated with `a`.
pub fn baseArgs(a: Allocator, out: *std.ArrayList([]const u8), p: Profile, has_password: bool) !void {
    // Key-only auth unless a password is saved: BatchMode forbids prompts,
    // which would otherwise hang a headless spawn. With a password the
    // askpass helper answers the one permitted prompt — one, so a wrong
    // password fails fast instead of re-prompting.
    if (has_password) {
        try out.appendSlice(a, &.{ "-o", "NumberOfPasswordPrompts=1" });
    } else {
        try out.appendSlice(a, &.{ "-o", "BatchMode=yes" });
    }
    // Never ride a ControlMaster from ~/.ssh/config: a mux client ignores
    // the keepalives below.
    try out.appendSlice(a, &.{ "-o", "ControlMaster=no", "-o", "ControlPath=none" });
    // Dead-link detection bound: 10s × (2+1) ≈ 30s.
    try out.appendSlice(a, &.{ "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-o", "ConnectTimeout=10" });
    if (p.ssh_port != 0) try out.appendSlice(a, &.{ "-p", try std.fmt.allocPrint(a, "{d}", .{p.ssh_port}) });
    if (p.identity_file.len > 0) try out.appendSlice(a, &.{ "-i", p.identity_file });
    var it = std.mem.tokenizeAny(u8, p.extra_options, " \t\r\n\x0b\x0c");
    while (it.next()) |tok| try out.append(a, tok);
}

/// `ssh <base> <host> <command>` for a deploy step / restart-sessions.
pub fn commandArgv(a: Allocator, ssh: []const u8, p: Profile, has_password: bool, command: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, ssh);
    try baseArgs(a, &out, p, has_password);
    try out.append(a, p.host);
    try out.append(a, command);
    return out.toOwnedSlice(a);
}

/// The tunnel: `ssh -N -o ExitOnForwardFailure=yes -o
/// StreamLocalBindUnlink=yes <base> -L <local.sock>:<remote.sock> <host>`.
/// StreamLocalBindUnlink makes ssh remove a stale socket file left by an
/// earlier tunnel before binding; the bind mask stays ssh's default 0177
/// and the socket's directory is 0700.
pub fn tunnelArgv(a: Allocator, ssh: []const u8, p: Profile, has_password: bool, local_sock: []const u8, remote_sock: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, &.{ ssh, "-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes" });
    try baseArgs(a, &out, p, has_password);
    try out.append(a, "-L");
    try out.append(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ local_sock, remote_sock }));
    try out.append(a, p.host);
    return out.toOwnedSlice(a);
}

/// argv without argv[0], space-joined: the `cmd` field of the
/// "tunnel spawned" log line (`ssh ${args.join(' ')}`).
pub fn joinForLog(a: Allocator, argv: []const []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    try parts.append(a, "ssh");
    try parts.appendSlice(a, argv[1..]);
    return std.mem.join(a, " ", parts.items);
}

/// Child environment: the base env plus, with a password, the askpass
/// trio. Caller owns the map; call `wipe` on it once the child is spawned.
pub fn childEnv(a: Allocator, base: *const EnvMap, askpass_path: []const u8, password: ?[]const u8) !EnvMap {
    var m = try base.clone(a);
    errdefer m.deinit();
    // Never inherit a stale password from our own environment.
    _ = m.swapRemove(PASSWORD_ENV);
    if (password) |pw| {
        try m.put("SSH_ASKPASS", askpass_path);
        try m.put("SSH_ASKPASS_REQUIRE", "force");
        try m.put(PASSWORD_ENV, pw);
    }
    return m;
}

/// Zero the password copy in an env map built by `childEnv` (in place; the
/// map stays usable for spawns that need no password any more).
pub fn zeroPassword(m: *EnvMap) void {
    if (m.getPtr(PASSWORD_ENV)) |v| std.crypto.secureZero(u8, @constCast(v.*));
}

/// zeroPassword, then free the map.
pub fn wipe(m: *EnvMap) void {
    zeroPassword(m);
    m.deinit();
}

/// Write the askpass helper (0700) into `dir` and return its path.
pub fn ensureAskpass(a: Allocator, io: std.Io, dir: []const u8) ![]u8 {
    try util.makePath(io, dir, 0o700);
    const path = try std.fs.path.join(a, &.{ dir, "askpass.sh" });
    errdefer a.free(path);
    try util.atomicWrite(io, path, ASKPASS_SCRIPT, 0o700);
    return path;
}
