//! The panels' pure parts: no GTK, unit-tested on their own.
//!
//!   - the theme list and settings validation (PARITY E-01…E-05; ruling
//!     A-12: this is the one place the theme ids live, unknown ids fall
//!     back to dark);
//!   - the log window's filtering, display and copy text (G-22…G-27;
//!     electron/logs.html);
//!   - the URL scheme rules (T-24…T-26, M-04; electron/ui/app.js
//!     activateLink / showLinkModal, main.js setWindowOpenHandler).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const conn = @import("../../../webmux/conn.zig");
const util = @import("../../../webmux/conn/util.zig");
const Log = conn.Log;
const Settings = conn.Settings;
const SettingsPatch = conn.SettingsPatch;

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

pub const Theme = struct {
    /// Stored id (config.json `settings.theme`).
    id: []const u8,
    /// What the settings panel's select shows (settings.js THEMES[id].label).
    label: [:0]const u8,
    /// Which built-in terminal scheme and libadwaita appearance it uses.
    dark: bool,
};

/// electron/ui/settings.js THEMES, in select order. The first is the
/// fallback for unknown ids.
pub const themes = [_]Theme{
    .{ .id = "dark", .label = "Dark mode default", .dark = true },
    .{ .id = "light", .label = "Light mode", .dark = false },
};

pub const defaults: Settings = .{};

/// Index into `themes` of a theme id; unknown ids are dark (index 0).
pub fn themeIndex(id: []const u8) usize {
    for (themes, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) return i;
    return 0;
}

pub fn themeOf(s: *const Settings) Theme {
    return themes[themeIndex(s.theme.slice())];
}

pub fn knownTheme(id: []const u8) bool {
    for (themes) |t| if (std.mem.eql(u8, t.id, id)) return true;
    return false;
}

/// The settings as the client applies them: numbers clamped and rounded,
/// max never below min (conn's sanitizeSettings, which is main.js's), and
/// an unknown theme id replaced by dark (settings.js sanitize).
pub fn normalize(s: Settings) Settings {
    var out = conn.profile.sanitizeSettings(s, .{});
    if (!knownTheme(out.theme.slice())) _ = out.theme.set(themes[0].id);
    return out;
}

/// settings.js `sanitize({ ...settings, ...patch })`: apply a partial
/// change. A theme id the client does not know becomes dark; malformed
/// numbers (NaN, ±inf) keep the current value.
pub fn applyPatch(base: Settings, patch: SettingsPatch) Settings {
    var p = patch;
    if (p.theme) |t| {
        if (!knownTheme(t)) p.theme = themes[0].id;
    }
    return normalize(conn.profile.sanitizeSettings(base, p));
}

/// The full settings as a patch (what the panel persists through the
/// engine, so the store ends up with exactly what is applied).
pub fn toPatch(s: *const Settings) SettingsPatch {
    return .{
        .theme = s.theme.slice(),
        .unfocused_fade = @floatFromInt(s.unfocused_fade),
        .min_cols = @floatFromInt(s.min_cols),
        .max_cols = @floatFromInt(s.max_cols),
    };
}

pub fn eql(a: *const Settings, b: *const Settings) bool {
    return std.mem.eql(u8, a.theme.slice(), b.theme.slice()) and
        a.unfocused_fade == b.unfocused_fade and
        a.min_cols == b.min_cols and
        a.max_cols == b.max_cols;
}

