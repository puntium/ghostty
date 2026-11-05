//! Persistence and reconciliation tests.
//!
//! `testdata/app_js_reconcile.jsonl` holds `[stored, live, expected]`
//! triples: the stored document (malformed in many ways), the server's
//! live session ids, and the layout app.js ends up with after
//! `loadLayout` + `attachExisting`, computed by running those functions
//! from app.js itself (`testdata/gen-reconcile.js`; regenerate with
//! `node gen-reconcile.js electron/ui/app.js < reconcile-cases.json`).

const std = @import("std");
const t = std.testing;
const Layout = @import("Layout.zig");
const persist = @import("persist.zig");
const testing = @import("testing.zig");
const gpa = testing.gpa;

const app_js_cases = @embedFile("testdata/app_js_reconcile.jsonl");

test "parse + reconcile match app.js loadLayout + attachExisting" {
    var lines = std.mem.splitScalar(u8, app_js_cases, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        const stored = items[0].string;
        var live: std.ArrayList([]const u8) = .empty;
        defer live.deinit(gpa);
        for (items[1].array.items) |id| try live.append(gpa, id.string);
        const expected = items[2].string;

        var l = try persist.load(gpa, stored, live.items);
        defer l.deinit();
        check(&l, expected) catch |err| {
            std.debug.print("case {d}: {s}\n", .{ n, line });
            return err;
        };
    }
    try t.expect(n >= 20);
}

fn check(l: *const Layout, expected_spec: []const u8) !void {
    var want = try testing.build(expected_spec);
    defer want.deinit();
    const want_str = try testing.render(&want);
    defer gpa.free(want_str);
    try testing.expectLayout(l, want_str);
    for (want.columns.items, 0..) |col, ci| try testing.expectSizes(l, ci, col.sizes.items);
}

// ---------------------------------------------------------------------------
// Round trip
// ---------------------------------------------------------------------------

test "serialize → parse round-trips structure, weights, flags, focus and file-browser state" {
    var l = try testing.build("s1:0.3,files-a:1.7^|!s2*|s3,s4^,files-b");
    defer l.deinit();
    try l.setPaneState("files-a", "{\"type\":\"files\",\"dir\":\"~/src\",\"cursor\":\"a \\\"b\\\"\"}");
    try l.setPaneState("files-b", "{\"dir\":\"/\",\"nested\":{\"x\":[1,2.5,null,true]}}");
    const text = try persist.serialize(gpa, &l);
    defer gpa.free(text);

    var back = try persist.parse(gpa, text);
    defer back.deinit();
    try testing.expectLayout(&back, "s1,files-a^|!s2^*|s3,s4^,files-b");
    try testing.expectSizes(&back, 0, &.{ 0.3, 1.7 });
    try t.expectEqualStrings(l.find("files-a").?.state.?, back.find("files-a").?.state.?);
    try t.expectEqualStrings(l.find("files-b").?.state.?, back.find("files-b").?.state.?);

    const again = try persist.serialize(gpa, &back);
    defer gpa.free(again);
    try t.expectEqualStrings(text, again);
}

test "serialize: the documented shape" {
    var l = try testing.build("s1,files-a^*|!s2");
    defer l.deinit();
    try l.setPaneState("files-a", "{\"dir\":\"~\"}");
    const text = try persist.serialize(gpa, &l);
    defer gpa.free(text);
    try t.expectEqualStrings(
        "{\"version\":1,\"columns\":[" ++
            "{\"panes\":[\"s1\",\"files-a\"],\"sizes\":[1,1],\"active\":\"files-a\",\"full\":false}," ++
            "{\"panes\":[\"s2\"],\"sizes\":[1],\"active\":\"s2\",\"full\":true}]," ++
            "\"focused\":\"files-a\",\"widgets\":{\"files-a\":{\"dir\":\"~\"}}}",
        text,
    );
}

