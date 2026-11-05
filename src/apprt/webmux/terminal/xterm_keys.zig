//! xterm.js 5.5's key encoding, for when the application has not enabled
//! the Kitty keyboard protocol (ruling for the fix round: "the terminal
//! sends what xterm.js 5.5 sends").
//!
//! `evaluate` is a line-by-line port of
//! electron/node_modules/@xterm/xterm/src/common/input/Keyboard.ts
//! (`evaluateKeyboardEvent`, Linux: isMac = false), plus the parts of
//! browser/Terminal.ts `_keyDown` / `_keyPress` that decide what is sent:
//! PAGE_UP/PAGE_DOWN scroll instead of sending, and a key keydown leaves
//! alone is sent by keypress as its character unless Ctrl, Alt or Meta is
//! held. `fromGdk` turns a GDK key event into the DOM fields the port
//! reads (keyCode, key, modifiers) the way Chromium does on Linux.
//!
//! webmux-dev/xterm-keys checks the native pane against xterm's own code
//! for every key and modifier combination.
const std = @import("std");
const gdk = @import("gdk");
const input = @import("../../../input.zig");

pub const Event = struct {
    /// DOM `keyCode` (Chromium on Linux, US-layout values).
    key_code: u16,
    /// DOM `key` when it is a single character (UTF-8), else empty.
    key: []const u8 = "",
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
};

pub const Result = union(enum) {
    /// Send these bytes.
    send: []const u8,
    /// Send nothing.
    none,
    /// Shift+PageUp / Shift+PageDown: scroll the viewport by rows - 1.
    page_up,
    page_down,
};

const ESC = "\x1b";

/// What xterm.js sends for `ev`. `buf` backs the returned slice.
pub fn evaluate(ev: Event, app_cursor: bool, buf: *[32]u8) Result {
    const r = keyDown(ev, app_cursor, buf);
    switch (r) {
        .page_up, .page_down, .send => return r,
        .none => {},
    }
    // keypress: a character, unless Ctrl/Alt/Meta is held.
    if (!ev.ctrl and !ev.alt and !ev.meta and ev.key.len > 0) {
        if (isSingleChar(ev.key)) return .{ .send = ev.key };
    }
    return .none;
}

fn isSingleChar(s: []const u8) bool {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return false;
    return n == s.len;
}

fn print(buf: *[32]u8, comptime fmt: []const u8, args: anytype) Result {
    return .{ .send = std.fmt.bufPrint(buf, fmt, args) catch unreachable };
}