/// Parse a setting value the way JS `Number(v)` would for what the control
/// socket hands us (number or numeric string); null for anything else.
pub fn numberFromJson(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Log window
// ---------------------------------------------------------------------------

/// The Host select's value for entries with no connection (logs.html
/// `'·client·'`), shown as `client (no host)`.
pub const client_key = "·client·";
pub const client_label = "client (no host)";

/// Level select, in order (logs.html `#level`); the default is info+.
pub const level_labels = [_][:0]const u8{ "debug+", "info+", "warn+", "error" };
pub const default_level: Log.Level = .info;

/// Ring size the window mirrors (log.js MAX_ENTRIES).
pub const max_rows = Log.MAX_ENTRIES;

pub const Filter = struct {
    /// null = all hosts; else a host key (`hostKey`).
    host: ?[]const u8 = null,
    min: Log.Level = default_level,
    /// Already trimmed and lowercased (`normalizeQuery`); empty = none.
    text: []const u8 = "",

    pub fn active(f: Filter) bool {
        return f.host != null or f.min != .debug or f.text.len > 0;
    }
};

pub fn hostKey(conn_name: ?[]const u8) []const u8 {
    return conn_name orelse client_key;
}

pub fn levelRank(l: Log.Level) u8 {
    return @backingInt(l);
}

/// logs.html `passes`: host matches, level at least the minimum, and the
/// file-format line contains the text (case-insensitive).
pub fn passes(f: Filter, conn_name: ?[]const u8, level: Log.Level, line: []const u8) bool {
    if (f.host) |h| if (!std.mem.eql(u8, hostKey(conn_name), h)) return false;
    if (levelRank(level) < levelRank(f.min)) return false;
    if (f.text.len > 0 and !containsLower(line, f.text)) return false;
    return true;
}

/// Case-insensitive (ASCII) substring test; `needle` is already lowercase.
pub fn containsLower(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(hay[i + j]) != c) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// logs.html `$('search').value.trim().toLowerCase()` into `buf`.
pub fn normalizeQuery(buf: []u8, raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    const n = @min(t.len, buf.len);
    for (t[0..n], buf[0..n]) |c, *o| o.* = std.ascii.toLower(c);
    return buf[0..n];
}

/// logs.html `dataOf`: `k=v` joined by spaces, strings bare (including the
/// JSON text log.js keeps for non-scalars), everything else as JSON.
pub fn writeDisplayData(w: *Io.Writer, fields: []const Log.Field) Io.Writer.Error!void {
    for (fields, 0..) |f, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{s}=", .{f.key});
        switch (f.value) {
            .str, .json => |s| try w.writeAll(s),
            .int => |n| try w.print("{d}", .{n}),
            .float => |x| try util.writeJsNumber(w, x),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .null => try w.writeAll("null"),
        }
    }
}