test "serialize: empty layout, and ids that need escaping" {
    var e = Layout.init(gpa);
    defer e.deinit();
    const text = try persist.serialize(gpa, &e);
    defer gpa.free(text);
    try t.expectEqualStrings("{\"version\":1,\"columns\":[],\"focused\":null,\"widgets\":{}}", text);

    var l = Layout.init(gpa);
    defer l.deinit();
    try l.newTerminal("we\"ird\\id\n\u{e9}");
    const t2 = try persist.serialize(gpa, &l);
    defer gpa.free(t2);
    var back = try persist.parse(gpa, t2);
    defer back.deinit();
    try t.expect(back.find("we\"ird\\id\n\u{e9}") != null);
    try t.expectEqualStrings("we\"ird\\id\n\u{e9}", back.focusedId().?);
}

test "weights survive the round trip bit for bit" {
    var l = try testing.build("a,b,c*");
    defer l.deinit();
    const ws = [_]f64{ 0.1 + 0.2, 1.0 / 3.0, 123456.789e-3 };
    @memcpy(l.columns.items[0].sizes.items, &ws);
    const text = try persist.serialize(gpa, &l);
    defer gpa.free(text);
    var back = try persist.parse(gpa, text);
    defer back.deinit();
    for (ws, back.columns.items[0].sizes.items) |w, b| try t.expectEqual(w, b);
}

// ---------------------------------------------------------------------------
// Rejection of malformed input
// ---------------------------------------------------------------------------

fn expectParse(text: []const u8, expected: []const u8) !void {
    var l = try persist.parse(gpa, text);
    defer l.deinit();
    try testing.expectLayout(&l, expected);
}

test "parse: unusable documents are an empty layout" {
    try expectParse("", "");
    try expectParse("{", "");
    try expectParse("null", "");
    try expectParse("42", "");
    try expectParse("[{\"panes\":[\"a\"]}]", "");
    try expectParse("{}", "");
    try expectParse("{\"columns\":{}}", "");
    try expectParse("{\"columns\":[{\"panes\":[\"a\"]}]} trailing", "");
    try expectParse("\xff\xfe", "");
    // A split-tree document from before columns (app.js migrates these;
    // this client never wrote one).
    try expectParse("{\"type\":\"pane\",\"session\":\"a\"}", "");
}

test "parse: version" {
    try expectParse("{\"version\":1,\"columns\":[{\"panes\":[\"a\"]}]}", "a^*");
    try expectParse("{\"columns\":[{\"panes\":[\"a\"]}]}", "a^*");
    try expectParse("{\"version\":2,\"columns\":[{\"panes\":[\"a\"]}]}", "");
    try expectParse("{\"version\":\"1\",\"columns\":[{\"panes\":[\"a\"]}]}", "");
}

test "parse: malformed columns and panes are dropped one by one" {
    try expectParse(
        \\{"columns":[1,null,"x",[],{},{"panes":"a"},{"panes":[]},{"panes":[null,1,true,{},[],""]},
        \\  {"panes":["a",7,"b","a"],"sizes":[2,9,3,9],"active":"b"},{"panes":["b","c"]}],
        \\ "focused":"c"}
    , "a,b^|c^*");
    var l = try persist.parse(gpa,
        \\{"columns":[{"panes":["a",7,"b","a"],"sizes":[2,9,3,9],"active":"b"}]}
    );
    defer l.deinit();
    try testing.expectSizes(&l, 0, &.{ 2, 3 }); // weights follow their raw index
}

test "parse: weights that are not finite positive numbers become 1" {
    var l = try persist.parse(gpa,
        \\{"columns":[{"panes":["a","b","c","d","e","f","g","h"],
        \\  "sizes":[-1,0,null,"2",true,1e400,0.25,[]]}]}
    );
    defer l.deinit();
    try testing.expectSizes(&l, 0, &.{ 1, 1, 1, 1, 1, 1, 0.25, 1 });
    var m = try persist.parse(gpa, "{\"columns\":[{\"panes\":[\"a\",\"b\"],\"sizes\":{\"0\":5}}]}");
    defer m.deinit();
    try testing.expectSizes(&m, 0, &.{ 1, 1 });
}

