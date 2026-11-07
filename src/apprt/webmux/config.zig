//! The Ghostty configuration webmux-gtk runs with.
//!
//! webmux-gtk never reads `~/.config/ghostty` (or any other Ghostty config
//! file, or Ghostty CLI flags): the configuration is built here, in code,
//! from Ghostty's defaults plus the lines below, which reproduce the
//! Electron client's xterm.js setup:
//!
//!   electron/ui/app.js      `new Terminal({cursorBlink: true, fontSize: 13,
//!                           scrollback: 5000, fontFamily: TERM_FONT})`
//!   electron/ui/settings.js THEMES.dark / THEMES.light (`xterm` palettes)
//!   electron/ui/index.html  `.term-holder { padding: 4px }`, JetBrainsMono
//!                           Nerd Font (woff2, bundled)
//!
//! Font: the Electron client bundles "JetBrainsMono Nerd Font". Ghostty's
//! built-in default font is JetBrains Mono with the Nerd Font symbols as a
//! fallback, i.e. the same glyphs, embedded in the binary, so we leave
//! `font-family` unset rather than depend on what fontconfig finds.
//!
//! Size: xterm.js sizes in CSS px, Ghostty in points at 96 dpi on Linux:
//! 13 px = 13 * 72 / 96 = 9.75 pt.
//!
//! Keybindings: Ghostty's are all cleared (`keybind = clear`). The shell
//! owns every chord (shortcuts.zig), and the terminal pane implements its
//! own keys (copy, the paste variants, terminal/keys.zig) because they
//! need the Electron client's logic, not Ghostty's.
//!
//! Mouse: right click does nothing (no context menu, no word selection,
//! PARITY T-23); selection is copied to PRIMARY by the pane itself (not
//! Ghostty's copy-on-select, so every clipboard write the core makes is an
//! OSC 52 write, C-01); word boundaries are xterm's (T-18); URLs highlight
//! on hover without a modifier (T-24, set in `build`).
//!
//! Selection colours: xterm.js draws a translucent overlay; Ghostty needs an
//! opaque colour, so these are the overlay blended onto the background.

const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../../config.zig");
const cli = @import("../../cli.zig");
const CoreConfig = configpkg.Config;
const config_webmux = @import("../../config/webmux.zig");

/// The terminal colour scheme (Electron: settings.theme).
pub const Scheme = enum {
    dark,
    light,

    pub fn fromString(s: []const u8) ?Scheme {
        return std.meta.stringToEnum(Scheme, s);
    }
};

/// Bindings handed to the Ghostty core: none (see the top comment).
pub const terminal_keybinds = "";

const common =
    \\font-size = 9.75
    \\# xterm.js's WebGL renderer floors the cell width (7.8 px → 7 px at
    \\# 13 px, measured in headless Chrome with the Electron client's font);
    \\# Ghostty rounds (→ 8). One pixel narrower matches at this size.
    \\adjust-cell-width = -1
    \\cursor-style = block
    \\cursor-style-blink = true
    \\# Ghostty trims whole pages, so ask for more than the 5000 lines xterm
    \\# keeps to never keep fewer (T-03).
    \\scrollback-limit-lines = 5600
    \\bold-color = bright
    \\# Padding is in points: 3 pt = 4 px at 96 dpi (T-09).
    \\window-padding-x = 3
    \\window-padding-y = 3
    \\window-padding-balance = false
    \\window-padding-color = background
    \\
    \\# The pane is a plain terminal; nothing Ghostty-specific leaks into it.
    \\shell-integration = none
    \\# $HOME, not the passwd home Ghostty's default uses (the headless
    \\# recipe points HOME at a throwaway directory).
    \\working-directory = ~/
    \\confirm-close-surface = false
    \\quit-after-last-window-closed = true
    \\gtk-single-instance = false
    \\
    \\# Clipboard as in the Electron client: OSC 52 writes land on the
    \\# clipboard, OSC 52 reads are ignored, pastes are not second-guessed
    \\# (there is no confirmation dialog in this shell), no copy-on-select.
    \\clipboard-write = allow
    \\clipboard-read = deny
    \\clipboard-paste-protection = false
    \\copy-on-select = none
    \\right-click-action = ignore
    \\# xterm.js word separators: space and ()[]{}',"` (PARITY T-18).
    \\selection-word-chars = " ()[]{}',\"`"
    \\
    \\keybind = clear
    \\
;

