//! The settings panel (PARITY E-10…E-15; electron/ui/app.js
//! showSettingsModal, electron/ui/index.html `.settings-modal`).
//!
//! A modal on the main window, one instance at a time: heading
//! `Settings`, lead `Apply to every host on this client.`, then one row per
//! setting separated by 1px borders, and `Done` (primary). Escape, a click
//! on the dimmed backdrop or Done closes it and focus goes back where it
//! was (the focused pane). The colour scheme select has the initial focus.
//!
//!   Color scheme            select; applies and saves on change
//!   Unfocused pane fade     slider 0–100 step 5 with an `N%` readout;
//!                           dragging previews live, the value is saved
//!                           once it has stopped moving for 400 ms (and
//!                           when the panel closes) — GTK's slider has no
//!                           "released" signal, so this stands in for the
//!                           range input's `change` event
//!   Minimum/Maximum width   number fields 40–400, `columns`; committed
//!                           on Enter or leaving the field, then both show
//!                           the clamped values (one can move the other)
//!   Connection log          `Open log…` opens the log window
//!
//! While open it follows changes made elsewhere (E-15), except in a number
//! field that has the keyboard focus.
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
    dialog: *adw.Dialog,
    theme: *gtk.DropDown,
    fade: *gtk.Scale,
    fade_value: *gtk.Label,
    min: *gtk.SpinButton,
    max: *gtk.SpinButton,
    open_log: *gtk.Button,
    done: *gtk.Button,
    scroller: ?*gtk.ScrolledWindow = null,
    /// Set while the panel writes its own controls (handlers ignore it).
    syncing: bool = false,
    /// Pending save of a fade preview, 0 when none.
    fade_timer: c_uint = 0,
};

pub var panel: ?*Panel = null;

const lead_text = "Apply to every host on this client.";
const fade_desc = "How much panes other than the focused one dim. 0% leaves them untouched.";
const min_desc = "No column is narrower than this. As many columns as fit at this width share the window exactly; open more and the layout scrolls sideways.";
const max_desc = "No column is wider than this. Fewer columns than fit the window grow to share it up to this width and sit centred.";
const log_desc = "Tunnel setup, teardown, and reconnect events for every host on this client, live and copyable. Also written to a file on disk.";

