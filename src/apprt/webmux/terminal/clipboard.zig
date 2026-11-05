//! Clipboard behaviour of a terminal pane, after the Electron client
//! (gtk/PARITY.md section 2):
//!
//!   paste      Ctrl+V / Ctrl+Shift+V (C-04, C-05, C-06): image → image
//!              paste, text → a normal (bracketed when asked) paste,
//!              nothing → a literal ^V for Ctrl+V only.
//!   image      paste-image over the pane's session socket (C-07, C-10,
//!              ruling A-11: types the host does not take become PNG).
//!   sync       `iface.hooks.clipboardSync` (C-09, H-03): the clipboard's
//!              image into the host's clipboard slot.
//!   copy       Ctrl+Shift+C (ruling A-03) and PRIMARY on selection (T-21).
//!
//! All of it runs on the main thread; asynchronous reads keep a strong
//! reference to the pane until they finish.
const std = @import("std");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const remote = @import("remote.zig");
const TerminalPane = @import("../pane.zig").TerminalPane;

const log = std.log.scoped(.webmux_clipboard);
const alloc = std.heap.c_allocator;

/// The image types the host stores (host/internal/server/paste.go).
pub const host_image_types = [_][:0]const u8{
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp",
};

pub const PasteKey = enum {
    /// Ctrl+V: falls back to a literal ^V.
    ctrl_v,
    /// Ctrl+Shift+V: paste, or nothing.
    paste,
};

fn clipboard() *gdk.Clipboard {
    return gdk.Display.getDefault().?.getClipboard();
}

fn primary() *gdk.Clipboard {
    return gdk.Display.getDefault().?.getPrimaryClipboard();
}

//---------------------------------------------------------------
// Paste

/// Ctrl+V / Ctrl+Shift+V in a terminal pane.
pub fn paste(pane: *TerminalPane, key: PasteKey) void {
    const formats = clipboard().getFormats();
    if (hasImage(formats)) {
        imagePaste(pane);
        return;
    }
    if (formats.containGtype(gobject.ext.types.string) != 0) {
        const req = alloc.create(TextRead) catch return;
        req.* = .{ .pane = pane.ref(), .key = key };
        pane.pasteBegin(); // typing meanwhile waits for the text (O2)
        clipboard().readTextAsync(null, TextRead.done, req);
        return;
    }
    if (key == .ctrl_v) literalCtrlV(pane);
}

/// Ctrl+Alt+V, and Ctrl+V with nothing usable on the clipboard (T-16).
pub fn literalCtrlV(pane: *TerminalPane) void {
    const surface = pane.core() orelse return;
    _ = surface.performBindingAction(.{ .text = "\\x16" }) catch |err| {
        log.warn("cannot send ^V: {t}", .{err});
    };
}

const TextRead = struct {
    pane: *TerminalPane,
    key: PasteKey,

    fn done(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *TextRead = @ptrCast(@alignCast(ud.?));
        defer alloc.destroy(self);
        defer self.pane.unref();
        defer self.pane.pasteEnd();
        const cb = gobject.ext.cast(gdk.Clipboard, source orelse return).?;
        var err_: ?*glib.Error = null;
        const text_ = cb.readTextFinish(res, &err_);
        if (err_) |e| e.free();
        const text = text_ orelse {
            if (self.key == .ctrl_v) literalCtrlV(self.pane);
            return;
        };
        defer glib.free(text);
        const str = std.mem.sliceTo(text, 0);
        if (str.len == 0) {
            if (self.key == .ctrl_v) literalCtrlV(self.pane);
            return;
        }
        const surface = self.pane.core() orelse return;
        surface.completeClipboardRequest(
            .{ .paste = .standard },
            .{ .contents = &.{.{ .mime = "text/plain", .data = str }} },
        ) catch |err| log.warn("paste failed: {t}", .{err});
    }
};

fn hasImage(formats: *gdk.ContentFormats) bool {
    if (formats.containGtype(gdk.Texture.getGObjectType()) != 0) return true;
    var n: usize = 0;
    const mimes = formats.getMimeTypes(&n) orelse return false;
    for (0..n) |i| {
        const m = std.mem.span(mimes[i] orelse continue);
        if (std.mem.startsWith(u8, m, "image/")) return true;
    }
    return false;
}

