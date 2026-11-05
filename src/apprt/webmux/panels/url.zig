//! `iface.services.url`: open, copy, or ask (PARITY T-24…T-26, C-11, M-04).
//!
//!   .open    a plain click on a link: http(s) goes to the default
//!            browser; anything else is inert (xterm's
//!            `allowNonHttpProtocols: false`, main.js's window-open
//!            handler denies non-http(s)).
//!   .copy    shift-click: http(s) is copied to the clipboard with the
//!            status message `link copied`; anything else is inert.
//!   .choose  nobody clicked (a program ran xdg-open, or a mailto: link in
//!            a markdown preview): the open/copy chooser, centred on the
//!            parent's window: the URL, then Cancel, Copy, and Open in
//!            browser (primary, initial focus). Escape or a click on the
//!            dimmed backdrop cancels. Closing returns focus to `parent`.
//!            For mailto: the open button reads `Open` and hands the URL
//!            to the default mail application (the Electron client's
//!            button is dead there: main.js denies non-http(s)); for any
//!            other scheme there is only Copy.
//!
//! Everything that would start another program (browser, mail client,
//! file manager) goes through `launch`, which the sink decides:
//! `launch` for real, or `record` (keep it in a list the control socket
//! reads back). The sink is `WEBMUX_GTK_URL_SINK=launch|record`; without
//! it, `record` whenever the control socket is enabled (every headless and
//! test run), `launch` otherwise. `url-sink` switches it at run time.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const control = @import("../control.zig");
const ext = @import("../ext.zig");
const Application = @import("../application.zig").Application;
const model = @import("model.zig");
const toast = @import("toast.zig");
const ui = @import("ui.zig");
const TerminalPane = @import("../pane.zig").TerminalPane;

const log = std.log.scoped(.webmux_panels);
const alloc = std.heap.c_allocator;

pub const sink_env = "WEBMUX_GTK_URL_SINK";

pub const Sink = enum { launch, record };
pub var sink: Sink = .launch;

pub const LaunchKind = enum {
    /// a URI for its default handler (browser, mail client)
    uri,
    /// show a file in the file manager
    reveal,
};

pub const Launch = struct { kind: LaunchKind, target: []const u8 };

/// What `record` mode kept, oldest first.
pub var recorded: std.ArrayList(Launch) = .empty;
/// The last text this module put on the clipboard (read back by tests;
/// the clipboard itself is also checked with wl-paste).
pub var last_copied: ?[]u8 = null;

pub fn initSink() void {
    if (std.c.getenv(sink_env)) |v| {
        if (std.meta.stringToEnum(Sink, std.mem.span(v))) |s| {
            sink = s;
            log.info("url sink: {t} ({s})", .{ s, sink_env });
            return;
        }
    }
    const ctl = std.c.getenv(control.env_var);
    sink = if (ctl != null and std.mem.span(ctl.?).len > 0) .record else .launch;
    log.info("url sink: {t}", .{sink});
}

pub fn clearRecorded() void {
    for (recorded.items) |r| alloc.free(r.target);
    recorded.clearRetainingCapacity();
}

/// The one place the client hands something to another program.
pub fn launch(kind: LaunchKind, target: []const u8, parent: ?*gtk.Window) void {
    switch (sink) {
        .record => {
            const copy = alloc.dupe(u8, target) catch return;
            recorded.append(alloc, .{ .kind = kind, .target = copy }) catch {
                alloc.free(copy);
                return;
            };
            log.info("url sink recorded {t}: {s}", .{ kind, target });
        },
        .launch => {
            const z = alloc.dupeSentinel(u8, target, 0) catch return;
            defer alloc.free(z);
            switch (kind) {
                .uri => {
                    const launcher = gtk.UriLauncher.new(z.ptr);
                    launcher.launch(parent, null, onUriLaunched, null);
                },
                .reveal => {
                    const file = gio.File.newForPath(z.ptr);
                    defer file.unref();
                    const launcher = gtk.FileLauncher.new(file);
                    launcher.openContainingFolder(parent, null, onFileLaunched, null);
                },
            }
        },
    }
}

fn onUriLaunched(source: ?*gobject.Object, res: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    const launcher: *gtk.UriLauncher = @ptrCast(source orelse return);
    defer launcher.unref();
    var err: ?*glib.Error = null;
    if (launcher.launchFinish(res, &err) == 0) {
        if (err) |e| {
            defer e.free();
            log.warn("could not open the link: {s}", .{e.f_message orelse "?"});
        }
    }
}