test "parse: active and full" {
    try expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"zz\"}]}", "a^*,b");
    try expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":1}]}", "a^*,b");
    try expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"}]}", "a,b^*");
    try expectParse(
        \\{"columns":[{"panes":["a"],"full":true},{"panes":["b"],"full":"true"},{"panes":["c"],"full":1}]}
    , "!a^*|b^|c^");
}

test "parse: focus falls back to the first column's active pane" {
    try expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"},{\"panes\":[\"c\"]}],\"focused\":\"nope\"}", "a,b^*|c^");
    try expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"},{\"panes\":[\"c\"]}],\"focused\":3}", "a,b^*|c^");
    try expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"},{\"panes\":[\"c\"]}],\"focused\":\"c\"}", "a,b^|c^*");
    // Focused but not its column's active pane: kept as saved (app.js too).
    try expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"}],\"focused\":\"a\"}", "a*,b^");
}

test "parse: duplicate keys keep the last (JSON.parse)" {
    try expectParse("{\"columns\":[{\"panes\":[\"a\"]}],\"columns\":[{\"panes\":[\"b\"]}]}", "b^*");
}

test "parse: widget states kept only for files panes, only objects, bounded depth" {
    var l = try persist.parse(gpa,
        \\{"columns":[{"panes":["s1","files-a","files-b","files-c","files-d"]}],
        \\ "widgets":{"files-a":{"dir":"~"},"files-b":[1],"files-c":"x","s1":{"dir":"/"},
        \\   "files-gone":{"dir":"/"},
        \\   "files-d":{"a":[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]}}}
    );
    defer l.deinit();
    try t.expectEqualStrings("{\"dir\":\"~\"}", l.find("files-a").?.state.?);
    try t.expectEqual(@as(?[]const u8, null), l.find("files-b").?.state);
    try t.expectEqual(@as(?[]const u8, null), l.find("files-c").?.state);
    try t.expectEqual(@as(?[]const u8, null), l.find("files-d").?.state);
    try t.expectEqual(@as(?[]const u8, null), l.find("s1").?.state);
    const text = try persist.serialize(gpa, &l);
    defer gpa.free(text);
    try t.expect(std.mem.indexOf(u8, text, "files-gone") == null);

    try expectParse("{\"columns\":[{\"panes\":[\"files-a\"]}],\"widgets\":[1]}", "files-a^*");
}

test "parse: hostile nesting does not crash" {
    const depth = 20000;
    const doc = try gpa.alloc(u8, 2 * depth + 64);
    defer gpa.free(doc);
    var n: usize = 0;
    const head = "{\"columns\":[{\"panes\":[\"a\"]}],\"x\":";
    @memcpy(doc[0..head.len], head);
    n = head.len;
    @memset(doc[n .. n + depth], '[');
    n += depth;
    @memset(doc[n .. n + depth], ']');
    n += depth;
    doc[n] = '}';
    n += 1;
    try expectParse(doc[0..n], "a^*");
}

// ---------------------------------------------------------------------------
// Reconciliation edges beyond the app.js cases
// ---------------------------------------------------------------------------

test "reconcile: ignores repeated, empty and files-prefixed live ids" {
    var l = try persist.load(gpa, "{\"columns\":[{\"panes\":[\"s1\"]}]}", &.{ "s2", "s1", "s2", "", "files-x", "s3" });
    defer l.deinit();
    try testing.expectLayout(&l, "s1^*|s2^|s3^");
}

test "reconcile: nothing live and no files panes leaves an empty layout" {
    var l = try persist.load(gpa, "{\"columns\":[{\"panes\":[\"s1\",\"s2\"]},{\"panes\":[\"s3\"]}],\"focused\":\"s3\"}", &.{});
    defer l.deinit();
    try t.expect(l.isEmpty());
    try t.expectEqual(@as(?[]const u8, null), l.focusedId());
}