//---------------------------------------------------------------
// Reading an image in a type the host accepts

const Purpose = union(enum) {
    /// Image paste into this pane (holds a strong ref).
    paste: *TerminalPane,
    /// Clipboard sync to this host socket (owned copy).
    sync: [:0]u8,
};

const ImageRead = struct {
    purpose: Purpose,
    mime: [:0]const u8 = "image/png",
    sink: ?*gio.MemoryOutputStream = null,

    fn destroy(self: *ImageRead) void {
        switch (self.purpose) {
            .paste => |p| p.unref(),
            .sync => |s| alloc.free(s),
        }
        if (self.sink) |s| s.unref();
        alloc.destroy(self);
    }

    /// Start reading; `finish` is called exactly once.
    fn start(self: *ImageRead) void {
        const formats = clipboard().getFormats();
        // A type the host takes, in the clipboard's own order.
        var n: usize = 0;
        if (formats.getMimeTypes(&n)) |mimes| {
            for (0..n) |i| {
                const m = std.mem.span(mimes[i] orelse continue);
                for (host_image_types) |t| {
                    if (!std.mem.eql(u8, m, t)) continue;
                    self.mime = t;
                    // A NULL-terminated array (GDK copies it).
                    var types = [_]?[*:0]const u8{ t.ptr, null };
                    clipboard().readAsync(@ptrCast(&types), glib.PRIORITY_DEFAULT, null, readDone, self);
                    return;
                }
            }
        }
        // Anything else GDK can decode (TIFF, SVG…): convert to PNG (A-11).
        self.mime = "image/png";
        clipboard().readTextureAsync(null, textureDone, self);
    }

    fn readDone(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *ImageRead = @ptrCast(@alignCast(ud.?));
        const cb = gobject.ext.cast(gdk.Clipboard, source.?).?;
        var err_: ?*glib.Error = null;
        const stream = cb.readFinish(res, null, &err_) orelse {
            self.fail(err_);
            return;
        };
        defer stream.unref();
        const sink = gio.MemoryOutputStream.newResizable();
        self.sink = sink;
        sink.as(gio.OutputStream).spliceAsync(
            stream,
            .{ .close_source = true, .close_target = true },
            glib.PRIORITY_DEFAULT,
            null,
            spliceDone,
            self,
        );
    }

    fn spliceDone(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *ImageRead = @ptrCast(@alignCast(ud.?));
        _ = source;
        var err_: ?*glib.Error = null;
        if (self.sink.?.as(gio.OutputStream).spliceFinish(res, &err_) < 0) {
            self.fail(err_);
            return;
        }
        const bytes = self.sink.?.stealAsBytes();
        defer bytes.unref();
        self.finish(bytes);
    }

    fn textureDone(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *ImageRead = @ptrCast(@alignCast(ud.?));
        const cb = gobject.ext.cast(gdk.Clipboard, source.?).?;
        var err_: ?*glib.Error = null;
        const texture = cb.readTextureFinish(res, &err_) orelse {
            self.fail(err_);
            return;
        };
        defer texture.unref();
        const bytes = texture.saveToPngBytes();
        defer bytes.unref();
        self.finish(bytes);
    }

    fn fail(self: *ImageRead, err_: ?*glib.Error) void {
        defer self.destroy();
        const msg: []const u8 = if (err_) |e| std.mem.span(e.f_message orelse "unknown error") else "unknown error";
        defer if (err_) |e| e.free();
        switch (self.purpose) {
            .paste => |pane| {
                var buf: [256]u8 = undefined;
                iface.services.status(pane.connName(), std.fmt.bufPrint(&buf, "image paste failed: {s}", .{msg}) catch "image paste failed");
            },
            // C-09: read failures are silent.
            .sync => log.debug("clipboard sync read failed: {s}", .{msg}),
        }
    }

    fn finish(self: *ImageRead, bytes: *glib.Bytes) void {
        defer self.destroy();
        var len: usize = 0;
        const ptr = bytes.getData(&len) orelse return;
        const data = ptr[0..len];
        const b64 = alloc.alloc(u8, std.base64.standard.Encoder.calcSize(len)) catch return;
        defer alloc.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, data);

        switch (self.purpose) {
            .paste => |pane| {
                if (!pane.sendFrame(.{ .paste_image = .{ .mime = self.mime, .data = b64 } })) {
                    log.info("image paste dropped: session socket closed", .{});
                }
            },
            .sync => |socket_path| syncSend(socket_path, self.mime, b64),
        }
    }
};

