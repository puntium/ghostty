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
//!            parent's window: an AdwAlertDialog with the URL, then Cancel,
//!            Copy, and Open in browser (suggested, initial focus). Escape
//!            cancels. Closing returns focus to `parent`.
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
    dialog: *adw.AlertDialog,
    url: [:0]u8,
    kind: model.UrlKind,
    /// Strong ref; focus goes back there on close.
    parent: ?*gtk.Widget,
    label: *gtk.Label,
    /// The tag names are the dialog's response ids.
    pub const Button = enum { cancel, copy, open };
};

/// Open choosers, oldest first (each one stacks over the previous).
pub var choosers: std.ArrayList(*Chooser) = .empty;

pub fn showChooser(url: []const u8, parent: ?*gtk.Widget) void {
    const win = windowOf(parent) orelse {
        log.warn("link chooser: no window", .{});
        return;
    };
    const z = alloc.dupeSentinel(u8, url, 0) catch return;

    // The exact URL: breaks anywhere and Pango must not add hyphens at the
    // breaks. Through markup, because a Pango attribute list would need a
    // direct libpango call. An extra child rather than the dialog's body,
    // which cannot be selected; both scroll with the message area, above
    // the buttons.
    const label = gtk.Label.new(null);
    const escaped = glib.markupEscapeText(z.ptr, -1);
    defer glib.free(escaped);
    const markup = std.fmt.allocPrintSentinel(alloc, "<span insert_hyphens=\"false\">{s}</span>", .{std.mem.span(escaped)}, 0) catch {
        alloc.free(z);
        return;
    };
    defer alloc.free(markup);
    label.setMarkup(markup.ptr);
    label.setWrap(1);
    label.setWrapMode(.char);
    label.setSelectable(1);
    const lw = label.as(gtk.Widget);
    lw.addCssClass("monospace");
    lw.addCssClass("accent");
    lw.setCanFocus(0);

    const kind = model.urlKind(url);
    const dialog = adw.AlertDialog.new("Link options", null);
    dialog.setExtraChild(lw);
    // Not a focus stop, nor is the scrolled window around the message area
    // (GTK makes it one when no child takes focus): Tab moves between the
    // buttons only. The URL stays selectable with the mouse.
    if (ext.getAncestor(gtk.ScrolledWindow, lw)) |s| s.as(gtk.Widget).setCanFocus(0);
    dialog.setPreferWideLayout(1);
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("copy", "Copy");
    dialog.setCloseResponse("cancel");
    if (model.chooserOpenLabel(kind)) |open_label| {
        dialog.addResponse("open", open_label);
        dialog.setResponseAppearance("open", .suggested);
        dialog.setDefaultResponse("open");
    } else {
        dialog.setDefaultResponse("copy");
    }

    const c = alloc.create(Chooser) catch {
        alloc.free(z);
        return;
    };
    c.* = .{
        .dialog = dialog,
        .url = z,
        .kind = kind,
        .parent = if (parent) |p| blk: {
            _ = p.as(gobject.Object).ref();
            break :blk p;
        } else null,
        .label = label,
    };
    _ = adw.AlertDialog.signals.response.connect(dialog, *Chooser, onResponse, c, .{});
    choosers.append(alloc, c) catch {};
    dialog.as(adw.Dialog).present(win.as(gtk.Widget));
}

/// Press a button from code (the control socket, the hub). The dialog has
/// no call for that, but closing it answers with its close response.
pub fn press(c: *Chooser, which: Chooser.Button) void {
    if (which == .open and model.chooserOpenLabel(c.kind) == null) return;
    c.dialog.setCloseResponse(@tagName(which));
    _ = c.dialog.as(adw.Dialog).close();
}

/// Every way of closing ends here, once, so this also frees the chooser.
/// Not on `closed`: a button's response comes after that signal.
fn onResponse(_: *adw.AlertDialog, response: [*:0]const u8, c: *Chooser) callconv(.c) void {
    switch (std.meta.stringToEnum(Chooser.Button, std.mem.span(response)) orelse .cancel) {
        .cancel => {},
        .copy => copyToClipboard(c.url, "link copied"),
        .open => launch(.uri, c.url, windowOf(c.parent)),
    }
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
