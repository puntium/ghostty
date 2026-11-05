//! The application menu (ruling N-16: a header-bar menu button in place
//! of Electron's hidden Alt-tap menu bar) and the `app.*` actions behind it
//! and behind the app shortcuts (PARITY W-41…W-45, K-20…K-26).
//!
//! The menu mirrors electron/main.js buildMenu: webmux, Edit, View, Pane,
//! Window. Shortcut hints are display-only (`accel` attribute); the keys
//! themselves go through shortcuts.zig. Items whose action is not
//! registered (app.show-settings / app.show-log before the panels exist)
//! show insensitive and do nothing.
const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const ext = @import("../ext.zig");
const Application = @import("../application.zig").Application;
const TerminalPane = @import("../pane.zig").TerminalPane;
const hub = @import("hub.zig");

const log = std.log.scoped(.webmux_chrome);

/// The pane commands of the Pane menu (main.js PANE_MENU), Linux strings.
pub const pane_menu = [_]?struct { label: [:0]const u8, accel: [:0]const u8, cmd: [:0]const u8 }{
    .{ .label = "New Terminal", .accel = "<Control><Shift>Return", .cmd = "new-terminal" },
    .{ .label = "New Terminal Below", .accel = "<Alt><Control><Shift>Return", .cmd = "new-terminal-below" },
    .{ .label = "New File Browser", .accel = "<Control><Shift>b", .cmd = "new-files" },
    .{ .label = "Close Pane", .accel = "<Control><Shift>w", .cmd = "close-pane" },
    .{ .label = "Full Window", .accel = "<Control><Shift>f", .cmd = "toggle-full" },
    null,
    .{ .label = "Focus Left", .accel = "<Control><Shift>Left", .cmd = "focus-left" },
    .{ .label = "Focus Right", .accel = "<Control><Shift>Right", .cmd = "focus-right" },
    .{ .label = "Focus Up", .accel = "<Control><Shift>Up", .cmd = "focus-up" },
    .{ .label = "Focus Down", .accel = "<Control><Shift>Down", .cmd = "focus-down" },
    null,
    .{ .label = "Expel or Merge Left", .accel = "<Control><Shift>bracketleft", .cmd = "consume-expel-left" },
    .{ .label = "Expel or Merge Right", .accel = "<Control><Shift>bracketright", .cmd = "consume-expel-right" },
    null,
    .{ .label = "Move Column Left", .accel = "<Alt><Control><Shift>Left", .cmd = "move-column-left" },
    .{ .label = "Move Column Right", .accel = "<Alt><Control><Shift>Right", .cmd = "move-column-right" },
    .{ .label = "Move Pane Up", .accel = "<Alt><Control><Shift>Up", .cmd = "move-pane-up" },
    .{ .label = "Move Pane Down", .accel = "<Alt><Control><Shift>Down", .cmd = "move-pane-down" },
};

var menu_model: ?*gio.Menu = null;

/// The menu (built once, shared).
pub fn model() *gio.MenuModel {
    if (menu_model == null) menu_model = build();
    return menu_model.?.as(gio.MenuModel);
}

fn item(m: *gio.Menu, label: [:0]const u8, action: [:0]const u8, accel: ?[:0]const u8) void {
    const it = gio.MenuItem.new(label.ptr, action.ptr);
    defer it.unref();
    if (accel) |a| it.setAttributeValue("accel", glib.Variant.newString(a.ptr));
    m.appendItem(it);
}

fn section(parent: *gio.Menu, m: *gio.Menu) void {
    parent.appendSection(null, m.as(gio.MenuModel));
    m.unref();
}