fn onFileLaunched(source: ?*gobject.Object, res: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    const launcher: *gtk.FileLauncher = @ptrCast(source orelse return);
    defer launcher.unref();
    var err: ?*glib.Error = null;
    if (launcher.openContainingFolderFinish(res, &err) == 0) {
        if (err) |e| {
            defer e.free();
            log.warn("could not show the file: {s}", .{e.f_message orelse "?"});
        }
    }
}

/// Put text on the CLIPBOARD; optionally say so in the status line.
pub fn copyToClipboard(text: []const u8, status: ?[]const u8) void {
    const display = gdk.Display.getDefault() orelse return;
    const z = alloc.dupeSentinel(u8, text, 0) catch return;
    defer alloc.free(z);
    display.getClipboard().setText(z.ptr);
    if (last_copied) |l| alloc.free(l);
    last_copied = alloc.dupe(u8, text) catch null;
    if (status) |s| toast.show(s);
}

fn windowOf(widget: ?*gtk.Widget) ?*gtk.Window {
    if (widget) |w| {
        if (ext.getAncestor(gtk.Window, w)) |win| return win;
    }
    const app = Application.default();
    if (app.activeWindow()) |w| return w.as(gtk.Window);
    return null;
}

/// `iface.services.url`.
pub fn service(target: []const u8, action: iface.services.UrlAction, parent: ?*gtk.Widget) void {
    const kind = model.urlKind(target);
    switch (action) {
        .open => {
            if (!model.clickable(kind)) {
                log.info("link not opened: only http(s) links open on a click", .{});
                return;
            }
            launch(.uri, target, windowOf(parent));
        },
        .copy => {
            if (!model.clickable(kind)) {
                log.info("link not copied: only http(s) links are active", .{});
                return;
            }
            copyToClipboard(target, "link copied");
        },
        .choose => showChooser(target, parent),
    }
}

// ---------------------------------------------------------------------------
// The chooser (electron/ui/app.js showLinkModal)
// ---------------------------------------------------------------------------

pub const Chooser = struct {
    dialog: *adw.Dialog,
    url: [:0]u8,
    kind: model.UrlKind,
    /// Strong ref; focus goes back there on close.
    parent: ?*gtk.Widget,
    open_button: ?*gtk.Button,
    cancel_button: ?*gtk.Button = null,
    label: ?*gtk.Label = null,
    copy_button: ?*gtk.Button = null,
    pub const Button = enum { cancel, copy, open };
};

/// Open choosers, oldest first (each one stacks over the previous).
pub var choosers: std.ArrayList(*Chooser) = .empty;