fn keyDown(ev: Event, app_cursor: bool, buf: *[32]u8) Result {
    const modifiers: u8 = @as(u8, @intFromBool(ev.shift)) |
        (@as(u8, @intFromBool(ev.alt)) << 1) |
        (@as(u8, @intFromBool(ev.ctrl)) << 2) |
        (@as(u8, @intFromBool(ev.meta)) << 3);
    const m1 = modifiers + 1;
    switch (ev.key_code) {
        8 => { // backspace
            const k: []const u8 = if (ev.ctrl) "\x08" else "\x7f";
            if (ev.alt) return print(buf, ESC ++ "{s}", .{k});
            return .{ .send = k };
        },
        9 => { // tab
            if (ev.shift) return .{ .send = ESC ++ "[Z" };
            return .{ .send = "\t" };
        },
        13 => return .{ .send = if (ev.alt) ESC ++ "\r" else "\r" },
        27 => return .{ .send = if (ev.alt) ESC ++ ESC else ESC },
        37, 39, 38, 40 => {
            if (ev.meta) return .none;
            const letter: u8 = switch (ev.key_code) {
                37 => 'D',
                39 => 'C',
                38 => 'A',
                else => 'B',
            };
            if (modifiers != 0) {
                // Alt+arrow behaves like Ctrl+arrow on Linux.
                const m: u8 = if (modifiers == 2) 5 else m1;
                return print(buf, ESC ++ "[1;{d}{c}", .{ m, letter });
            }
            if (app_cursor) return print(buf, ESC ++ "O{c}", .{letter});
            return print(buf, ESC ++ "[{c}", .{letter});
        },
        45 => { // insert
            if (!ev.shift and !ev.ctrl) return .{ .send = ESC ++ "[2~" };
            return .none;
        },
        46 => { // delete
            if (modifiers != 0) return print(buf, ESC ++ "[3;{d}~", .{m1});
            return .{ .send = ESC ++ "[3~" };
        },
        36, 35 => { // home, end
            const letter: u8 = if (ev.key_code == 36) 'H' else 'F';
            if (modifiers != 0) return print(buf, ESC ++ "[1;{d}{c}", .{ m1, letter });
            if (app_cursor) return print(buf, ESC ++ "O{c}", .{letter});
            return print(buf, ESC ++ "[{c}", .{letter});
        },
        33, 34 => { // page up, page down
            const n: u8 = if (ev.key_code == 33) 5 else 6;
            if (ev.shift) return if (ev.key_code == 33) .page_up else .page_down;
            if (ev.ctrl) return print(buf, ESC ++ "[{d};{d}~", .{ n, m1 });
            return print(buf, ESC ++ "[{d}~", .{n});
        },
        112, 113, 114, 115 => { // F1-F4
            const letter: u8 = "PQRS"[ev.key_code - 112];
            if (modifiers != 0) return print(buf, ESC ++ "[1;{d}{c}", .{ m1, letter });
            return print(buf, ESC ++ "O{c}", .{letter});
        },
        116...123 => { // F5-F12
            const codes = [_]u8{ 15, 17, 18, 19, 20, 21, 23, 24 };
            const c = codes[ev.key_code - 116];
            if (modifiers != 0) return print(buf, ESC ++ "[{d};{d}~", .{ c, m1 });
            return print(buf, ESC ++ "[{d}~", .{c});
        },
        else => return keyDownDefault(ev, buf),
    }
}

fn keyDownDefault(ev: Event, buf: *[32]u8) Result {
    const kc = ev.key_code;
    if (ev.ctrl and !ev.shift and !ev.alt and !ev.meta) {
        if (kc >= 65 and kc <= 90) return print(buf, "{c}", .{@as(u8, @intCast(kc - 64))});
        if (kc == 32) return .{ .send = "\x00" };
        if (kc >= 51 and kc <= 55) return print(buf, "{c}", .{@as(u8, @intCast(kc - 51 + 27))});
        if (kc == 56) return .{ .send = "\x7f" };
        if (kc == 219) return .{ .send = ESC };
        if (kc == 220) return .{ .send = "\x1c" };
        if (kc == 221) return .{ .send = "\x1d" };
        return .none;
    }
    if (ev.alt and !ev.meta) {
        if (keyMapping(kc)) |pair| {
            return print(buf, ESC ++ "{c}", .{if (ev.shift) pair[1] else pair[0]});
        }
        if (kc >= 65 and kc <= 90) {
            var c: u8 = if (ev.ctrl) @intCast(kc - 64) else @intCast(kc + 32);
            if (ev.shift) c = std.ascii.toUpper(c);
            return print(buf, ESC ++ "{c}", .{c});
        }
        if (kc == 32) return .{ .send = if (ev.ctrl) ESC ++ "\x00" else ESC ++ " " };
        // ev.key === 'Dead': the input method handles dead keys here.
        return .none;
    }
    if (ev.key.len > 0 and !ev.ctrl and !ev.alt and !ev.meta and kc >= 48 and isSingleChar(ev.key)) {
        return .{ .send = ev.key };
    }
    if (ev.key.len > 0 and ev.ctrl) {
        if (std.mem.eql(u8, ev.key, "_")) return .{ .send = "\x1f" };
        if (std.mem.eql(u8, ev.key, "@")) return .{ .send = "\x00" };
    }
    return .none;
}