fn build() *gio.Menu {
    const root = gio.Menu.new();

    // webmux (W-41)
    {
        const sub = gio.Menu.new();
        const a = gio.Menu.new();
        item(a, "About webmux", "app.about", null);
        section(sub, a);
        const b = gio.Menu.new();
        item(b, "Connections…", iface.actions.show_connections, "<Control><Shift>o");
        item(b, "Reconnect", "app.reconnect", "<Control><Shift>r");
        item(b, "Open Config File", "app.open-config", null);
        item(b, "Connection Log…", iface.actions.show_log, "<Control><Shift>g");
        section(sub, b);
        const c = gio.Menu.new();
        item(c, "Settings…", iface.actions.show_settings, "<Control>comma");
        section(sub, c);
        const d = gio.Menu.new();
        item(d, "Quit", "app.quit", null);
        section(sub, d);
        root.appendSubmenu("webmux", sub.as(gio.MenuModel));
        sub.unref();
    }
    // Edit (W-42)
    {
        const sub = gio.Menu.new();
        const a = gio.Menu.new();
        item(a, "Undo", "app.edit-undo", "<Control>z");
        item(a, "Redo", "app.edit-redo", "<Control><Shift>z");
        section(sub, a);
        const b = gio.Menu.new();
        item(b, "Cut", "app.edit-cut", "<Control>x");
        item(b, "Copy", "app.edit-copy", "<Control><Shift>c");
        item(b, "Paste", "app.edit-paste", "<Control>v");
        item(b, "Delete", "app.edit-delete", null);
        section(sub, b);
        const c = gio.Menu.new();
        item(c, "Select All", "app.edit-select-all", "<Control>a");
        section(sub, c);
        root.appendSubmenu("Edit", sub.as(gio.MenuModel));
        sub.unref();
    }
    // View (W-43; A-15: no reload, Reconnect covers it; N-11: no devtools)
    {
        const sub = gio.Menu.new();
        const a = gio.Menu.new();
        item(a, "Reset Zoom", "app.zoom-reset", "<Control>0");
        item(a, "Zoom In", "app.zoom-in", "<Control>equal");
        item(a, "Zoom Out", "app.zoom-out", "<Control>minus");
        section(sub, a);
        const b = gio.Menu.new();
        item(b, "Toggle Full Screen", "app.fullscreen", null);
        section(sub, b);
        root.appendSubmenu("View", sub.as(gio.MenuModel));
        sub.unref();
    }
    // Pane (W-44)
    {
        const sub = gio.Menu.new();
        var sec = gio.Menu.new();
        for (pane_menu) |entry| {
            const e = entry orelse {
                section(sub, sec);
                sec = gio.Menu.new();
                continue;
            };
            var buf: [96]u8 = undefined;
            const detailed = std.fmt.bufPrintSentinel(&buf, "app.pane-command::{s}", .{e.cmd}, 0) catch continue;
            item(sec, e.label, detailed, e.accel);
        }
        section(sub, sec);
        root.appendSubmenu("Pane", sub.as(gio.MenuModel));
        sub.unref();
    }
    // Window (W-45)
    {
        const sub = gio.Menu.new();
        const a = gio.Menu.new();
        item(a, "Minimize", "app.minimize", null);
        section(sub, a);
        const b = gio.Menu.new();
        item(b, "Previous Host", "app.host-prev", "<Control>Page_Up");
        item(b, "Next Host", "app.host-next", "<Control>Page_Down");
        section(sub, b);
        const c = gio.Menu.new();
        inline for (1..10) |n| {
            const ns = std.fmt.comptimePrint("{d}", .{n});
            item(c, "Host " ++ ns, "app.host-" ++ ns, "<Control>" ++ ns);
        }
        section(sub, c);
        root.appendSubmenu("Window", sub.as(gio.MenuModel));
        sub.unref();
    }
    return root;
}

/// Labels and actions of every menu item (for the control socket).
pub const Item = struct { menu: []const u8, label: []const u8, action: []const u8, target: ?[]const u8, enabled: bool };

pub fn listItems(a: std.mem.Allocator) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    const root = model();
    const app = Application.default().as(gio.ActionGroup);
    var i: c_int = 0;
    while (i < root.getNItems()) : (i += 1) {
        const top_label = attrString(a, root, i, "label") orelse "";
        const sub = root.getItemLink(i, "submenu") orelse continue;
        defer sub.unref();
        var s: c_int = 0;
        while (s < sub.getNItems()) : (s += 1) {
            const sec = sub.getItemLink(s, "section") orelse continue;
            defer sec.unref();
            var k: c_int = 0;
            while (k < sec.getNItems()) : (k += 1) {
                const action = attrString(a, sec, k, "action") orelse continue;
                const target = attrString(a, sec, k, "target");
                const name = if (std.mem.startsWith(u8, action, "app.")) action[4..] else action;
                const nz = try a.dupeSentinel(u8, name, 0);
                try out.append(a, .{
                    .menu = top_label,
                    .label = attrString(a, sec, k, "label") orelse "",
                    .action = action,
                    .target = target,
                    .enabled = app.hasAction(nz.ptr) != 0 and app.getActionEnabled(nz.ptr) != 0,
                });
            }
        }
    }
    return out.items;
}