test "reconcile: a focused files pane survives with no sessions at all" {
    var l = try persist.load(gpa, "{\"columns\":[{\"panes\":[\"s1\"]},{\"panes\":[\"files-a\"]}],\"focused\":\"files-a\",\"widgets\":{\"files-a\":{\"d\":1}}}", &.{});
    defer l.deinit();
    try testing.expectLayout(&l, "files-a^*");
    try t.expectEqualStrings("{\"d\":1}", l.find("files-a").?.state.?);
}

test "reconcile: fresh start (no file) is just the live sessions in order" {
    var l = try persist.load(gpa, "", &.{ "b", "a", "c" });
    defer l.deinit();
    try testing.expectLayout(&l, "b^*|a^|c^");
}

test "reconcile: the saved focus may name a live session only reconciliation adds" {
    // app.js checks the saved focus after appending (case 22 above).
    var l = try persist.load(gpa, "{\"columns\":[{\"panes\":[\"s2\"]}],\"focused\":\"s1\"}", &.{ "s1", "s2" });
    defer l.deinit();
    try testing.expectLayout(&l, "s2^|s1^*");
    // parse alone (no reconciliation) cannot know it: first column's active.
    var p = try persist.parse(gpa, "{\"columns\":[{\"panes\":[\"s2\"]}],\"focused\":\"s1\"}");
    defer p.deinit();
    try testing.expectLayout(&p, "s2^*");
}

test "reconcile: an existing layout, focus id pointing into it, focused pane dropped" {
    var l = try testing.build("a|b*,c");
    defer l.deinit();
    try persist.reconcile(&l, &.{ "a", "c", "d" }, l.focusedId());
    try testing.expectLayout(&l, "a^*|c^|d^");
}

// ---------------------------------------------------------------------------
// OOM
// ---------------------------------------------------------------------------

test "parse, reconcile and serialize are OOM-safe" {
    const Case = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var l = try persist.load(alloc,
                \\{"columns":[{"panes":["s1","files-a","s2"],"sizes":[1,2,3],"active":"s2"},{"panes":["s3"],"full":true}],
                \\ "focused":"s4","widgets":{"files-a":{"dir":"~","c":[1,2]}}}
            , &.{ "s1", "s3", "s4" });
            defer l.deinit();
            try persist.reconcile(&l, &.{"s3"}, l.focusedId());
            const text = try persist.serialize(alloc, &l);
            alloc.free(text);
        }
    };
    try t.checkAllAllocationFailures(gpa, Case.run, .{});
}

// ---------------------------------------------------------------------------
// statePath
// ---------------------------------------------------------------------------

test "statePath: XDG_STATE_HOME, else ~/.local/state; slug must be one component" {
    const p1 = try persist.statePath(gpa, "/x/state/", "/home/u", "box-default");
    defer gpa.free(p1);
    try t.expectEqualStrings("/x/state/webmux-gtk/layout/box-default.json", p1);
    const p2 = try persist.statePath(gpa, null, "/home/u", "box");
    defer gpa.free(p2);
    try t.expectEqualStrings("/home/u/.local/state/webmux-gtk/layout/box.json", p2);
    const p3 = try persist.statePath(gpa, "relative/dir", "/home/u", "box");
    defer gpa.free(p3);
    try t.expectEqualStrings("/home/u/.local/state/webmux-gtk/layout/box.json", p3);
    const p4 = try persist.statePath(gpa, "", "/home/u/", "box");
    defer gpa.free(p4);
    try t.expectEqualStrings("/home/u/.local/state/webmux-gtk/layout/box.json", p4);
    try t.expectError(error.InvalidPath, persist.statePath(gpa, null, null, "box"));
    try t.expectError(error.InvalidPath, persist.statePath(gpa, null, "rel", "box"));
    for ([_][]const u8{ "", ".", "..", "a/b", "a\x00" }) |bad| {
        try t.expectError(error.InvalidPath, persist.statePath(gpa, "/s", "/h", bad));
    }
}