pub fn displayDataAlloc(alloc: Allocator, fields: []const Log.Field) ![]u8 {
    var aw: Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    writeDisplayData(&aw.writer, fields) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// logs.html `copy`: the lines newline-joined, with a trailing newline
/// when there is at least one.
pub fn copyText(alloc: Allocator, lines: []const []const u8) ![]u8 {
    var len: usize = 0;
    for (lines) |l| len += l.len + 1;
    const out = try alloc.alloc(u8, len);
    var i: usize = 0;
    for (lines) |l| {
        @memcpy(out[i..][0..l.len], l);
        i += l.len;
        out[i] = '\n';
        i += 1;
    }
    return out;
}

/// The status bar count (logs.html `updateCount`).
pub fn countText(buf: []u8, shown: usize, total: usize) []const u8 {
    return (if (shown == total)
        std.fmt.bufPrint(buf, "{d} entries", .{total})
    else
        std.fmt.bufPrint(buf, "{d} of {d} entries", .{ shown, total })) catch "";
}

/// The copy flash: `copied N visible line(s)` / `copied N line(s)`.
/// (logs.html passes `''` for Copy all, which leaves a double space; the
/// intent, and PARITY G-25, is one.)
pub fn copiedText(buf: []u8, n: usize, visible: bool) []const u8 {
    return std.fmt.bufPrint(buf, "copied {d} {s}line{s}", .{
        n,
        if (visible) "visible " else "",
        if (n == 1) "" else "s",
    }) catch "";
}

pub const empty_no_entries = "No log entries yet.";
pub const empty_no_match = "Nothing matches the current filters.";

pub fn emptyText(total: usize) []const u8 {
    return if (total == 0) empty_no_entries else empty_no_match;
}

/// G-24: follow is on exactly when the view is within 4px of the bottom.
pub fn atBottom(upper: f64, value: f64, page: f64) bool {
    return upper - value - page < 4;
}

// ---------------------------------------------------------------------------
// Toolbar wrapping (logs.html #toolbar: `display: flex; flex-wrap: wrap;
// gap: 8px` with a `flex: 1` spacer)
// ---------------------------------------------------------------------------

pub const FlowItem = struct {
    min: i32,
    nat: i32,
    /// The `flex: 1` spacer: no width of its own, takes its line's slack.
    spacer: bool = false,
};

pub const FlowPlace = struct { line: u32, x: i32, w: i32 };

/// Flex-wrap line breaking: items keep their natural width (shrunk to
/// what is available, never below their minimum), lines break when the
/// next item does not fit, and the spacer takes the free space of its
/// line, pushing what follows it on that line to the right end. Returns
/// the number of lines.
pub fn flow(items: []const FlowItem, avail: i32, gap: i32, out: []FlowPlace) u32 {
    std.debug.assert(out.len >= items.len);
    var line: u32 = 0;
    var x: i32 = 0;
    var line_start: usize = 0;
    var any = false;
    for (items, 0..) |it, i| {
        const w: i32 = if (it.spacer) 0 else @max(it.min, @min(it.nat, avail));
        if (any and x + gap + w > avail) {
            finishLine(items, out, line_start, i, avail, x);
            line += 1;
            x = 0;
            line_start = i;
            any = false;
        }
        const at = if (any) x + gap else 0;
        out[i] = .{ .line = line, .x = at, .w = w };
        x = at + w;
        any = true;
    }
    if (items.len > 0) finishLine(items, out, line_start, items.len, avail, x);
    return if (items.len == 0) 0 else line + 1;
}

fn finishLine(items: []const FlowItem, out: []FlowPlace, from: usize, to: usize, avail: i32, used: i32) void {
    const slack = avail - used;
    if (slack <= 0) return;
    var shift: i32 = 0;
    for (from..to) |j| {
        out[j].x += shift;
        if (items[j].spacer and shift == 0) {
            out[j].w += slack;
            shift = slack;
        }
    }
}

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

pub const UrlKind = enum {
    /// http: / https: — clicks open it in the browser, shift-click copies,
    /// the chooser offers Open in browser.
    web,
    /// mailto: — never activated by a click; the chooser offers Open (the
    /// default mail application) and Copy.
    mailto,
    /// anything else (file:, javascript:, ssh:, …) — inert; the chooser
    /// offers Copy only.
    other,
};

pub fn urlKind(url: []const u8) UrlKind {
    if (std.ascii.startsWithIgnoreCase(url, "http:") or std.ascii.startsWithIgnoreCase(url, "https:")) return .web;
    if (std.ascii.startsWithIgnoreCase(url, "mailto:")) return .mailto;
    return .other;
}

/// Whether a plain click (`.open`) or shift-click (`.copy`) acts on it:
/// only http(s) links are live (T-25: `allowNonHttpProtocols: false`;
/// T-26: anything else the page tries to open is denied).
pub fn clickable(kind: UrlKind) bool {
    return kind == .web;
}

/// Whether the chooser shows an Open button, and its label.
pub fn chooserOpenLabel(kind: UrlKind) ?[:0]const u8 {
    return switch (kind) {
        .web => "Open in browser",
        .mailto => "Open",
        .other => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn withTheme(id: []const u8) Settings {
    var s: Settings = .{};
    _ = s.theme.set(id);
    return s;
}

test "panels model: theme list, unknown ids fall back to dark" {
    try testing.expectEqual(@as(usize, 0), themeIndex("dark"));
    try testing.expectEqual(@as(usize, 1), themeIndex("light"));
    try testing.expectEqual(@as(usize, 0), themeIndex("solarized"));
    try testing.expectEqualStrings("Dark mode default", themes[0].label);
    try testing.expectEqualStrings("Light mode", themes[1].label);
    const n = normalize(withTheme("solarized"));
    try testing.expectEqualStrings("dark", n.theme.slice());
    try testing.expect(themeOf(&withTheme("light")).dark == false);
}

test "panels model: defaults are settings.js DEFAULTS" {
    const d = normalize(.{});
    try testing.expectEqualStrings("dark", d.theme.slice());
    try testing.expectEqual(@as(u8, 40), d.unfocused_fade);
    try testing.expectEqual(@as(u16, 90), d.min_cols);
    try testing.expectEqual(@as(u16, 200), d.max_cols);
}

test "panels model: fade and widths are clamped and rounded" {
    const base = normalize(.{});
    try testing.expectEqual(@as(u8, 100), applyPatch(base, .{ .unfocused_fade = 140 }).unfocused_fade);
    try testing.expectEqual(@as(u8, 0), applyPatch(base, .{ .unfocused_fade = -3 }).unfocused_fade);
    try testing.expectEqual(@as(u8, 13), applyPatch(base, .{ .unfocused_fade = 12.5 }).unfocused_fade);
    try testing.expectEqual(@as(u8, 40), applyPatch(base, .{ .unfocused_fade = std.math.nan(f64) }).unfocused_fade);
    try testing.expectEqual(@as(u16, 40), applyPatch(base, .{ .min_cols = 1 }).min_cols);
    try testing.expectEqual(@as(u16, 400), applyPatch(base, .{ .max_cols = 9000 }).max_cols);
    try testing.expectEqual(@as(u16, 90), applyPatch(base, .{ .min_cols = std.math.inf(f64) }).min_cols);
}

test "panels model: max is never below min, whichever moved" {
    const base = normalize(.{});
    // Raising the min lifts the max with it.
    const a = applyPatch(base, .{ .min_cols = 250 });
    try testing.expectEqual(@as(u16, 250), a.min_cols);
    try testing.expectEqual(@as(u16, 250), a.max_cols);
    // Lowering the max below the min is raised to the min.
    const b = applyPatch(base, .{ .max_cols = 50 });
    try testing.expectEqual(@as(u16, 90), b.min_cols);
    try testing.expectEqual(@as(u16, 90), b.max_cols);
}

test "panels model: patch with an unknown theme is dark, other fields kept" {
    var base = normalize(.{ .unfocused_fade = 20 });
    _ = base.theme.set("light");
    const s = applyPatch(base, .{ .theme = "neon" });
    try testing.expectEqualStrings("dark", s.theme.slice());
    try testing.expectEqual(@as(u8, 20), s.unfocused_fade);
    const t = applyPatch(base, .{ .theme = "light" });
    try testing.expect(eql(&t, &base));
    const p = toPatch(&t);
    const round = applyPatch(.{}, p);
    try testing.expect(eql(&round, &t));
}

test "panels model: numbers from control-socket JSON" {
    try testing.expectEqual(@as(?f64, 5), numberFromJson(.{ .integer = 5 }));
    try testing.expectEqual(@as(?f64, 2.5), numberFromJson(.{ .string = " 2.5" }));
    try testing.expectEqual(@as(?f64, null), numberFromJson(.{ .string = "abc" }));
    try testing.expectEqual(@as(?f64, null), numberFromJson(.{ .bool = true }));
}

test "panels model: log filter matching" {
    const line = "2026-11-04T10:00:00.000Z WARN  [prod] tunnel exited code=255";
    try testing.expect(passes(.{}, "prod", .warn, line));
    try testing.expect(!passes(.{}, "prod", .debug, line)); // info+ default
    try testing.expect(passes(.{ .min = .debug }, "prod", .debug, line));
    try testing.expect(!passes(.{ .min = .@"error" }, "prod", .warn, line));
    try testing.expect(passes(.{ .host = "prod" }, "prod", .warn, line));
    try testing.expect(!passes(.{ .host = "prod" }, null, .warn, line));
    try testing.expect(passes(.{ .host = client_key }, null, .info, line));
    try testing.expect(!passes(.{ .host = client_key }, "prod", .info, line));
    var buf: [64]u8 = undefined;
    const q = normalizeQuery(&buf, "  TUNNEL Exited ");
    try testing.expectEqualStrings("tunnel exited", q);
    try testing.expect(passes(.{ .text = q }, "prod", .warn, line));
    try testing.expect(!passes(.{ .text = "nope" }, "prod", .warn, line));
    try testing.expect(containsLower("ABC", ""));
    try testing.expect(!containsLower("ab", "abc"));
    try testing.expect(!(Filter{ .min = .debug }).active());
    try testing.expect((Filter{}).active());
}

test "panels model: display data is logs.html dataOf" {
    const fields = [_]Log.Field{
        .{ .key = "pid", .value = .{ .int = 42 } },
        .{ .key = "cmd", .value = .{ .str = "ssh -N host" } },
        .{ .key = "ok", .value = .{ .boolean = false } },
        .{ .key = "x", .value = .null },
        .{ .key = "ms", .value = .{ .float = 1.5 } },
        .{ .key = "o", .value = .{ .json = "{\"a\":1}" } },
    };
    const s = try displayDataAlloc(testing.allocator, &fields);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("pid=42 cmd=ssh -N host ok=false x=null ms=1.5 o={\"a\":1}", s);
}

test "panels model: copy text, count and flash strings" {
    const t = try copyText(testing.allocator, &.{ "a", "bc" });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("a\nbc\n", t);
    const e = try copyText(testing.allocator, &.{});
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("", e);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("12 entries", countText(&buf, 12, 12));
    try testing.expectEqualStrings("3 of 12 entries", countText(&buf, 3, 12));
    try testing.expectEqualStrings("copied 1 visible line", copiedText(&buf, 1, true));
    try testing.expectEqualStrings("copied 7 lines", copiedText(&buf, 7, false));
    try testing.expectEqualStrings(empty_no_entries, emptyText(0));
    try testing.expectEqualStrings(empty_no_match, emptyText(5));
}

test "panels model: follow threshold" {
    try testing.expect(atBottom(1000, 600, 400));
    try testing.expect(atBottom(1000, 597, 400));
    try testing.expect(!atBottom(1000, 596, 400));
}

test "panels model: url scheme rules" {
    try testing.expectEqual(UrlKind.web, urlKind("https://example.com"));
    try testing.expectEqual(UrlKind.web, urlKind("HTTP://x"));
    try testing.expectEqual(UrlKind.mailto, urlKind("mailto:a@b.c"));
    try testing.expectEqual(UrlKind.other, urlKind("file:///etc/passwd"));
    try testing.expectEqual(UrlKind.other, urlKind("javascript:alert(1)"));
    try testing.expectEqual(UrlKind.other, urlKind("httpx://x"));
    try testing.expect(clickable(.web));
    try testing.expect(!clickable(.mailto));
    try testing.expect(!clickable(.other));
    try testing.expectEqualStrings("Open in browser", chooserOpenLabel(.web).?);
    try testing.expectEqualStrings("Open", chooserOpenLabel(.mailto).?);
    try testing.expect(chooserOpenLabel(.other) == null);
}

test "panels model: toolbar flow wraps like flex-wrap with a spacer" {
    const items = [_]FlowItem{
        .{ .min = 50, .nat = 100 }, // host
        .{ .min = 50, .nat = 80 }, // level
        .{ .min = 200, .nat = 200 }, // search
        .{ .min = 60, .nat = 60 }, // follow
        .{ .min = 0, .nat = 0, .spacer = true },
        .{ .min = 90, .nat = 90 }, // copy visible
        .{ .min = 70, .nat = 70 }, // copy all
    };
    var out: [items.len]FlowPlace = undefined;
    // Wide: one line, the buttons pushed to the right end.
    try testing.expectEqual(@as(u32, 1), flow(&items, 1000, 8, &out));
    try testing.expectEqual(@as(i32, 1000 - 70), out[6].x);
    try testing.expectEqual(@as(i32, 1000 - 70 - 8 - 90), out[5].x);
    try testing.expectEqual(@as(i32, 0), out[0].x);
    try testing.expectEqual(@as(i32, 108), out[1].x);
    // Narrow: the buttons go to a second line, starting at the left.
    try testing.expectEqual(@as(u32, 2), flow(&items, 500, 8, &out));
    for (out[0..5]) |p| try testing.expectEqual(@as(u32, 0), p.line);
    try testing.expectEqual(@as(u32, 1), out[5].line);
    try testing.expectEqual(@as(i32, 0), out[5].x);
    try testing.expectEqual(@as(i32, 98), out[6].x);
    // Every item stays whole and inside the width.
    for (out) |p| try testing.expect(p.x + p.w <= 500);
    // Very narrow: one item per line, shrunk toward its minimum.
    const n = flow(&items, 150, 8, &out);
    try testing.expect(n >= 6);
    try testing.expectEqual(@as(i32, 100), out[0].w);
    try testing.expectEqual(@as(i32, 200), out[2].w); // never below min
    try testing.expectEqual(@as(u32, 0), flow(&.{}, 100, 8, &out));
}
