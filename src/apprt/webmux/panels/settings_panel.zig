//! The one preferences dialog (deviation 67): an `AdwPreferencesDialog`
//! holding the General page built here and, in the normal app, the
//! Connections page (chrome/page.zig). PARITY E-10…E-15.
//!
//! The dialog lives as long as the window, so reopening it finds it as it
//! was left (a half-typed profile form included). `dialog()` makes it;
//! `ensure()` adds General, after any page that goes before it.
//!
//! The fade slider previews live and is saved once it has stopped moving
//! for 400 ms (and when the dialog closes): GTK's slider has no "released"
//! signal, so this stands in for the range input's `change` event. Column
//! widths commit on Enter or leaving the field, then both show the clamped
//! values. The page follows changes made elsewhere (E-15), except in a
//! number field that has the keyboard focus.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const conn = @import("../../../webmux/conn.zig");
const Application = @import("../application.zig").Application;
const model = @import("model.zig");
const settings = @import("settings.zig");
const ui = @import("ui.zig");

const log = std.log.scoped(.webmux_panels);
const alloc = std.heap.c_allocator;

/// The fade slider is saved this long after it stops moving.
pub const fade_settle_ms = 400;

pub const Panel = struct {
    page: *adw.PreferencesPage,
    theme: *adw.ComboRow,
    fade: *gtk.Scale,
    fade_value: *gtk.Label,
    min: *adw.SpinRow,
    max: *adw.SpinRow,
    open_log: *gtk.Button,
    /// Set while the panel writes its own controls (handlers ignore it).
    syncing: bool = false,
    /// Pending save of a fade preview, 0 when none.
    fade_timer: c_uint = 0,
};

pub var panel: ?*Panel = null;
/// Called when `close` starts, while focus is still in the dialog.
pub var on_closing: ?*const fn () void = null;
/// Called once the dialog has closed (the chrome puts focus back).
pub var on_closed: ?*const fn () void = null;

var shared: ?*adw.PreferencesDialog = null;
var is_open: bool = false;

const lead_text = "Apply to every host on this client.";
const fade_desc = "How much panes other than the focused one dim. 0% leaves them untouched.";
const min_desc = "No column is narrower than this. As many columns as fit at this width share the window exactly; open more and the layout scrolls sideways.";
const max_desc = "No column is wider than this. Fewer columns than fit the window grow to share it up to this width and sit centred.";
const log_desc = "Tunnel setup, teardown, and reconnect events for every host on this client, live and copyable. Also written to a file on disk.";

/// The dialog, made on first use and kept until `reset`.
pub fn dialog() *adw.PreferencesDialog {
    if (shared) |d| return d;
    const d = adw.PreferencesDialog.new();
    _ = d.as(gobject.Object).refSink();
    // Always floating: ui.present hooks the backdrop of the sheet it finds,
    // which a switch to a bottom sheet would replace.
    d.as(adw.Dialog).setPresentationMode(.floating);
    // Tall enough for the whole profile form in a normal window.
    d.as(adw.Dialog).setContentHeight(720);
    _ = adw.Dialog.signals.closed.connect(d.as(adw.Dialog), ?*anyopaque, onClosed, null, .{});
    // Escape drops an uncommitted width edit (app.js: the input's change
    // event never fires), before the dialog closes and the field's
    // focus-out would commit it.
    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, ?*anyopaque, onDialogKey, null, .{});
    d.as(gtk.Widget).addController(keys.as(gtk.EventController));
    shared = d;
    return d;
}

pub fn isOpen() bool {
    return is_open;
}

/// Show the dialog on `parent`, or leave it up if it is.
pub fn present(parent: *gtk.Widget) void {
    is_open = true;
    ui.present(dialog().as(adw.Dialog), parent);
}

/// `app.show-settings`: the dialog, on General.
pub fn show() void {
    const app = Application.default();
    const win = app.activeWindow() orelse {
        log.warn("settings: no window to show the panel on", .{});
        return;
    };
    const p = ensure();
    const d = dialog();
    _ = d.popSubpage();
    d.setVisiblePage(p.page);
    present(win.as(gtk.Widget));
    // Not AdwDialog.setFocus: it does nothing when reopening on the widget
    // it already remembers.
    _ = p.theme.as(gtk.Widget).grabFocus();
}