fn attrString(a: std.mem.Allocator, m: *gio.MenuModel, i: c_int, attr: [:0]const u8) ?[]const u8 {
    const v = m.getItemAttributeValue(i, attr.ptr, null) orelse return null;
    defer v.unref();
    const t = std.mem.span(v.getTypeString());
    if (!std.mem.eql(u8, t, "s")) return null;
    var n: usize = 0;
    const p = v.getString(&n);
    return a.dupe(u8, p[0..n]) catch null;
}

/// Activate a menu item the way the popover does (control socket).
pub fn activateItem(action: []const u8, target: ?[]const u8) bool {
    if (!std.mem.startsWith(u8, action, "app.")) return false;
    var buf: [96]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&buf, "{s}", .{action[4..]}, 0) catch return false;
    const app = Application.default().as(gio.ActionGroup);
    if (app.hasAction(name.ptr) == 0) return false;
    var tb: [96]u8 = undefined;
    const param: ?*glib.Variant = if (target) |t| glib.Variant.newString((std.fmt.bufPrintSentinel(&tb, "{s}", .{t}, 0) catch return false).ptr) else null;
    app.activateAction(name.ptr, param);
    return true;
}

/// Activate `app.<name>` if it exists (activating a missing action would
/// warn).
pub fn activateApp(detailed: [:0]const u8) void {
    const name = if (std.mem.startsWith(u8, detailed, "app.")) detailed[4..] else detailed;
    var buf: [96]u8 = undefined;
    const nz = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return;
    const app = Application.default().as(gio.ActionGroup);
    if (app.hasAction(nz.ptr) == 0) {
        log.info("{s}: not registered (yet)", .{detailed});
        return;
    }
    app.activateAction(nz.ptr, null);
}

// ---------------------------------------------------------------------------
// app.* actions
// ---------------------------------------------------------------------------

const Ctx = struct {};
var ctx: Ctx = .{};

const A = ext.actions.Action(Ctx);

pub fn registerActions(app: *Application) void {
    const s = glib.VariantType.new("s");
    defer s.free();
    const actions = [_]A{
        .init("show-connections", actShowConnections, null),
        .init("reconnect", actReconnect, null),
        .init("open-config", actOpenConfig, null),
        .init("about", actAbout, null),
        .init("host-next", actHostNext, null),
        .init("host-prev", actHostPrev, null),
        .init("host-1", actHost1, null),
        .init("host-2", actHost2, null),
        .init("host-3", actHost3, null),
        .init("host-4", actHost4, null),
        .init("host-5", actHost5, null),
        .init("host-6", actHost6, null),
        .init("host-7", actHost7, null),
        .init("host-8", actHost8, null),
        .init("host-9", actHost9, null),
        .init("pane-command", actPaneCommand, s),
        .init("edit-undo", actUndo, null),
        .init("edit-redo", actRedo, null),
        .init("edit-cut", actCut, null),
        .init("edit-copy", actCopy, null),
        .init("edit-paste", actPaste, null),
        .init("edit-delete", actDelete, null),
        .init("edit-select-all", actSelectAll, null),
        .init("zoom-reset", actZoomReset, null),
        .init("zoom-in", actZoomIn, null),
        .init("zoom-out", actZoomOut, null),
        .init("fullscreen", actFullscreen, null),
        .init("minimize", actMinimize, null),
    };
    ext.actions.addToMap(Ctx, &ctx, app.as(gio.ActionMap), &actions);
}

fn actShowConnections(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    hub.userShow(null);
}
fn actReconnect(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    hub.reconnectActive();
}
fn actHostNext(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    hub.showAdjacent(1);
}
fn actHostPrev(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    hub.showAdjacent(-1);
}
fn hostN(comptime n: usize) fn (*gio.SimpleAction, ?*glib.Variant, *Ctx) callconv(.c) void {
    return struct {
        fn f(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
            hub.showNth(n - 1);
        }
    }.f;
}
const actHost1 = hostN(1);
const actHost2 = hostN(2);
const actHost3 = hostN(3);
const actHost4 = hostN(4);
const actHost5 = hostN(5);
const actHost6 = hostN(6);
const actHost7 = hostN(7);
const actHost8 = hostN(8);
const actHost9 = hostN(9);

fn actPaneCommand(_: *gio.SimpleAction, param: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    const p = param orelse return;
    var n: usize = 0;
    const s = p.getString(&n);
    hub.paneCommand(s[0..n]);
}

