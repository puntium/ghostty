//! A key event as the shell processes it, whether it came from GTK or was
//! synthesized by the control socket.
//!
//! Real events: `EventControllerKey` → `KeyEvent.fromController` →
//! `Window` capture phase (shortcuts.zig) → `TerminalPane.handleKey`
//! (input method, then Ghostty key encoding).
//! Synthesized events (`key` / `text` control commands):
//! `KeyEvent.synthesize` → `Window.dispatchKey` → the same two steps,
//! minus the input method (it needs a real `gdk.Event`).

const std = @import("std");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../input.zig");

pub const KeyEvent = struct {
    action: input.Action,
    keyval: c_uint,
    /// Hardware keycode (evdev + 8 on Wayland/X11).
    keycode: c_uint,
    /// Modifier state as GTK reports it for this event.
    state: gdk.ModifierType,
    /// Modifiers the keymap used to produce `keyval` (e.g. shift for 'A').
    consumed: gdk.ModifierType,
    /// The keyboard layout (XKB group) of the event.
    layout: c_uint,
    is_modifier: bool,
    /// The real GDK event, or null when synthesized.
    event: ?*gdk.Event,

    /// Build from the current event of a key controller. Null if GTK has
    /// no current key event (should not happen inside the signal).
    pub fn fromController(
        ec: *gtk.EventControllerKey,
        action: input.Action,
        keyval: c_uint,
        keycode: c_uint,
        state: gdk.ModifierType,
    ) ?KeyEvent {
        const event = ec.as(gtk.EventController).getCurrentEvent() orelse return null;
        const key_event = gobject.ext.cast(gdk.KeyEvent, event) orelse return null;
        return .{
            .action = action,
            .keyval = keyval,
            .keycode = keycode,
            .state = state,
            .consumed = key_event.getConsumedModifiers(),
            .layout = key_event.getLayout(),
            .is_modifier = key_event.isModifier() != 0,
            .event = event,
        };
    }

    /// Build an event for `keyval` with modifier `state`, the way the
    /// keyboard would have produced it: the keycode comes from the
    /// display's keymap (first layout), and if the keyval sits on the
    /// shifted level, shift is added to the state and marked consumed.
    /// Keyvals with no key in the keymap get keycode 0 (text still goes
    /// through, as an input-method commit would).
    pub fn synthesize(
        display: *gdk.Display,
        action: input.Action,
        keyval: c_uint,
        state_in: gdk.ModifierType,
    ) KeyEvent {
        var state = state_in;
        var consumed: gdk.ModifierType = .{};
        var keycode: c_uint = 0;
        var layout: c_uint = 0;

        var keys: [*]gdk.KeymapKey = undefined;
        var n: c_int = 0;
        if (display.mapKeyval(keyval, &keys, &n) != 0 and n > 0) {
            defer @import("glib").free(keys);
            // Prefer group 0, lowest level.
            var best: ?gdk.KeymapKey = null;
            for (keys[0..@intCast(n)]) |k| {
                if (best) |b| {
                    if (k.f_group < b.f_group or
                        (k.f_group == b.f_group and k.f_level < b.f_level)) best = k;
                } else best = k;
            }
            if (best) |b| {
                keycode = b.f_keycode;
                layout = @intCast(b.f_group);
                if (b.f_level == 1) {
                    state.shift_mask = true;
                    consumed.shift_mask = true;
                }
            }
        }

        return .{
            .action = action,
            .keyval = keyval,
            .keycode = keycode,
            .state = state,
            .consumed = consumed,
            .layout = layout,
            .is_modifier = isModifierKeyval(keyval),
            .event = null,
        };
    }

    /// The key's physical position as a Linux evdev code (KEY_H = 35), like
    /// Electron's KeyboardEvent.code: independent of the layout and of
    /// shift. Real events: Wayland keycodes are evdev + 8. Synthesized
    /// events (control socket) stand for a US keyboard: the position of
    /// the key that produces `keyval` there. 0 when unknown.
    pub fn physicalCode(self: KeyEvent) u32 {
        if (self.event != null) return if (self.keycode >= 8) self.keycode - 8 else 0;
        return usEvdev(self.keyval) orelse 0;
    }

    /// The keyval at level 0 of this key in the event's layout: what the
    /// key is labelled, independent of shift ("bracketleft" for '{').
    /// Shortcut matching uses this for the chords Electron matches by
    /// KeyboardEvent.key (Enter, arrows, zoom); everything else goes by
    /// `physicalCode`. Synthesized events: the keyval itself, lowered.
    pub fn baseKeyval(self: KeyEvent, display: *gdk.Display) c_uint {
        if (self.keycode != 0 and self.event != null) {
            var keys: [*]gdk.KeymapKey = undefined;
            var keyvals: [*]c_uint = undefined;
            var n: c_int = 0;
            if (display.mapKeycode(self.keycode, &keys, &keyvals, &n) != 0) {
                const glib = @import("glib");
                defer glib.free(keys);
                defer glib.free(keyvals);
                for (0..@intCast(n)) |i| {
                    if (keys[i].f_group == self.layout and keys[i].f_level == 0) {
                        return gdk.keyvalToLower(keyvals[i]);
                    }
                }
            }
        }
        return gdk.keyvalToLower(self.keyval);
    }
};