/// Close the dialog, whichever page it is on.
pub fn close() void {
    if (!is_open) return;
    if (on_closing) |f| f();
    if (shared) |d| _ = d.as(adw.Dialog).close();
}

/// The window is going: drop the dialog and everything in it.
pub fn reset() void {
    flushFade();
    if (settings.on_change == onSettingsChanged) settings.on_change = null;
    if (panel) |p| alloc.destroy(p);
    panel = null;
    if (shared) |d| d.as(gobject.Object).unref();
    shared = null;
    is_open = false;
}

/// Add the General page to the dialog, once.
pub fn ensure() *Panel {
    if (panel) |p| return p;

    const page = adw.PreferencesPage.new();
    page.setTitle("General");
    page.setIconName("emblem-system-symbolic");
    page.setDescription(lead_text);

    const look = adw.PreferencesGroup.new();
    look.setTitle("Appearance");

    var labels: [model.themes.len + 1]?[*:0]const u8 = undefined;
    for (model.themes, 0..) |t, i| labels[i] = t.label.ptr;
    labels[model.themes.len] = null;
    const themes = gtk.StringList.new(@ptrCast(&labels));
    defer themes.unref();
    const theme = adw.ComboRow.new();
    theme.as(adw.PreferencesRow).setTitle("Color scheme");
    theme.setModel(themes.as(gio.ListModel));
    look.add(theme.as(gtk.Widget));

    const fade = gtk.Scale.newWithRange(.horizontal, 0, 100, 5);
    fade.setDrawValue(0);
    fade.setDigits(0);
    fade.as(gtk.Widget).setSizeRequest(170, -1);
    fade.as(gtk.Widget).setValign(.center);
    const fade_value = ui.label("", "numeric");
    fade_value.setWidthChars(4);
    fade_value.setXalign(1);
    const fade_row = adw.ActionRow.new();
    fade_row.as(adw.PreferencesRow).setTitle("Unfocused pane fade");
    fade_row.setSubtitle(fade_desc);
    fade_row.addSuffix(fade.as(gtk.Widget));
    fade_row.addSuffix(fade_value.as(gtk.Widget));
    fade_row.as(gtk.Widget).setFocusable(0); // Tab goes to the slider
    look.add(fade_row.as(gtk.Widget));
    page.add(look);

    const widths = adw.PreferencesGroup.new();
    widths.setTitle("Terminal width");
    const min = spin("Minimum width (columns)", min_desc);
    const max = spin("Maximum width (columns)", max_desc);
    widths.add(min.as(gtk.Widget));
    widths.add(max.as(gtk.Widget));
    page.add(widths);

    const logs = adw.PreferencesGroup.new();
    const open_log = gtk.Button.newWithLabel("Open log…");
    open_log.as(gtk.Widget).setValign(.center);
    const log_row = adw.ActionRow.new();
    log_row.as(adw.PreferencesRow).setTitle("Connection log");
    log_row.setSubtitle(log_desc);
    log_row.addSuffix(open_log.as(gtk.Widget));
    log_row.as(gtk.Widget).setFocusable(0); // Tab goes to the button
    logs.add(log_row.as(gtk.Widget));
    page.add(logs);

    const p = alloc.create(Panel) catch @panic("OOM");
    p.* = .{
        .page = page,
        .theme = theme,
        .fade = fade,
        .fade_value = fade_value,
        .min = min,
        .max = max,
        .open_log = open_log,
    };
    panel = p;
    dialog().add(page);
    sync(&settings.current());
    settings.on_change = onSettingsChanged;

    _ = gobject.Object.signals.notify.connect(theme, *Panel, onTheme, p, .{ .detail = "selected" });
    _ = gtk.Range.signals.value_changed.connect(fade.as(gtk.Range), *Panel, onFade, p, .{});
    _ = gobject.Object.signals.notify.connect(min, *Panel, onMin, p, .{ .detail = "value" });
    _ = gobject.Object.signals.notify.connect(max, *Panel, onMax, p, .{ .detail = "value" });
    _ = gtk.Button.signals.clicked.connect(open_log, *Panel, onOpenLog, p, .{});
    return p;
}

