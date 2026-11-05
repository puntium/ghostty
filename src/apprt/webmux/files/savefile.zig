//! Writing a download to the local disk without destroying anything the
//! user did not agree to replace (std only, no GTK).
//!
//! The bytes go to a new file in the destination's directory, created
//! exclusively (O_EXCL, never following or truncating anything that is
//! there) under an unpredictable name `.<name>.<16 hex>.webmux-part`. Only
//! a complete download is renamed onto the destination the user chose in
//! the save dialog (which asks before replacing an existing file); a
//! failed or cancelled one removes its own temporary file and nothing
//! else.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Temp = struct {
    file: Io.File,
    /// Absolute path of the temporary file (owned).
    path: []u8,

    /// Remove the temporary file (after a failure or a cancel).
    pub fn discard(self: *Temp, a: Allocator, io: Io) void {
        self.file.close(io);
        Io.Dir.cwd().deleteFile(io, self.path) catch {};
        a.free(self.path);
    }

    /// Close it and move it onto `dest`. On failure the temporary file is
    /// removed and `dest` is untouched.
    pub fn commit(self: *Temp, a: Allocator, io: Io, dest: []const u8) !void {
        self.file.close(io);
        defer a.free(self.path);
        Io.Dir.renameAbsolute(self.path, dest, io) catch |err| {
            Io.Dir.cwd().deleteFile(io, self.path) catch {};
            return err;
        };
    }
};

/// Longest part of the destination's name kept in the temporary name, so
/// that `.<part>.<16 hex>.webmux-part` stays within the usual 255-byte
/// name limit for any destination name that fits it (re-check N5).
pub const max_name_part = 200;

/// Create the temporary file next to `dest` (an absolute path). Errors are
/// the file system's (see `reason`).
pub fn create(a: Allocator, io: Io, dest: []const u8) !Temp {
    const dir = std.fs.path.dirname(dest) orelse return error.FileNotFound;
    const base = shorten(std.fs.path.basename(dest), max_name_part);
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const hex = std.fmt.bytesToHex(rnd, .lower);
        const path = try std.fmt.allocPrint(a, "{s}/.{s}.{s}.webmux-part", .{ dir, base, hex });
        const file = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| {
            a.free(path);
            switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            }
        };
        return .{ .file = file, .path = path };
    }
    return error.PathAlreadyExists;
}

/// At most `max` bytes of `s`, cut at a UTF-8 character boundary.
pub fn shorten(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Why a local write failed, for the status line and the log (N6).
pub fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.NoSpaceLeft => "no space left on the device",
        error.DiskQuota => "disk quota exceeded",
        error.NameTooLong => "name too long for the target folder",
        error.IsDir => "a folder has that name",
        error.NotDir, error.FileNotFound => "the folder does not exist",
        error.ReadOnlyFileSystem => "read-only file system",
        error.FileTooBig => "file too big for the target file system",
        error.PathAlreadyExists => "cannot create a temporary file",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

test "long names: the temporary name stays within 255 bytes" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(base);
    // 250 bytes: 125 two-byte characters, so the cut must respect UTF-8.
    var name: [250]u8 = undefined;
    var i: usize = 0;
    while (i < name.len) : (i += 2) @memcpy(name[i..][0..2], "é");
    const dest = try std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ base, name });
    defer t.allocator.free(dest);
    var tf = try create(t.allocator, io, dest);
    try t.expect(std.unicode.utf8ValidateSlice(std.fs.path.basename(tf.path)));
    try t.expect(std.fs.path.basename(tf.path).len <= 255);
    try tf.file.writeStreamingAll(io, "x");
    try tf.commit(t.allocator, io, dest);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("x", try tmp.dir.readFile(io, &name, &buf));
    try t.expectEqualStrings("name too long for the target folder", reason(error.NameTooLong));
}

test "temp files never touch existing files; commit and discard" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "out.txt.part", .data = "precious" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "old" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(base);
    const dest = try std.fmt.allocPrint(t.allocator, "{s}/out.txt", .{base});
    defer t.allocator.free(dest);

    // A completed download lands on dest.
    var tf = try create(t.allocator, io, dest);
    try tf.file.writeStreamingAll(io, "new data");
    try tf.commit(t.allocator, io, dest);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("new data", try tmp.dir.readFile(io, "out.txt", &buf));
    try t.expectEqualStrings("precious", try tmp.dir.readFile(io, "out.txt.part", &buf));

    // A failed one leaves nothing behind.
    const dest2 = try std.fmt.allocPrint(t.allocator, "{s}/keep.txt", .{base});
    defer t.allocator.free(dest2);
    var tf2 = try create(t.allocator, io, dest2);
    try tf2.file.writeStreamingAll(io, "partial");
    tf2.discard(t.allocator, io);
    try t.expectEqualStrings("old", try tmp.dir.readFile(io, "keep.txt", &buf));
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try t.expectEqual(@as(usize, 3), n); // out.txt, out.txt.part, keep.txt
}