/// `app.show-settings`: open the panel (or leave the open one).
pub fn show() void {
    if (panel != null) return;
    const app = Application.default();
    const win = app.activeWindow() orelse {
        log.warn("settings: no window to show the panel on", .{});
        return;
    };

    const dialog = ui.modal("settings-modal");
    dialog.setFollowsContentSize(0);
    dialog.setContentWidth(460);
    dialog.setTitle("Settings");

    const box = gtk.Box.new(.vertical, 0);
    box.as(gtk.Widget).addCssClass("modal-body");
    box.append(ui.label("Settings", "settings-heading").as(gtk.Widget));
    box.append(ui.label(lead_text, "settings-lead").as(gtk.Widget));

    // Color scheme
    var labels: [model.themes.len + 1]?[*:0]const u8 = undefined;
    for (model.themes, 0..) |t, i| labels[i] = t.label.ptr;
    labels[model.themes.len] = null;
    const theme = gtk.DropDown.newFromStrings(@ptrCast(&labels));
    theme.as(gtk.Widget).addCssClass("setting-select");
    box.append(row("Color scheme", theme.as(gtk.Widget), null).as(gtk.Widget));

    // Unfocused pane fade
    const fade = gtk.Scale.newWithRange(.horizontal, 0, 100, 5);
    fade.setDrawValue(0);
    fade.setDigits(0);
    fade.as(gtk.Widget).setSizeRequest(170, -1);
    fade.as(gtk.Widget).addCssClass("setting-range");
    const fade_value = ui.label("", "setting-output");
    fade_value.setWidthChars(4);
    fade_value.setXalign(1);
    const fade_ctl = gtk.Box.new(.horizontal, 8);
    fade_ctl.append(fade.as(gtk.Widget));
    fade_ctl.append(fade_value.as(gtk.Widget));
    box.append(row("Unfocused pane fade", fade_ctl.as(gtk.Widget), fade_desc).as(gtk.Widget));

    // Minimum / maximum terminal width
    const min = spin();
    box.append(row("Minimum terminal width", withUnit(min), min_desc).as(gtk.Widget));
    const max = spin();
    box.append(row("Maximum terminal width", withUnit(max), max_desc).as(gtk.Widget));

    // Connection log
    const open_log = ui.button("Open log…", .normal);
    box.append(row("Connection log", open_log.as(gtk.Widget), log_desc).as(gtk.Widget));

    const actions = ui.actionsRow();
    actions.as(gtk.Widget).addCssClass("settings-actions");
    const done = ui.button("Done", .primary);
    actions.append(done.as(gtk.Widget));
    box.append(actions.as(gtk.Widget));

    // In a window too short for the panel, the panel scrolls.
    const scroller = gtk.ScrolledWindow.new();
    scroller.setPolicy(.never, .automatic);
    scroller.setPropagateNaturalHeight(1);
    scroller.setPropagateNaturalWidth(1);
    scroller.setChild(box.as(gtk.Widget));
    dialog.setChild(scroller.as(gtk.Widget));

    const p = alloc.create(Panel) catch return;
    p.* = .{
        .dialog = dialog,
        .theme = theme,
        .fade = fade,
        .fade_value = fade_value,
        .min = min,
        .max = max,
        .open_log = open_log,
        .done = done,
        .scroller = scroller,
    };
    panel = p;
    sync(&settings.current());
    settings.on_change = onSettingsChanged;

    _ = gobject.Object.signals.notify.connect(theme, *Panel, onTheme, p, .{ .detail = "selected" });
    _ = gtk.Range.signals.value_changed.connect(fade.as(gtk.Range), *Panel, onFade, p, .{});
    _ = gtk.SpinButton.signals.value_changed.connect(min, *Panel, onMin, p, .{});
    _ = gtk.SpinButton.signals.value_changed.connect(max, *Panel, onMax, p, .{});
    _ = gtk.Button.signals.clicked.connect(open_log, *Panel, onOpenLog, p, .{});
    _ = gtk.Button.signals.clicked.connect(done, *Panel, onDone, p, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Panel, onClosed, p, .{});
    // Escape drops an uncommitted width edit (app.js: the input's change
    // event never fires), before the dialog closes and the field's
    // focus-out would commit it.
    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Panel, onDialogKey, p, .{});
    dialog.as(gtk.Widget).addController(keys.as(gtk.EventController));

    dialog.setDefaultWidget(done.as(gtk.Widget));
    dialog.setFocus(theme.as(gtk.Widget));
    ui.present(dialog, win.as(gtk.Widget));
}

/// Close the panel, as Done does.
pub fn close() void {
    const p = panel orelse return;
    _ = p.dialog.close();
}

fn spin() *gtk.SpinButton {
    const s = gtk.SpinButton.newWithRange(40, 400, 1);
    s.setDigits(0);
    // Not `numeric`: that silently drops a typed '.', so 12.7 would
    // commit as 127. The text is parsed as a number (strtod) instead;
    // junk leaves the value unchanged, as Number() → NaN does in app.js.
    s.setNumeric(0);
    s.as(gtk.Editable).setWidthChars(4);
    s.as(gtk.Widget).addCssClass("setting-number");
    return s;
}

fn withUnit(s: *gtk.SpinButton) *gtk.Widget {
    const b = gtk.Box.new(.horizontal, 8);
    b.append(s.as(gtk.Widget));
    b.append(ui.label("columns", "setting-unit").as(gtk.Widget));
    return b.as(gtk.Widget);
}