/// KEYCODE_KEY_MAPPINGS: digits and US punctuation, unshifted/shifted.
fn keyMapping(kc: u16) ?[2]u8 {
    if (kc >= 48 and kc <= 57) return .{ @intCast(kc), ")!@#$%^&*("[kc - 48] };
    return switch (kc) {
        186 => .{ ';', ':' },
        187 => .{ '=', '+' },
        188 => .{ ',', '<' },
        189 => .{ '-', '_' },
        190 => .{ '.', '>' },
        191 => .{ '/', '?' },
        192 => .{ '`', '~' },
        219 => .{ '[', '{' },
        220 => .{ '\\', '|' },
        221 => .{ ']', '}' },
        222 => .{ '\'', '"' },
        else => null,
    };
}

//---------------------------------------------------------------
// GDK → DOM

/// Chromium's Linux keyCode for a key: from the keysym for keys with a
/// fixed code, from the layout's level-0 keysym for Latin letters, digits
/// and punctuation, and from the physical key otherwise (a non-Latin
/// layout's letter gets the US letter's code, as Chromium does).
pub fn keyCode(keyval: c_uint, base: c_uint, physical: input.Key) u16 {
    // The level-0 keysym too: Ctrl+Alt+F1 is XF86Switch_VT_1 on level 2
    // of the F1 key, still keyCode 112 in Chromium.
    if (specialCode(keyval) orelse specialCode(base)) |c| return c;
    if (asciiCode(base)) |c| return c;
    return physicalCode(physical);
}

fn specialCode(keyval: c_uint) ?u16 {
    switch (keyval) {
        0xff08 => return 8, // BackSpace
        0xff09, 0xfe20 => return 9, // Tab, ISO_Left_Tab
        0xff0d, 0xff8d => return 13, // Return, KP_Enter
        0xff1b => return 27, // Escape
        0xff50, 0xff95 => return 36, // Home, KP_Home
        0xff51, 0xff96 => return 37, // Left
        0xff52, 0xff97 => return 38, // Up
        0xff53, 0xff98 => return 39, // Right
        0xff54, 0xff99 => return 40, // Down
        0xff55, 0xff9a => return 33, // Prior
        0xff56, 0xff9b => return 34, // Next
        0xff57, 0xff9c => return 35, // End
        0xff63, 0xff9e => return 45, // Insert
        0xffff, 0xff9f => return 46, // Delete
        0xffbe...0xffc9 => return @intCast(112 + (keyval - 0xffbe)), // F1-F12
        0xffb0...0xffb9 => return @intCast(96 + (keyval - 0xffb0)), // KP_0-9
        0xffaa => return 106, // KP_Multiply
        0xffab => return 107, // KP_Add
        0xffad => return 109, // KP_Subtract
        0xffae => return 110, // KP_Decimal
        0xffaf => return 111, // KP_Divide
        0x20, 0xff80 => return 32, // space, KP_Space
        else => return null,
    }
}

fn asciiCode(base: c_uint) ?u16 {
    return switch (base) {
        'a'...'z' => @intCast(base - 32),
        '0'...'9' => @intCast(base),
        ';' => 186,
        '=' => 187,
        ',' => 188,
        '-' => 189,
        '.' => 190,
        '/' => 191,
        '`' => 192,
        '[' => 219,
        '\\' => 220,
        ']' => 221,
        '\'' => 222,
        else => null,
    };
}

fn physicalCode(k: input.Key) u16 {
    return switch (k) {
        .key_a => 65, .key_b => 66, .key_c => 67, .key_d => 68, .key_e => 69,
        .key_f => 70, .key_g => 71, .key_h => 72, .key_i => 73, .key_j => 74,
        .key_k => 75, .key_l => 76, .key_m => 77, .key_n => 78, .key_o => 79,
        .key_p => 80, .key_q => 81, .key_r => 82, .key_s => 83, .key_t => 84,
        .key_u => 85, .key_v => 86, .key_w => 87, .key_x => 88, .key_y => 89,
        .key_z => 90,
        .digit_0 => 48, .digit_1 => 49, .digit_2 => 50, .digit_3 => 51, .digit_4 => 52,
        .digit_5 => 53, .digit_6 => 54, .digit_7 => 55, .digit_8 => 56, .digit_9 => 57,
        .semicolon => 186, .equal => 187, .comma => 188, .minus => 189, .period => 190,
        .slash => 191, .backquote => 192, .bracket_left => 219, .backslash => 220,
        .bracket_right => 221, .quote => 222,
        else => 0,
    };
}

