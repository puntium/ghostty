//! The shell's keyboard shortcuts.
//!
//! webmux-gtk owns every chord (Ghostty's own keybindings are cleared in
//! config.zig, except the few terminal-level ones listed there). A
//! shortcut maps a chord to a GAction name; the window's key controller
//! runs in the capture phase, before the focused pane sees the key, and
//! activates the action on the focused widget, so the action can live on
//! the application (`app.`), the window (`win.`), or any widget group on
//! the way up from the focus (e.g. a pane's `pane.` group).
//!
//! To add one: add the action where it belongs (see WEBMUX.md ›
//! Actions and shortcuts), then a line to `table`. Chords use GTK
//! accelerator syntax with the key as it is labelled on a US keyboard,
//! unshifted (Ctrl+Shift+[ is "<Control><Shift>bracketleft").
//!
//! Matching (K-16, as the Electron client, chord by chord):
//!   .code  the key's physical position (Electron `KeyboardEvent.code`):
//!          the accelerator's key names the US position, and any layout
//!          matches that position (Ctrl+Shift+H is the key right of G on
//!          Russian, German, French… keyboards alike). Every app shortcut
//!          (main.js APP_SHORTCUTS: KeyO, KeyR, KeyG, Comma, PageUp,
//!          PageDown, Digit1…9) and the pane chords W F B H J K L [ ]
//!          (app.js paneCommandForKey).
//!   .key   the key's meaning in the active layout (`KeyboardEvent.key`):
//!          Enter (also keypad Enter) and the arrows (also keypad arrows)
//!          in app.js; and zoom (Electron menu-role accelerators), matched
//!          by the level-0 keyval of the active layout.
//! Modifiers must match exactly (Ctrl, Shift, Alt, Super; lock keys are
//! ignored).
//!
//! Modals (K-18, deviation 31): pane chords never run while focus is in a
//! text field or a dialog, or while any modal is up in the window (a mapped
//! widget with the CSS class `modal_class`); they are swallowed so the key
//! never reaches the field or the pane underneath. App shortcuts run
//! everywhere. The Linux chord modifier is Ctrl+Shift (electron/main.js
//! `MOD`).

const std = @import("std");
const gdk = @import("gdk");
const gtk = @import("gtk");
const gobject = @import("gobject");
const adw = @import("adw");

const usEvdev = @import("key_event.zig").usEvdev;

const log = std.log.scoped(.webmux_shortcuts);

pub const By = enum { code, key };

pub const Entry = struct {
    /// GTK accelerator syntax, e.g. "<Control><Shift>w".
    accel: [:0]const u8,
    /// Detailed action name, e.g. "pane.close-pane".
    action: [:0]const u8,
    /// Physical position (default) or the layout's key (see the header).
    by: By = .code,
};

/// The CSS class that marks a modal inside the window (an in-pane
/// confirmation, an overlay sheet): while a widget carrying it is mapped,
/// pane chords do not run. Any area may use it on the modal's root widget.
pub const modal_class = "wm-modal";