fn spin(title: [:0]const u8, desc: [:0]const u8) *adw.SpinRow {
    const s = adw.SpinRow.newWithRange(40, 400, 1);
    s.as(adw.PreferencesRow).setTitle(title);
    s.as(adw.ActionRow).setSubtitle(desc);
    s.setDigits(0);
    // Not `numeric`: that silently drops a typed '.', so 12.7 would
    // commit as 127. The text is parsed as a number (strtod) instead;
    // junk leaves the value unchanged, as Number() → NaN does in app.js.
    s.setNumeric(0);
    return s;
}

fn hasFocus(w: *gtk.Widget) bool {
    const root = w.getRoot() orelse return false;
    const focus = root.getFocus() orelse return false;
    return focus == w or focus.isAncestor(w) != 0;
}

/// Show `s` in the controls (a number field being edited keeps its text).
fn sync(s: *const conn.Settings) void {
    const p = panel orelse return;
    p.syncing = true;
    defer p.syncing = false;
    p.theme.setSelected(@intCast(model.themeIndex(s.theme.slice())));
    p.fade.as(gtk.Range).setValue(@floatFromInt(s.unfocused_fade));
    setFadeReadout(p, s.unfocused_fade);
    if (!hasFocus(p.min.as(gtk.Widget))) p.min.setValue(@floatFromInt(s.min_cols));
    if (!hasFocus(p.max.as(gtk.Widget))) p.max.setValue(@floatFromInt(s.max_cols));
}

fn setFadeReadout(p: *Panel, v: anytype) void {
    var buf: [16]u8 = undefined;
    const t = std.fmt.bufPrintSentinel(&buf, "{d}%", .{v}, 0) catch return;
    p.fade_value.setText(t.ptr);
}

fn onSettingsChanged(s: *const conn.Settings) void {
    sync(s);
}

fn onTheme(row: *adw.ComboRow, _: *gobject.ParamSpec, p: *Panel) callconv(.c) void {
    if (p.syncing) return;
    const i = row.getSelected();
    if (i >= model.themes.len) return;
    _ = settings.update(.{ .theme = model.themes[i].id }, true);
}

fn onFade(r: *gtk.Range, p: *Panel) callconv(.c) void {
    if (p.syncing) return;
    const raw = r.getValue();
    // step="5": the range input snaps to multiples of 5.
    const snapped = @round(raw / 5) * 5;
    if (snapped != raw) {
        r.setValue(snapped); // re-enters with the snapped value
        return;
    }
    setFadeReadout(p, @as(i64, @intFromFloat(snapped)));
    _ = settings.update(.{ .unfocused_fade = snapped }, false);
    if (p.fade_timer != 0) _ = glib.Source.remove(p.fade_timer);
    p.fade_timer = glib.timeoutAdd(fade_settle_ms, onFadeSettled, p);
}

fn onFadeSettled(ud: ?*anyopaque) callconv(.c) c_int {
    const p: *Panel = @ptrCast(@alignCast(ud.?));
    p.fade_timer = 0;
    settings.persistCurrent();
    return 0;
}

/// The fade slider was released / settled: save now (control socket, and
/// on close).
pub fn flushFade() void {
    const p = panel orelse return;
    if (p.fade_timer == 0) return;
    _ = glib.Source.remove(p.fade_timer);
    p.fade_timer = 0;
    settings.persistCurrent();
}

fn onMin(s: *adw.SpinRow, _: *gobject.ParamSpec, p: *Panel) callconv(.c) void {
    if (p.syncing) return;
    const now = settings.update(.{ .min_cols = s.getValue() }, true);
    showClamped(p, &now);
}

fn onMax(s: *adw.SpinRow, _: *gobject.ParamSpec, p: *Panel) callconv(.c) void {
    if (p.syncing) return;
    const now = settings.update(.{ .max_cols = s.getValue() }, true);
    showClamped(p, &now);
}

