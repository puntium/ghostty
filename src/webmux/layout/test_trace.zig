//! Differential test against app.js itself. `testdata/gen-trace.js` loads
//! the real layout functions out of `electron/ui/app.js` (extracted from
//! the source text by name, DOM and network stubbed), runs random command
//! sequences on them and writes, per step, the command and the resulting
//! layout in `testing.zig` spec syntax. This replays every step on the Zig
//! model and requires the same layout after each: columns, panes, order,
//! weights, full flags, active panes and focus.
//!
//! Regenerate (from the webmux checkout root):
//!   for s in $(seq 1 16); do node gtk/ghostty/src/webmux/layout/testdata/gen-trace.js \
//!     electron/ui/app.js $s 100; done > gtk/ghostty/src/webmux/layout/testdata/app_js_trace.jsonl

const std = @import("std");
const t = std.testing;
const Layout = @import("Layout.zig");
const testing = @import("testing.zig");

const trace = @embedFile("testdata/app_js_trace.jsonl");

const Step = struct {
    cmd: []const u8,
    id: ?[]const u8 = null,
    col: ?usize = null,
    row: ?usize = null,
    w: ?f64 = null,
    after: []const u8,
};

test "app.js differential trace" {
    var l: Layout = .init(testing.gpa);
    defer l.deinit();
    var lines = std.mem.splitScalar(u8, trace, '\n');
    var n: usize = 0;
    var resets: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        const parsed = try std.json.parseFromSlice(Step, testing.gpa, line, .{});
        defer parsed.deinit();
        const s = parsed.value;
        if (std.mem.eql(u8, s.cmd, "reset")) { // a new run, from an empty layout
            l.deinit();
            l = .init(testing.gpa);
            resets += 1;
            continue;
        }
        apply(&l, s) catch |err| {
            std.debug.print("step {d}: {s}\n", .{ n, line });
            return err;
        };
        expectSame(&l, s.after) catch |err| {
            std.debug.print("step {d}: {s}\n", .{ n, line });
            return err;
        };
    }
    try t.expect(n >= 1000);
    try t.expectEqual(@as(usize, 16), resets);
}

fn apply(l: *Layout, s: Step) !void {
    const cmd = s.cmd;
    if (std.mem.eql(u8, cmd, "new-terminal")) return l.newTerminal(s.id.?);
    if (std.mem.eql(u8, cmd, "new-terminal-below")) return l.newTerminalBelow(s.id.?);
    if (std.mem.eql(u8, cmd, "new-files")) return l.newFiles(s.id.?, null);
    if (std.mem.eql(u8, cmd, "close-pane")) {
        if (l.focusedId()) |f| {
            const copy = try testing.gpa.dupe(u8, f);
            defer testing.gpa.free(copy);
            try t.expect(l.remove(copy));
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "remove")) {
        try t.expect(l.remove(s.id.?));
        return;
    }
    if (std.mem.eql(u8, cmd, "click")) {
        _ = l.setFocus(s.id.?);
        return;
    }
    if (std.mem.eql(u8, cmd, "set-weight")) {
        l.columns.items[s.col.?].sizes.items[s.row.?] = s.w.?;
        return;
    }
    const c = Layout.Command.fromName(cmd) orelse return error.UnknownCommand;
    _ = try l.run(c);
}

fn expectSame(l: *const Layout, expected_spec: []const u8) !void {
    var want = try testing.build(expected_spec);
    defer want.deinit();
    const want_str = try testing.render(&want);
    defer testing.gpa.free(want_str);
    try testing.expectLayout(l, want_str);
    for (want.columns.items, 0..) |col, ci| try testing.expectSizes(l, ci, col.sizes.items);
}