pub const table = [_]Entry{
    // --- App shortcuts (PARITY K-20…K-26, main.js APP_SHORTCUTS) ---------
    // Intercepted ahead of every view. None may be a pane chord (K-27).
    .{ .accel = "<Control><Shift>o", .action = "app.show-connections" },
    .{ .accel = "<Control><Shift>r", .action = "app.reconnect" },
    .{ .accel = "<Control><Shift>g", .action = "app.show-log" },
    .{ .accel = "<Control>comma", .action = "app.show-settings" },
    .{ .accel = "<Control>Page_Up", .action = "app.host-prev" },
    .{ .accel = "<Control>Page_Down", .action = "app.host-next" },
    .{ .accel = "<Control>1", .action = "app.host-1" },
    .{ .accel = "<Control>2", .action = "app.host-2" },
    .{ .accel = "<Control>3", .action = "app.host-3" },
    .{ .accel = "<Control>4", .action = "app.host-4" },
    .{ .accel = "<Control>5", .action = "app.host-5" },
    .{ .accel = "<Control>6", .action = "app.host-6" },
    .{ .accel = "<Control>7", .action = "app.host-7" },
    .{ .accel = "<Control>8", .action = "app.host-8" },
    .{ .accel = "<Control>9", .action = "app.host-9" },
    // View › zoom (K-31).
    .{ .accel = "<Control>0", .action = "app.zoom-reset", .by = .key },
    .{ .accel = "<Control>equal", .action = "app.zoom-in", .by = .key },
    .{ .accel = "<Control><Shift>equal", .action = "app.zoom-in", .by = .key },
    .{ .accel = "<Control>minus", .action = "app.zoom-out", .by = .key },
    // Where + has a key of its own (German and others: Ctrl++ is what a
    // user presses; Electron's zoomIn is Ctrl+Plus), and the keypad. Not
    // with Shift: on German that is the physical ] key, Ctrl+Shift+] is a
    // pane chord (consume-expel-right).
    .{ .accel = "<Control>plus", .action = "app.zoom-in", .by = .key },
    .{ .accel = "<Control>KP_Add", .action = "app.zoom-in", .by = .key },
    .{ .accel = "<Control>KP_Subtract", .action = "app.zoom-out", .by = .key },

    // Pane chords (PARITY K-01…K-15; electron/ui/app.js paneCommandForKey,
    // Linux: Ctrl+Shift, Alt as the secondary modifier), on the workspace's
    // `pane.` group.
    .{ .accel = "<Control><Shift>Return", .action = "pane.new-terminal", .by = .key },
    .{ .accel = "<Control><Shift><Alt>Return", .action = "pane.new-terminal-below", .by = .key },
    .{ .accel = "<Control><Shift>b", .action = "pane.new-files" },
    .{ .accel = "<Control><Shift>w", .action = "pane.close-pane" },
    .{ .accel = "<Control><Shift>f", .action = "pane.toggle-full" },
    .{ .accel = "<Control><Shift>Left", .action = "pane.focus-left", .by = .key },
    .{ .accel = "<Control><Shift>h", .action = "pane.focus-left" },
    .{ .accel = "<Control><Shift>Right", .action = "pane.focus-right", .by = .key },
    .{ .accel = "<Control><Shift>l", .action = "pane.focus-right" },
    .{ .accel = "<Control><Shift>Up", .action = "pane.focus-up", .by = .key },
    .{ .accel = "<Control><Shift>k", .action = "pane.focus-up" },
    .{ .accel = "<Control><Shift>Down", .action = "pane.focus-down", .by = .key },
    .{ .accel = "<Control><Shift>j", .action = "pane.focus-down" },
    .{ .accel = "<Control><Shift>bracketleft", .action = "pane.consume-expel-left" },
    .{ .accel = "<Control><Shift>bracketright", .action = "pane.consume-expel-right" },
    .{ .accel = "<Control><Shift><Alt>Left", .action = "pane.move-column-left", .by = .key },
    .{ .accel = "<Control><Shift><Alt>h", .action = "pane.move-column-left" },
    .{ .accel = "<Control><Shift><Alt>Right", .action = "pane.move-column-right", .by = .key },
    .{ .accel = "<Control><Shift><Alt>l", .action = "pane.move-column-right" },
    .{ .accel = "<Control><Shift><Alt>Up", .action = "pane.move-pane-up", .by = .key },
    .{ .accel = "<Control><Shift><Alt>k", .action = "pane.move-pane-up" },
    .{ .accel = "<Control><Shift><Alt>Down", .action = "pane.move-pane-down", .by = .key },
    .{ .accel = "<Control><Shift><Alt>j", .action = "pane.move-pane-down" },
};

/// The modifiers shortcuts care about.
pub const Mods = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn fromGdk(state: gdk.ModifierType) Mods {
        return .{
            .ctrl = state.control_mask,
            .shift = state.shift_mask,
            .alt = state.alt_mask,
            .super = state.super_mask,
        };
    }
};

pub const Chord = struct {
    /// The level-0 keyval of the key in the active layout, lowercased
    /// (`KeyEvent.baseKeyval`): for `.key` entries.
    keyval: c_uint,
    mods: Mods,
    /// The physical position, an evdev code (`KeyEvent.physicalCode`): for
    /// `.code` entries. 0: unknown, then the US position of `keyval`.
    code: u32 = 0,

    pub fn eql(a: Chord, b: Chord) bool {
        return a.keyval == b.keyval and a.mods == b.mods;
    }
};

const Parsed = struct { chord: Chord, action: [:0]const u8, by: By };

/// Keypad Enter and keypad arrows are the same `KeyboardEvent.key`.
fn keyKeyval(kv: c_uint) c_uint {
    return switch (kv) {
        0xff8d => 0xff0d, // KP_Enter → Return
        0xff96 => 0xff51, // KP_Left
        0xff97 => 0xff52, // KP_Up
        0xff98 => 0xff53, // KP_Right
        0xff99 => 0xff54, // KP_Down
        else => kv,
    };
}
var parsed: ?[table.len]Parsed = null;

fn parsedTable() []const Parsed {
    if (parsed == null) {
        var out: [table.len]Parsed = undefined;
        for (table, 0..) |entry, i| {
            var key: c_uint = 0;
            var mods: gdk.ModifierType = .{};
            if (gtk.acceleratorParse(entry.accel, &key, &mods) == 0 or key == 0) {
                std.debug.panic("invalid accelerator in shortcuts.table: {s}", .{entry.accel});
            }
            const kv = gdk.keyvalToLower(key);
            const code: u32 = if (entry.by == .code)
                usEvdev(kv) orelse std.debug.panic("shortcuts.table: no US position for {s}", .{entry.accel})
            else
                0;
            out[i] = .{
                .chord = .{ .keyval = kv, .mods = .fromGdk(mods), .code = code },
                .action = entry.action,
                .by = entry.by,
            };
        }
        parsed = out;
    }
    return &parsed.?;
}