pub fn showChooser(url: []const u8, parent: ?*gtk.Widget) void {
    const win = windowOf(parent) orelse {
        log.warn("link chooser: no window", .{});
        return;
    };
    const kind = model.urlKind(url);
    const c = alloc.create(Chooser) catch return;
    c.* = .{
        .dialog = ui.modal("link-modal"),
        .url = alloc.dupeSentinel(u8, url, 0) catch {
            alloc.destroy(c);
            return;
        },
        .kind = kind,
        .parent = if (parent) |p| blk: {
            _ = p.as(gobject.Object).ref();
            break :blk p;
        } else null,
        .open_button = null,
    };

    const box = gtk.Box.new(.vertical, 0);
    box.as(gtk.Widget).addCssClass("modal-body");

    // The exact URL: breaks anywhere (word-break: break-all) and Pango
    // must not add hyphens at the breaks. Through markup, because a Pango
    // attribute list would need a direct libpango call.
    const label = gtk.Label.new(null);
    const escaped = glib.markupEscapeText(c.url.ptr, -1);
    defer glib.free(escaped);
    const markup = std.fmt.allocPrintSentinel(alloc, "<span insert_hyphens=\"false\">{s}</span>", .{std.mem.span(escaped)}, 0) catch {
        alloc.free(c.url);
        alloc.destroy(c);
        return;
    };
    defer alloc.free(markup);
    label.setMarkup(markup.ptr);
    c.label = label;
    const lw = label.as(gtk.Widget);
    lw.addCssClass("link-url");
    label.setWrap(1);
    label.setWrapMode(.char);
    label.setSelectable(1);
    label.setXalign(0);
    // max-width min(560px, 90vw) at 12.5px monospace (~7.5px a cell,
    // minus the panel's padding). The same minimum, so the wrapped height
    // is measured at the width it is shown at.
    const win_w = win.as(gtk.Widget).getWidth();
    const chars: c_int = @max(20, @min(65, @divTrunc(@divTrunc(win_w * 9, 10) - 40, 8)));
    label.setMaxWidthChars(chars);
    const url_chars: c_int = @intCast(@min(std.unicode.utf8CountCodepoints(url) catch url.len, 1000));
    label.setWidthChars(@min(chars, url_chars));
    lw.setCanFocus(0);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.setPropagateNaturalHeight(1);
    scroll.setPropagateNaturalWidth(1);
    // max-height: 30vh
    const win_h = win.as(gtk.Widget).getHeight();
    scroll.setMaxContentHeight(@max(60, @divTrunc(win_h * 3, 10)));
    scroll.setChild(lw);
    scroll.as(gtk.Widget).addCssClass("link-scroll");
    // Not a focus stop (the Electron URL box is a plain div): Tab moves
    // between the buttons only. The URL stays selectable with the mouse.
    scroll.as(gtk.Widget).setCanFocus(0);
    box.append(scroll.as(gtk.Widget));

    const actions = ui.actionsRow();
    const cancel = ui.button("Cancel", .normal);
    const copy = ui.button("Copy", .normal);
    actions.append(cancel.as(gtk.Widget));
    actions.append(copy.as(gtk.Widget));
    c.cancel_button = cancel;
    c.copy_button = copy;
    _ = gtk.Button.signals.clicked.connect(cancel, *Chooser, onCancel, c, .{});
    _ = gtk.Button.signals.clicked.connect(copy, *Chooser, onCopy, c, .{});
    if (model.chooserOpenLabel(kind)) |open_label| {
        const open = ui.button(open_label, .primary);
        actions.append(open.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(open, *Chooser, onOpen, c, .{});
        c.open_button = open;
    }
    box.append(actions.as(gtk.Widget));

    c.dialog.setChild(box.as(gtk.Widget));
    c.dialog.setTitle("Link options");
    if (c.open_button) |o| {
        c.dialog.setDefaultWidget(o.as(gtk.Widget));
        c.dialog.setFocus(o.as(gtk.Widget));
    } else {
        c.dialog.setFocus(copy.as(gtk.Widget));
    }
    _ = adw.Dialog.signals.closed.connect(c.dialog, *Chooser, onClosed, c, .{});
    choosers.append(alloc, c) catch {};
    ui.present(c.dialog, win.as(gtk.Widget));
}

fn onCancel(_: *gtk.Button, c: *Chooser) callconv(.c) void {
    press(c, .cancel);
}
fn onCopy(_: *gtk.Button, c: *Chooser) callconv(.c) void {
    press(c, .copy);
}
fn onOpen(_: *gtk.Button, c: *Chooser) callconv(.c) void {
    press(c, .open);
}

/// What each button does; the control socket enters here too.
pub fn press(c: *Chooser, which: Chooser.Button) void {
    switch (which) {
        .cancel => _ = c.dialog.close(),
        .copy => {
            // app.js closes first (focus off the modal), then copies.
            const url = alloc.dupe(u8, c.url) catch return;
            defer alloc.free(url);
            _ = c.dialog.close();
            copyToClipboard(url, "link copied");
        },
        .open => {
            if (model.chooserOpenLabel(c.kind) == null) return;
            launch(.uri, c.url, windowOf(c.parent));
            _ = c.dialog.close();
        },
    }
}

fn onClosed(_: *adw.Dialog, c: *Chooser) callconv(.c) void {
    for (choosers.items, 0..) |x, i| if (x == c) {
        _ = choosers.orderedRemove(i);
        break;
    };
    // Focus goes back to the pane the URL came from (app.js tile.focus()),
    // after libadwaita has put it back where it was when the chooser
    // opened (which may be another pane).
    if (c.parent) |p| _ = glib.idleAddOnce(refocus, p);
    alloc.free(c.url);
    alloc.destroy(c);
}

fn refocus(ud: ?*anyopaque) callconv(.c) void {
    const p: *gtk.Widget = @ptrCast(@alignCast(ud orelse return));
    defer p.as(gobject.Object).unref();
    if (p.getRoot() == null) return;
    // A terminal pane's focus target is its render surface; anything else
    // takes focus itself or gives it to its first focusable child.
    if (gobject.ext.cast(TerminalPane, p)) |tp| {
        tp.grabFocus();
    } else if (p.grabFocus() == 0) {
        _ = p.childFocus(.tab_forward);
    }
}

pub fn topChooser() ?*Chooser {
    if (choosers.items.len == 0) return null;
    return choosers.items[choosers.items.len - 1];
}