/// THEMES.dark: xterm.js's stock palette on the panel colour.
const dark =
    \\background = #1f1f2b
    \\foreground = #ffffff
    \\cursor-color = #ffffff
    \\cursor-text = #000000
    \\selection-background = #62626b
    \\selection-foreground = cell-foreground
    \\palette = 0=#2e3436
    \\palette = 1=#cc0000
    \\palette = 2=#4e9a06
    \\palette = 3=#c4a000
    \\palette = 4=#3465a4
    \\palette = 5=#75507b
    \\palette = 6=#06989a
    \\palette = 7=#d3d7cf
    \\palette = 8=#555753
    \\palette = 9=#ef2929
    \\palette = 10=#8ae234
    \\palette = 11=#fce94f
    \\palette = 12=#729fcf
    \\palette = 13=#ad7fa8
    \\palette = 14=#34e2e2
    \\palette = 15=#eeeeec
    \\
;

/// THEMES.light.
const light =
    \\background = #f4f5f9
    \\foreground = #343b58
    \\cursor-color = #343b58
    \\cursor-text = #f4f5f9
    \\selection-background = #c2d7f5
    \\selection-foreground = cell-foreground
    \\palette = 0=#3b3e4d
    \\palette = 1=#c8283f
    \\palette = 2=#587539
    \\palette = 3=#8c6c3e
    \\palette = 4=#2e7de9
    \\palette = 5=#9854f1
    \\palette = 6=#007197
    \\palette = 7=#7d84a3
    \\palette = 8=#6a6f87
    \\palette = 9=#f52a65
    \\palette = 10=#4d8a2f
    \\palette = 11=#a5772a
    \\palette = 12=#1c5fc4
    \\palette = 13=#7c3de0
    \\palette = 14=#0a8fb5
    \\palette = 15=#343b58
    \\
;

/// The config text for a scheme, in Ghostty's config-file syntax.
pub fn text(scheme: Scheme) []const u8 {
    return switch (scheme) {
        .dark => common ++ terminal_keybinds ++ dark,
        .light => common ++ terminal_keybinds ++ light,
    };
}

/// xterm.js web-links addon's URL regex (config/webmux.zig, shared with
/// the native macOS client).
pub const url_regex = config_webmux.url_regex;

/// Build the finalized Ghostty configuration. Caller owns the result
/// (`deinit`). Parse problems end up in `_diagnostics` and are logged by
/// the caller; they are bugs in this file.
pub fn build(alloc: Allocator, scheme: Scheme) !CoreConfig {
    var config = try CoreConfig.default(alloc);
    errdefer config.deinit();

    var reader: std.Io.Reader = .fixed(text(scheme));
    var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = "<webmux-gtk built-in config>" };
    try config.loadIter(alloc, &iter);
    try config.finalize();
    // URLs underline and click without a modifier, like xterm.js's
    // web-links addon (config/webmux.zig, shared with the macOS client).
    config_webmux.links(&config);
    return config;
}

test "built-in config parses cleanly and keeps only the terminal keybinds" {
    const testing = std.testing;
    inline for (.{ Scheme.dark, Scheme.light }) |scheme| {
        var config = try build(testing.allocator, scheme);
        defer config.deinit();

        try testing.expect(config._diagnostics.empty());
        try testing.expectEqual(@as(f32, 9.75), config.@"font-size");
        try testing.expectEqual(@as(usize, 0), config.keybind.set.bindings.count());
        try testing.expect(config.@"right-click-action" == .ignore);
        try testing.expectEqual(@as(usize, 12), config.@"selection-word-chars".codepoints.len);
        try testing.expect(!config.@"clipboard-paste-protection");
        try testing.expect(config.@"cursor-style-blink".?);
    }
}

test "url regex stops at an empty cell" {
    const testing = std.testing;
    const oni = @import("oniguruma");

    try oni.testing.ensureInit();
    var re = try oni.Regex.init(url_regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();

    const cases = [_]struct { input: []const u8, expect: []const u8 }{
        .{ .input = "see https://ex.invalid/a?b=c, then", .expect = "https://ex.invalid/a?b=c" },
        // A URL that ends its row, as the renderer sees it.
        .{ .input = "https://ex.invalid/m\x00\x00\x00\n", .expect = "https://ex.invalid/m" },
        .{ .input = "https://ex.invalid/m.\x00\x00", .expect = "https://ex.invalid/m" },
    };
    for (cases) |case| {
        var reg = try re.search(case.input, .{});
        defer reg.deinit();
        const start: usize = @intCast(reg.starts()[0]);
        const end: usize = @intCast(reg.ends()[0]);
        try testing.expectEqualStrings(case.expect, case.input[start..end]);
    }
}

test "scheme backgrounds" {
    const testing = std.testing;
    var config = try build(testing.allocator, .light);
    defer config.deinit();
    const bg = config.background.toTerminalRGB();
    try testing.expectEqual(@as(u8, 0xf4), bg.r);
    try testing.expectEqual(@as(u8, 0xf9), bg.b);
}