/// The action bound to `chord`, if any (see the header for how each
/// entry matches).
pub fn lookup(chord: Chord) ?[:0]const u8 {
    const code = if (chord.code != 0) chord.code else usEvdev(chord.keyval) orelse 0;
    const kv = keyKeyval(gdk.keyvalToLower(chord.keyval));
    for (parsedTable()) |p| {
        if (p.chord.mods != chord.mods) continue;
        const hit = switch (p.by) {
            .code => code != 0 and p.chord.code == code,
            .key => p.chord.keyval == kv,
        };
        if (hit) return p.action;
    }
    return null;
}

/// Look the chord up and, if bound, activate the action on `widget`
/// (which resolves `app.`/`win.`/widget groups from there upwards).
/// Returns true if a shortcut matched; the key is then consumed even if
/// the action is disabled.
///
/// Pane chords (actions in the `pane.` group) do not run while the focus
/// is in a text field (K-18): they are swallowed, so the field never sees
/// the chord as text. App shortcuts run from anywhere.
pub fn dispatch(widget: *gtk.Widget, chord: Chord) bool {
    const action = lookup(chord) orelse return false;
    if (std.mem.startsWith(u8, action, "pane.")) {
        const why: ?[]const u8 = if (inTextField(widget))
            "in a text field"
        else if (modalUp(widget))
            "under a modal"
        else
            null;
        if (why) |w| {
            log.debug("shortcut {s} swallowed {s}", .{ action, w });
            last_action = action;
            return true;
        }
    }
    log.debug("shortcut {s}", .{action});
    if (widget.activateAction(action.ptr, null) == 0) {
        log.warn("shortcut action {s} not found from the focused widget", .{action});
    }
    last_action = action;
    return true;
}

/// Focus in a text field, or in a dialog over the window (K-18).
fn inTextField(widget: *gtk.Widget) bool {
    var w: ?*gtk.Widget = widget;
    while (w) |x| : (w = x.getParent()) {
        if (gobject.ext.isA(x, gtk.Text) or gobject.ext.isA(x, gtk.TextView)) return true;
        if (gobject.ext.isA(x, adw.Dialog)) return true;
    }
    return false;
}

/// A modal is up in `widget`'s window: a mapped widget carrying
/// `modal_class`. Hidden hosts' views are unmapped, so their modals do not
/// count (each Electron host page blocks only its own chords).
pub fn modalUp(widget: *gtk.Widget) bool {
    const root = widget.getRoot() orelse return false;
    return hasModal(root.as(gtk.Widget));
}

fn hasModal(w: *gtk.Widget) bool {
    if (w.getMapped() == 0) return false;
    if (w.hasCssClass(modal_class) != 0) return true;
    var c = w.getFirstChild();
    while (c) |x| : (c = x.getNextSibling()) if (hasModal(x)) return true;
    return false;
}

/// The most recently dispatched shortcut action (for the control socket).
pub var last_action: ?[:0]const u8 = null;

test "table parses" {
    // gtk_accelerator_parse needs no display.
    const chord: Chord = .{ .keyval = 'w', .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expectEqualStrings("pane.close-pane", lookup(chord).?);
    try std.testing.expect(lookup(.{ .keyval = 'w', .mods = .{ .ctrl = true } }) == null);
    try std.testing.expectEqualStrings("app.reconnect", lookup(.{ .keyval = 'r', .mods = .{ .ctrl = true, .shift = true } }).?);
    try std.testing.expect(lookup(.{ .keyval = 'r', .mods = .{ .ctrl = true } }) == null);
}

test "physical positions: any layout's keyval at the H position is focus-left" {
    const cs: Mods = .{ .ctrl = true, .shift = true };
    // Russian: the H key gives Cyrillic_er; German: '[' is on ü, AZERTY: '1' is '&'.
    try std.testing.expectEqualStrings("pane.focus-left", lookup(.{ .keyval = 0x6d2, .code = 35, .mods = cs }).?);
    try std.testing.expectEqualStrings("pane.consume-expel-left", lookup(.{ .keyval = 0xfc, .code = 26, .mods = cs }).?);
    try std.testing.expectEqualStrings("app.host-1", lookup(.{ .keyval = '&', .code = 2, .mods = .{ .ctrl = true } }).?);
    // German: the key labelled H on any layout is not what matters: the
    // position of Z (QWERTZ's Y) is Ctrl+Shift+Z, unbound.
    try std.testing.expect(lookup(.{ .keyval = 'y', .code = 44, .mods = cs }) == null);
    // By key: keypad Enter and arrows count; Enter matches wherever it is.
    try std.testing.expectEqualStrings("pane.new-terminal", lookup(.{ .keyval = 0xff8d, .code = 96, .mods = cs }).?);
    try std.testing.expectEqualStrings("pane.focus-left", lookup(.{ .keyval = 0xff96, .code = 75, .mods = cs }).?);
    // Alt is the secondary modifier; Super never matches.
    try std.testing.expectEqualStrings("pane.move-column-left", lookup(.{ .keyval = 'h', .code = 35, .mods = .{ .ctrl = true, .shift = true, .alt = true } }).?);
    try std.testing.expect(lookup(.{ .keyval = 'h', .code = 35, .mods = .{ .ctrl = true, .shift = true, .super = true } }) == null);
}