/// C-07: with the session socket open, toast and send the image.
fn imagePaste(pane: *TerminalPane) void {
    if (pane.getLink() != .up) return; // socket closed: do nothing
    iface.services.status(pane.connName(), "uploading pasted image…");
    const req = alloc.create(ImageRead) catch return;
    req.* = .{ .purpose = .{ .paste = pane.ref() } };
    req.start();
}

//---------------------------------------------------------------
// Clipboard sync (iface.hooks.clipboardSync)

pub fn register() void {
    iface.hooks.clipboardSync = clipboardSync;
}

/// Per host socket: when we last looked, and the image last sent.
const SyncState = struct {
    socket_path: []u8,
    last_ms: ?i64 = null,
    last_hash: ?u64 = null,
};
var sync_states: std.ArrayListUnmanaged(SyncState) = .empty;

fn syncState(socket_path: []const u8) ?*SyncState {
    for (sync_states.items) |*s| {
        if (std.mem.eql(u8, s.socket_path, socket_path)) return s;
    }
    const copy = alloc.dupe(u8, socket_path) catch return null;
    sync_states.append(alloc, .{ .socket_path = copy }) catch {
        alloc.free(copy);
        return null;
    };
    return &sync_states.items[sync_states.items.len - 1];
}

/// Throttle in the Electron client (`syncClipboardImage`).
pub const sync_throttle_ms = 1000;

fn clipboardSync(c: *const iface.Conn) void {
    const st = syncState(c.socket_path) orelse return;
    const now = @divFloor(glib.getMonotonicTime(), 1000);
    if (st.last_ms) |last| if (now - last < sync_throttle_ms) return;
    st.last_ms = now;
    // Text clipboards are never synced.
    if (!hasImage(clipboard().getFormats())) return;
    if (remote.firstLive(c.socket_path) == null) return;
    const req = alloc.create(ImageRead) catch return;
    req.* = .{ .purpose = .{ .sync = alloc.dupeSentinel(u8, c.socket_path, 0) catch {
        alloc.destroy(req);
        return;
    } } };
    req.start();
}

fn syncSend(socket_path: []const u8, mime: []const u8, b64: []const u8) void {
    const st = syncState(socket_path) orelse return;
    const hash = std.hash.Wyhash.hash(0, b64);
    if (st.last_hash == hash) return;
    // The first open session socket of that host (C-09).
    const pane = remote.firstLive(socket_path) orelse return;
    if (!pane.sendFrame(.{ .clipboard_sync = .{ .mime = mime, .data = b64 } })) return;
    st.last_hash = hash;
    iface.services.status(pane.connName(), "clipboard image synced to sessions");
}

//---------------------------------------------------------------
// Copy

/// Ctrl+Shift+C: the selection to CLIPBOARD. Returns false without one.
pub fn copySelection(pane: *TerminalPane) bool {
    const text = selectionText(pane) orelse return false;
    defer alloc.free(text);
    clipboard().setText(text.ptr);
    return true;
}

/// T-21: a finished mouse selection becomes PRIMARY.
pub fn selectionToPrimary(pane: *TerminalPane) void {
    const text = selectionText(pane) orelse return;
    defer alloc.free(text);
    primary().setText(text.ptr);
}

fn selectionText(pane: *TerminalPane) ?[:0]const u8 {
    const surface = pane.core() orelse return null;
    if (!surface.hasSelection()) return null;
    const text = (surface.selectionString(alloc) catch return null) orelse return null;
    if (text.len == 0) {
        alloc.free(text);
        return null;
    }
    return text;
}