test "evaluate: xterm.js cases" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    const Case = struct { ev: Event, app: bool = false, want: []const u8 };
    const cases = [_]Case{
        .{ .ev = .{ .key_code = 13, .shift = true }, .want = "\r" },
        .{ .ev = .{ .key_code = 13, .ctrl = true }, .want = "\r" },
        .{ .ev = .{ .key_code = 13, .alt = true }, .want = "\x1b\r" },
        .{ .ev = .{ .key_code = 9, .ctrl = true }, .want = "\t" },
        .{ .ev = .{ .key_code = 9, .ctrl = true, .shift = true }, .want = "\x1b[Z" },
        .{ .ev = .{ .key_code = 27, .ctrl = true }, .want = "\x1b" },
        .{ .ev = .{ .key_code = 37, .alt = true }, .want = "\x1b[1;5D" },
        .{ .ev = .{ .key_code = 39, .shift = true, .alt = true }, .want = "\x1b[1;4C" },
        .{ .ev = .{ .key_code = 38 }, .app = true, .want = "\x1bOA" },
        .{ .ev = .{ .key_code = 8, .ctrl = true, .alt = true }, .want = "\x1b\x08" },
        .{ .ev = .{ .key_code = 116, .shift = true }, .want = "\x1b[15;2~" },
        .{ .ev = .{ .key_code = 33, .ctrl = true, .alt = true }, .want = "\x1b[5;7~" },
        .{ .ev = .{ .key_code = 33, .alt = true }, .want = "\x1b[5~" },
        .{ .ev = .{ .key_code = 65, .ctrl = true, .key = "a" }, .want = "\x01" },
        .{ .ev = .{ .key_code = 65, .ctrl = true, .shift = true, .key = "A" }, .want = "" },
        .{ .ev = .{ .key_code = 65, .ctrl = true, .alt = true, .shift = true, .key = "A" }, .want = "\x1b\x01" },
        .{ .ev = .{ .key_code = 219, .ctrl = true, .alt = true, .shift = true, .key = "{" }, .want = "\x1b{" },
        .{ .ev = .{ .key_code = 49, .alt = true, .shift = true, .key = "!" }, .want = "\x1b!" },
        .{ .ev = .{ .key_code = 50, .ctrl = true, .shift = true, .key = "@" }, .want = "\x00" },
        .{ .ev = .{ .key_code = 189, .ctrl = true, .shift = true, .key = "_" }, .want = "\x1f" },
        .{ .ev = .{ .key_code = 49, .ctrl = true, .shift = true, .key = "!" }, .want = "" },
        .{ .ev = .{ .key_code = 32, .key = " " }, .want = " " },
        .{ .ev = .{ .key_code = 32, .alt = true, .key = " " }, .want = "\x1b " },
        .{ .ev = .{ .key_code = 97, .key = "1" }, .want = "1" },
        .{ .ev = .{ .key_code = 0, .key = "é" }, .want = "é" },
    };
    for (cases) |c| {
        const r = evaluate(c.ev, c.app, &buf);
        const got: []const u8 = switch (r) {
            .send => |s| s,
            else => "",
        };
        try t.expectEqualSlices(u8, c.want, got);
    }
    try t.expect(evaluate(.{ .key_code = 33, .shift = true }, false, &buf) == .page_up);
    try t.expect(evaluate(.{ .key_code = 45, .shift = true }, false, &buf) == .none);
}

comptime {
    _ = gdk;
}
