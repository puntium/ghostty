//! Unit tests of the chrome's pure bits (no display needed).
const std = @import("std");
const testing = std.testing;
const gtk = @import("gtk");
const gdk = @import("gdk");

const hub = @import("hub.zig");
const header = @import("header.zig");
const menu = @import("menu.zig");
const shortcuts = @import("../shortcuts.zig");

fn parse(accel: [:0]const u8) shortcuts.Chord {
    var key: c_uint = 0;
    var mods: gdk.ModifierType = .{};
    std.debug.assert(gtk.acceleratorParse(accel, &key, &mods) != 0);
    return .{ .keyval = gdk.keyvalToLower(key), .mods = .fromGdk(mods) };
}

test "chrome: app shortcuts never collide with a pane chord (K-27)" {
    // Pane chords: the Pane menu's accelerators plus the vim-key variants.
    var pane: std.ArrayList(shortcuts.Chord) = .empty;
    defer pane.deinit(testing.allocator);
    for (menu.pane_menu) |e| if (e) |x| try pane.append(testing.allocator, parse(x.accel));
    for ([_][:0]const u8{ "h", "j", "k", "l" }) |k| {
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        try pane.append(testing.allocator, parse(try std.fmt.bufPrintSentinel(&b1, "<Control><Shift>{s}", .{k}, 0)));
        try pane.append(testing.allocator, parse(try std.fmt.bufPrintSentinel(&b2, "<Alt><Control><Shift>{s}", .{k}, 0)));
    }
    var app_rows: usize = 0;
    for (shortcuts.table) |row| {
        if (!std.mem.startsWith(u8, row.action, "app.")) continue;
        app_rows += 1;
        const c = parse(row.accel);
        for (pane.items) |p| try testing.expect(!c.eql(p));
        // Ctrl-based, never Alt or Super (main.js: control, no alt/meta).
        try testing.expect(c.mods.ctrl and !c.mods.alt and !c.mods.super);
    }
    try testing.expect(app_rows >= 15);
    // The bindings PARITY K-20…K-26 name.
    try testing.expectEqualStrings("app.show-connections", shortcuts.lookup(parse("<Control><Shift>o")).?);
    try testing.expectEqualStrings("app.reconnect", shortcuts.lookup(parse("<Control><Shift>r")).?);
    try testing.expectEqualStrings("app.show-log", shortcuts.lookup(parse("<Control><Shift>g")).?);
    try testing.expectEqualStrings("app.show-settings", shortcuts.lookup(parse("<Control>comma")).?);
    try testing.expectEqualStrings("app.host-prev", shortcuts.lookup(parse("<Control>Page_Up")).?);
    try testing.expectEqualStrings("app.host-next", shortcuts.lookup(parse("<Control>Page_Down")).?);
    try testing.expectEqualStrings("app.host-9", shortcuts.lookup(parse("<Control>9")).?);
}

fn fakeEntry(id: u64, name: []const u8, state: @import("../../../webmux/conn.zig").State, panes: usize, offline: bool) hub.Entry {
    return .{
        .id = id,
        .name = @constCast(name),
        .state = state,
        .view = .{ .entry_id = id },
        .panes = panes,
        .offline = offline,
        .stack_name = @constCast("x"),
    };
}

test "chrome: window title (W-03)" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("webmux", hub.titleText(&buf));

    var a = fakeEntry(1, "a", .connected, 1, false);
    var b = fakeEntry(2, "b", .connecting, 0, false);
    hub.hub.entries = .empty;
    defer hub.hub.entries.deinit(testing.allocator);
    try hub.hub.entries.append(testing.allocator, &a);
    try testing.expectEqualStrings("webmux — 1 host · 1 pane", hub.titleText(&buf));
    a.panes = 3;
    try hub.hub.entries.append(testing.allocator, &b);
    try testing.expectEqualStrings("webmux — 2 hosts · 3 panes", hub.titleText(&buf));
    a.panes = 0;
    try testing.expectEqualStrings("webmux — 2 hosts · 0 panes", hub.titleText(&buf));
}

test "chrome: pill tooltip and dot (W-12, W-14)" {
    var buf: [256]u8 = undefined;
    var e = fakeEntry(1, "devbox", .connected, 1, false);
    try testing.expectEqualStrings("devbox — connected (Ctrl+1)", header.pillTooltip(&e, 0, &buf));
    e.offline = true;
    try testing.expectEqualStrings("devbox — server unreachable — page retrying (Ctrl+3)", header.pillTooltip(&e, 2, &buf));
    e.state = .connecting;
    try testing.expectEqualStrings("devbox — connecting…", header.pillTooltip(&e, 9, &buf));
    e.state = .failed;
    try testing.expectEqualStrings("devbox — connection failed (Ctrl+9)", header.pillTooltip(&e, 8, &buf));
    e.state = .retry;
    try testing.expectEqualStrings("devbox — interrupted — retrying (Ctrl+1)", header.pillTooltip(&e, 0, &buf));
    // No status yet: grey; then by state, degraded when offline.
    try testing.expectEqualStrings("unknown", header.dotClass(&e));
}