/// The evdev code (linux/input-event-codes.h) of the key that produces
/// `keyval` on a US keyboard, at level 0 or 1 ('{' is on KEY_LEFTBRACE),
/// for the keys shortcuts use. Null for others.
pub fn usEvdev(keyval_in: c_uint) ?u32 {
    const kv = gdk.keyvalToLower(keyval_in);
    const rows = [_]struct { []const u8, u32 }{ .{ "qwertyuiop", 16 }, .{ "asdfghjkl", 30 }, .{ "zxcvbnm", 44 } };
    if (kv >= 'a' and kv <= 'z') {
        for (rows) |r| if (std.mem.indexOfScalar(u8, r[0], @intCast(kv))) |i| return r[1] + @as(u32, @intCast(i));
    }
    if (kv >= '1' and kv <= '9') return 2 + (kv - '1');
    return switch (kv) {
        '0', ')' => 11,
        '!' => 2,
        '@' => 3,
        '#' => 4,
        '$' => 5,
        '%' => 6,
        '^' => 7,
        '&' => 8,
        '*' => 9,
        '(' => 10,
        '-', '_' => 12,
        '=', '+' => 13,
        '[', '{' => 26,
        ']', '}' => 27,
        ';', ':' => 39,
        '\'', '"' => 40,
        '`', '~' => 41,
        '\\', '|' => 43,
        ',', '<' => 51,
        '.', '>' => 52,
        '/', '?' => 53,
        ' ' => 57,
        0xff1b => 1, // Escape
        0xff08 => 14, // BackSpace
        0xff09 => 15, // Tab
        0xff0d => 28, // Return
        0xff8d => 96, // KP_Enter
        0xff50 => 102, // Home
        0xff52 => 103, // Up
        0xff55 => 104, // Page_Up
        0xff51 => 105, // Left
        0xff53 => 106, // Right
        0xff57 => 107, // End
        0xff54 => 108, // Down
        0xff56 => 109, // Page_Down
        0xff63 => 110, // Insert
        0xffff => 111, // Delete
        else => null,
    };
}

test "usEvdev positions" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u32, 35), usEvdev('h'));
    try testing.expectEqual(@as(?u32, 35), usEvdev('H'));
    try testing.expectEqual(@as(?u32, 17), usEvdev('w'));
    try testing.expectEqual(@as(?u32, 26), usEvdev('{'));
    try testing.expectEqual(@as(?u32, 2), usEvdev('1'));
    try testing.expectEqual(@as(?u32, 11), usEvdev('0'));
    try testing.expectEqual(@as(?u32, 51), usEvdev(','));
    try testing.expectEqual(@as(?u32, 104), usEvdev(0xff55));
    try testing.expect(usEvdev(0x6c4) == null); // Cyrillic_er
}

/// GDK keyvals for modifier keys (Shift_L .. Hyper_R, ISO_Level3/5_Shift).
pub fn isModifierKeyval(keyval: c_uint) bool {
    return (keyval >= 0xffe1 and keyval <= 0xffee) or
        keyval == 0xfe03 or keyval == 0xfe11;
}

/// Parse a chord like "ctrl+shift+w", "Return", "alt+Left", "a", "plus".
/// The last component is a GDK keyval name or a single character; the
/// others are modifiers (ctrl|control, shift, alt, super).
pub fn parseChord(spec: []const u8) error{ InvalidKey, InvalidModifier }!struct {
    keyval: c_uint,
    state: gdk.ModifierType,
} {
    var state: gdk.ModifierType = .{};
    var rest = spec;
    while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        if (i == 0) break; // "+" itself, or "ctrl++"
        const m = rest[0..i];
        if (std.ascii.eqlIgnoreCase(m, "ctrl") or std.ascii.eqlIgnoreCase(m, "control")) {
            state.control_mask = true;
        } else if (std.ascii.eqlIgnoreCase(m, "shift")) {
            state.shift_mask = true;
        } else if (std.ascii.eqlIgnoreCase(m, "alt")) {
            state.alt_mask = true;
        } else if (std.ascii.eqlIgnoreCase(m, "super")) {
            state.super_mask = true;
        } else return error.InvalidModifier;
        rest = rest[i + 1 ..];
    }
    if (rest.len == 0) return error.InvalidKey;
    return .{ .keyval = try keyvalFromName(rest), .state = state };
}

/// A keyval from a GDK name ("Return") or a single UTF-8 character ("é").
pub fn keyvalFromName(name: []const u8) error{InvalidKey}!c_uint {
    const void_symbol: c_uint = 0xffffff;
    var buf: [64]u8 = undefined;
    if (name.len < buf.len) {
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const kv = gdk.keyvalFromName(buf[0..name.len :0]);
        if (kv != 0 and kv != void_symbol) return kv;
    }
    const cp = std.unicode.utf8Decode(name) catch return error.InvalidKey;
    const kv = gdk.unicodeToKeyval(cp);
    if (kv == 0 or kv == void_symbol) return error.InvalidKey;
    return kv;
}

test "parseChord" {
    const testing = std.testing;
    const a = try parseChord("ctrl+shift+w");
    try testing.expect(a.state.control_mask and a.state.shift_mask and !a.state.alt_mask);
    try testing.expectEqual(@as(c_uint, 'w'), a.keyval);
    const b = try parseChord("Return");
    try testing.expectEqual(@as(c_uint, 0xff0d), b.keyval);
    const c = try parseChord("ctrl++");
    try testing.expectEqual(@as(c_uint, '+'), c.keyval);
    try testing.expectError(error.InvalidModifier, parseChord("hyper+a"));
}