/// app.js: after a width change both fields show the clamped values.
fn showClamped(p: *Panel, s: *const conn.Settings) void {
    p.syncing = true;
    defer p.syncing = false;
    p.min.setValue(@floatFromInt(s.min_cols));
    p.max.setValue(@floatFromInt(s.max_cols));
}

fn onDialogKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, _: ?*anyopaque) callconv(.c) c_int {
    if (keyval != gdk.KEY_Escape) return 0;
    const p = panel orelse return 0;
    const now = settings.current();
    if (hasFocus(p.min.as(gtk.Widget))) restoreText(p.min, now.min_cols);
    if (hasFocus(p.max.as(gtk.Widget))) restoreText(p.max, now.max_cols);
    return 0; // the dialog still closes
}

/// Put the committed value back in the field's text (setting the value it
/// already has would leave the edit there for focus-out to commit).
fn restoreText(s: *adw.SpinRow, v: anytype) void {
    var buf: [32]u8 = undefined;
    const t = std.fmt.bufPrintSentinel(&buf, "{d}", .{v}, 0) catch return;
    s.as(gtk.Editable).setText(t.ptr);
}

fn onOpenLog(_: *gtk.Button, _: *Panel) callconv(.c) void {
    Application.default().as(gio.ActionGroup).activateAction("show-log", null);
}

fn onClosed(_: *adw.Dialog, _: ?*anyopaque) callconv(.c) void {
    flushFade();
    is_open = false;
    if (on_closed) |f| f();
}

// --- control socket ----------------------------------------------------

pub const Dump = struct {
    open: bool,
    theme: ?[]const u8 = null,
    theme_label: ?[]const u8 = null,
    fade: ?f64 = null,
    fade_readout: ?[]const u8 = null,
    min_cols: ?f64 = null,
    max_cols: ?f64 = null,
    fade_save_pending: bool = false,
    focus: ?[]const u8 = null,
};

pub fn dump() Dump {
    if (!is_open) return .{ .open = false };
    const p = panel orelse return .{ .open = true };
    const i = p.theme.getSelected();
    const focus: ?[]const u8 = if (hasFocus(p.theme.as(gtk.Widget))) "theme" else if (hasFocus(p.fade.as(gtk.Widget))) "fade" else if (hasFocus(p.min.as(gtk.Widget))) "min_cols" else if (hasFocus(p.max.as(gtk.Widget))) "max_cols" else if (hasFocus(p.open_log.as(gtk.Widget))) "open_log" else null;
    return .{
        .open = true,
        .theme = if (i < model.themes.len) model.themes[i].id else null,
        .theme_label = if (i < model.themes.len) model.themes[i].label else null,
        .fade = p.fade.as(gtk.Range).getValue(),
        .fade_readout = std.mem.span(p.fade_value.getText()),
        .min_cols = p.min.getValue(),
        .max_cols = p.max.getValue(),
        .fade_save_pending = p.fade_timer != 0,
        .focus = focus,
    };
}

pub const Control = enum { theme, fade, min_cols, max_cols, open_log, done };

/// Operate one control the way a user would (the widget's own signal runs
/// the same handler a click, drag step or Enter does). Number fields are
/// set as if typed and committed (Enter).
pub fn operate(which: Control, value: ?f64, theme_id: ?[]const u8) error{ NotOpen, BadValue }!void {
    if (!is_open) return error.NotOpen;
    const p = panel orelse return error.NotOpen;
    switch (which) {
        .theme => {
            const id = theme_id orelse return error.BadValue;
            if (!model.knownTheme(id)) return error.BadValue;
            p.theme.setSelected(@intCast(model.themeIndex(id)));
        },
        .fade => p.fade.as(gtk.Range).setValue(value orelse return error.BadValue),
        .min_cols, .max_cols => {
            const s = if (which == .min_cols) p.min else p.max;
            const v = value orelse return error.BadValue;
            var buf: [32]u8 = undefined;
            const t = std.fmt.bufPrintSentinel(&buf, "{d}", .{v}, 0) catch return error.BadValue;
            s.as(gtk.Editable).setText(t.ptr);
            s.update(); // what Enter / focus-out does
        },
        .open_log => _ = p.open_log.as(gtk.Widget).activate(),
        .done => close(),
    }
}