fn actOpenConfig(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    const engine = hub.hub.engine orelse return;
    // Through the panels' launch sink, so a test run records it instead
    // of starting an application (C-9).
    const file = gio.File.newForPath(@ptrCast((std.fmt.bufPrintSentinel(&path_buf, "{s}", .{engine.configPath()}, 0) catch return).ptr));
    defer file.unref();
    const uri = file.getUri();
    defer glib.free(uri);
    const parent: ?*gtk.Window = if (hub.hub.window) |w| w.as(gtk.Window) else null;
    log.info("open config file {s}", .{engine.configPath()});
    @import("../panels/url.zig").launch(.uri, std.mem.span(uri), parent);
}

var path_buf: [4096]u8 = undefined;

fn actAbout(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    const d = adw.AboutDialog.new();
    d.setApplicationName("webmux");
    d.setVersion(@import("../../../build_config.zig").version_string.ptr);
    d.setComments("Terminals on your hosts, over ssh.");
    d.as(adw.Dialog).present(if (hub.hub.window) |w| w.as(gtk.Widget) else null);
}

fn actFullscreen(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    const w = (hub.hub.window orelse return).as(gtk.Window);
    if (w.isFullscreen() != 0) w.unfullscreen() else w.fullscreen();
}

fn actMinimize(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    (hub.hub.window orelse return).as(gtk.Window).minimize();
}

// -- Edit: the focused text field's own actions, or the terminal's --------

fn focusWidget() ?*gtk.Widget {
    // The dev-mode window (WEBMUX_GTK_DEV_SOCKET) is not the hub's.
    // From the ☰ menu the popover holds focus when an item fires: act on
    // what the user was working in before it opened (N1).
    if (hub.hub.window != null) return hub.contentFocus();
    const w: *gtk.Window = Application.default().as(gtk.Application).getActiveWindow() orelse return null;
    return w.getFocus();
}

fn focusedTerminal() ?*TerminalPane {
    const f = focusWidget() orelse return null;
    return ext.getAncestor(TerminalPane, f);
}

fn editAction(name: [:0]const u8) void {
    const f = focusWidget() orelse return;
    _ = f.activateAction(name.ptr, null);
}

fn terminalBinding(action: @import("../../../input.zig").Binding.Action) bool {
    const pane = focusedTerminal() orelse return false;
    const surface = pane.core() orelse return true;
    _ = surface.performBindingAction(action) catch |err| log.warn("terminal action failed: {t}", .{err});
    return true;
}

fn actUndo(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    if (focusedTerminal() == null) editAction("text.undo");
}
fn actRedo(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    if (focusedTerminal() == null) editAction("text.redo");
}
// Terminal copy/paste go through the pane's own clipboard code (plain
// text, no toast; images take the image-paste flow), never Ghostty's
// bindings, whose clipboard writes the pane treats as OSC 52 (C-06, D-04).
fn actCut(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    if (focusedTerminal()) |pane| {
        _ = pane.copyToClipboard();
    } else editAction("clipboard.cut");
}
fn actCopy(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    if (focusedTerminal()) |pane| {
        _ = pane.copyToClipboard();
    } else editAction("clipboard.copy");
}
fn actPaste(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    if (focusedTerminal()) |pane| {
        pane.pasteFromClipboard();
    } else editAction("clipboard.paste");
}
fn actDelete(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    if (focusedTerminal() == null) editAction("selection.delete");
}
fn actSelectAll(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    if (!terminalBinding(.select_all)) editAction("selection.select-all");
}

// -- View: zoom (K-31) every terminal of the visible host ------------------

fn zoomAll(action: @import("../../../input.zig").Binding.Action) void {
    const win = hub.hub.window orelse return;
    if (hub.hub.active == null) return;
    var buf: [64]*TerminalPane = undefined;
    for (win.panes(&buf)) |p| {
        // Only the front host's panes are mapped.
        if (p.as(gtk.Widget).getMapped() == 0) continue;
        const surface = p.core() orelse continue;
        _ = surface.performBindingAction(action) catch {};
    }
}

fn actZoomReset(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    zoomAll(.reset_font_size);
}
fn actZoomIn(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    zoomAll(.{ .increase_font_size = 1 });
}
fn actZoomOut(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Ctx) callconv(.c) void {
    zoomAll(.{ .decrease_font_size = 1 });
}