/// `.setting`: label and control on one line, the description under both.
fn row(title: [:0]const u8, control: *gtk.Widget, desc: ?[:0]const u8) *gtk.Box {
    // A vertical box of [label … control] over the description: boxes
    // measure wrapping labels height-for-width consistently (a GtkGrid
    // with a spanning wrapped label made GTK warn on every open).
    const v = gtk.Box.new(.vertical, 0);
    v.as(gtk.Widget).addCssClass("setting");
    const line = gtk.Box.new(.horizontal, 14);
    const l = ui.label(title, "setting-label");
    l.as(gtk.Widget).setHexpand(1);
    line.append(l.as(gtk.Widget));
    control.setHalign(.end);
    control.setValign(.center);
    line.append(control);
    v.append(line.as(gtk.Widget));
    if (desc) |d| {
        const dl = ui.label(d, "setting-desc");
        dl.setWrap(1);
        dl.setWrapMode(.word_char);
        dl.setMaxWidthChars(60);
        v.append(dl.as(gtk.Widget));
    }
    return v;
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

fn onTheme(dd: *gtk.DropDown, _: *gobject.ParamSpec, p: *Panel) callconv(.c) void {
    if (p.syncing) return;
    const i = dd.getSelected();
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

fn onMin(s: *gtk.SpinButton, p: *Panel) callconv(.c) void {
    if (p.syncing) return;
    const now = settings.update(.{ .min_cols = s.getValue() }, true);
    showClamped(p, &now);
}

fn onMax(s: *gtk.SpinButton, p: *Panel) callconv(.c) void {
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

fn onDialogKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, p: *Panel) callconv(.c) c_int {
    if (keyval != gdk.KEY_Escape) return 0;
    const now = settings.current();
    p.syncing = true;
    defer p.syncing = false;
    // Setting the value it already has rewrites the field's text.
    if (hasFocus(p.min.as(gtk.Widget))) p.min.setValue(@floatFromInt(now.min_cols));
    if (hasFocus(p.max.as(gtk.Widget))) p.max.setValue(@floatFromInt(now.max_cols));
    return 0; // the dialog still closes
}

fn onOpenLog(_: *gtk.Button, _: *Panel) callconv(.c) void {
    Application.default().as(gio.ActionGroup).activateAction("show-log", null);
}

fn onDone(_: *gtk.Button, _: *Panel) callconv(.c) void {
    close();
}

fn onClosed(_: *adw.Dialog, p: *Panel) callconv(.c) void {
    flushFade();
    if (settings.on_change == onSettingsChanged) settings.on_change = null;
    panel = null;
    alloc.destroy(p);
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
    scroll: ?struct { value: f64, upper: f64, page: f64 } = null,
};

pub fn dump() Dump {
    const p = panel orelse return .{ .open = false };
    const i = p.theme.getSelected();
    const focus: ?[]const u8 = if (hasFocus(p.theme.as(gtk.Widget))) "theme" else if (hasFocus(p.fade.as(gtk.Widget))) "fade" else if (hasFocus(p.min.as(gtk.Widget))) "min_cols" else if (hasFocus(p.max.as(gtk.Widget))) "max_cols" else if (hasFocus(p.done.as(gtk.Widget))) "done" else if (hasFocus(p.open_log.as(gtk.Widget))) "open_log" else null;
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
        .scroll = if (p.scroller) |sc| blk: {
            const adj = sc.getVadjustment();
            break :blk .{ .value = adj.getValue(), .upper = adj.getUpper(), .page = adj.getPageSize() };
        } else null,
    };
}

pub const Control = enum { theme, fade, min_cols, max_cols, open_log, done };

/// Operate one control the way a user would (the widget's own signal runs
/// the same handler a click, drag step or Enter does). Number fields are
/// set as if typed and committed (Enter).
pub fn operate(which: Control, value: ?f64, theme_id: ?[]const u8) error{ NotOpen, BadValue }!void {
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
        .done => _ = p.done.as(gtk.Widget).activate(),
    }
}
