//! Headless suite for the webmux backend's protocol core: a real, isolated
//! webmux host (net.TestHost), the real Client, and a plain
//! `terminal.Terminal` driven by its own VT stream as the sink. Assertions
//! are on the terminal's text and state.
//!
//! Run: zig build test -Dtest-filter=webmux
const std = @import("std");
const t = std.testing;
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");
const net = @import("../../webmux/net.zig");
const Client = @import("Client.zig");
const replay = @import("replay.zig");
const TestHost = net.TestHost;

const ns_per_ms = std.time.ns_per_ms;

/// A headless terminal standing in for Termio.
const Sink = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    term: terminal.Terminal,
    stream: terminal.TerminalStream,
    strategy: replay.Strategy = .remote_grid,

    events: std.ArrayList(Recorded) = .empty,
    snapshots: usize = 0,

    const Recorded = struct {
        tag: std.meta.Tag(Client.Event),
        text: []u8, // title / message / url, or ""
        code: i64 = 0,
    };

    fn create(alloc: Allocator, cols: u16, rows: u16) !*Sink {
        const self = try alloc.create(Sink);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .term = try .init(t.io, alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = null,
                .max_scrollback_lines = 10_000,
            }),
            .stream = undefined,
        };
        self.stream = self.term.vtStream();
        return self;
    }

    fn destroy(self: *Sink) void {
        for (self.events.items) |e| self.alloc.free(e.text);
        self.events.deinit(self.alloc);
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn clientSink(self: *Sink) Client.Sink {
        return .{ .ctx = self, .snapshot = snapshotCb, .output = outputCb };
    }

    fn eventSink(self: *Sink) Client.EventSink {
        return .{ .userdata = self, .callback = eventCb };
    }

    fn snapshotCb(ctx: *anyopaque, snap: *const net.protocol.Snapshot, cancel: *const std.atomic.Value(bool)) Client.GridSize {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        replay.apply(self.alloc, &self.term, &self.stream, snap.data, snap.cols, snap.rows, null, self.strategy, cancel);
        self.snapshots += 1;
        return .{ .cols = self.term.cols, .rows = self.term.rows };
    }

    fn outputCb(ctx: *anyopaque, data: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.stream.nextSlice(data);
    }

    fn eventCb(ud: ?*anyopaque, ev: *const Client.Event) void {
        const self: *Sink = @ptrCast(@alignCast(ud.?));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        const label: []const u8 = switch (ev.*) {
            .title => |s| s,
            .session_title => |s| s.title,
            .session_error => |e| e.message,
            .open_url => |u| u.url,
            .paste_result => |p| p.mode,
            else => "",
        };
        const code: i64 = switch (ev.*) {
            .exit => |e| e.code,
            else => 0,
        };
        const copy = self.alloc.dupe(u8, label) catch return;
        self.events.append(self.alloc, .{ .tag = ev.*, .text = copy, .code = code }) catch self.alloc.free(copy);
    }

    /// Whole screen including scrollback, rows joined by "\n".
    fn text(self: *Sink) ![]const u8 {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        return self.term.screens.active.dumpStringAlloc(self.alloc, .{ .screen = .{} });
    }

    fn count(self: *Sink, tag: std.meta.Tag(Client.Event)) usize {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        var n: usize = 0;
        for (self.events.items) |e| n += @intFromBool(e.tag == tag);
        return n;
    }

    fn lastEvent(self: *Sink, tag: std.meta.Tag(Client.Event)) ?Recorded {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        var i = self.events.items.len;
        while (i > 0) {
            i -= 1;
            if (self.events.items[i].tag == tag) return self.events.items[i];
        }
        return null;
    }

    fn snapshotCount(self: *Sink) usize {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        return self.snapshots;
    }

    /// Local resize, in Termio's order: tell the backend, resize the grid.
    fn resize(self: *Sink, client: *Client, cols: u16, rows: u16) !void {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        client.resize(cols, rows);
        try self.term.resize(self.alloc, .{ .cols = cols, .rows = rows });
    }

    fn waitText(self: *Sink, needle: []const u8, timeout_ms: u32) !void {
        const deadline = net.Conn.now() + @as(i64, timeout_ms) * ns_per_ms;
        while (true) {
            const s = try self.text();
            defer self.alloc.free(s);
            if (std.mem.indexOf(u8, s, needle) != null) return;
            if (net.Conn.now() > deadline) {
                std.log.err("timed out waiting for {s}; screen:\n{s}", .{ needle, s });
                return error.Timeout;
            }
            try sleep(20);
        }
    }

    fn waitCount(self: *Sink, tag: std.meta.Tag(Client.Event), n: usize, timeout_ms: u32) !void {
        const deadline = net.Conn.now() + @as(i64, timeout_ms) * ns_per_ms;
        while (self.count(tag) < n) {
            if (net.Conn.now() > deadline) return error.Timeout;
            try sleep(20);
        }
    }

    fn waitSnapshots(self: *Sink, n: usize, timeout_ms: u32) !void {
        const deadline = net.Conn.now() + @as(i64, timeout_ms) * ns_per_ms;
        while (self.snapshotCount() < n) {
            if (net.Conn.now() > deadline) return error.Timeout;
            try sleep(20);
        }
    }
};

fn sleep(ms: u32) !void {
    try std.Io.sleep(t.io, .fromMilliseconds(ms), .awake);
}

fn startHost() !*TestHost {
    return TestHost.start(t.allocator, t.io, t.environ);
}

fn newSession(host: *TestHost, cols: u16, rows: u16) ![]u8 {
    var c = try host.client();
    defer c.deinit();
    return net.api.createSession(&c, t.allocator, cols, rows, .{});
}

fn attach(host: *TestHost, sink: *Sink, id: []const u8) !*Client {
    const c = try Client.create(t.allocator, t.io, sink.clientSink(), .{
        .socket_path = host.socket_path,
        .session_id = id,
        .events = sink.eventSink(),
        // Faster retries keep the reconnect tests short; the doubling and
        // cap are the production ones scaled down.
        .retry_initial_ms = 100,
        .retry_max_ms = 400,
    });
    errdefer c.destroy();
    try c.start();
    return c;
}

fn detach(c: *Client) void {
    c.stop();
    c.destroy();
}

/// How many times `needle` occurs as a whole line in `s`.
fn lineCount(s: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, l, " "), needle)) n += 1;
    }
    return n;
}

fn expectSeqOnce(s: []const u8, n: usize) !void {
    var buf: [16]u8 = undefined;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const num = try std.fmt.bufPrint(&buf, "{d}", .{i});
        const c = lineCount(s, num);
        if (c != 1) {
            std.log.err("line {s} appears {d} times", .{ num, c });
            return error.TestUnexpectedResult;
        }
    }
}

fn hostSessionSize(host: *TestHost, id: []const u8) !struct { i64, i64 } {
    var c = try host.client();
    defer c.deinit();
    const list = try net.api.listSessions(&c, t.allocator, .{});
    defer list.deinit();
    for (list.value) |s| if (std.mem.eql(u8, s.id, id)) return .{ s.cols, s.rows };
    return error.NoSuchSession;
}

test "webmux: seq 1 200, then reattach replays it exactly once" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);

    const a = try Sink.create(t.allocator, 80, 24);
    defer a.destroy();
    const ca = try attach(host, a, id);
    try a.waitSnapshots(1, 5000);
    try a.waitText("$ ", 5000);
    ca.input("seq 1 200\r");
    try a.waitText("\n200\n$", 5000);
    {
        const s = try a.text();
        defer t.allocator.free(s);
        try expectSeqOnce(s, 200);
    }
    try t.expectEqual(@as(usize, 1), a.count(.link_up));
    detach(ca);

    // A second terminal attaching later sees the same history.
    const b = try Sink.create(t.allocator, 80, 24);
    defer b.destroy();
    const cb = try attach(host, b, id);
    defer detach(cb);
    try b.waitSnapshots(1, 5000);
    const sa = try a.text();
    defer t.allocator.free(sa);
    const sb = try b.text();
    defer t.allocator.free(sb);
    try expectSeqOnce(sb, 200);
    try t.expectEqualStrings(std.mem.trimEnd(u8, sa, "\n "), std.mem.trimEnd(u8, sb, "\n "));
    try t.expectEqual(a.term.screens.active.cursor.y, b.term.screens.active.cursor.y);
    try t.expectEqual(a.term.screens.active.cursor.x, b.term.screens.active.cursor.x);

    // Input still works on the reattached client.
    cb.input("echo again-$((1+1))\r");
    try b.waitText("again-2", 5000);
}

test "webmux: input queued before the first connect is delivered" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);
    const s = try Sink.create(t.allocator, 80, 24);
    defer s.destroy();
    const c = try Client.create(t.allocator, t.io, s.clientSink(), .{
        .socket_path = host.socket_path,
        .session_id = id,
        .events = s.eventSink(),
    });
    defer detach(c);
    c.input("echo EARLY-$((3*3))\r");
    try c.start();
    try s.waitText("EARLY-9", 5000);
}

test "webmux: resize is reported and follows local resizes" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);

    const s = try Sink.create(t.allocator, 100, 30);
    defer s.destroy();
    const c = try attach(host, s, id);
    defer detach(c);
    try s.waitSnapshots(1, 5000);
    const ev = s.lastEvent(.snapshot_applied);
    try t.expect(ev != null);
    c.input("stty size\r");
    try s.waitText("30 100", 5000);
    try t.expectEqual(.{ @as(i64, 100), @as(i64, 30) }, try hostSessionSize(host, id));

    try s.resize(c, 120, 40);
    c.input("stty size\r");
    try s.waitText("40 120", 5000);
    try t.expectEqual(.{ @as(i64, 120), @as(i64, 40) }, try hostSessionSize(host, id));
}

/// Ground truth for fidelity checks: the host mirror's own view, replayed
/// into a fresh terminal of the same size as the mirror (no resize needed).
fn groundTruth(host: *TestHost, id: []const u8, cols: u16, rows: u16) !*Sink {
    const g = try Sink.create(t.allocator, cols, rows);
    errdefer g.destroy();
    const c = try attach(host, g, id);
    try g.waitSnapshots(1, 5000);
    // Detach before it reports its own size (same size anyway).
    detach(c);
    return g;
}

fn joinRows(s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s, "\n "), '\n');
    while (it.next()) |row| try out.appendSlice(t.allocator, std.mem.trimEnd(u8, row, " "));
    return out.toOwnedSlice(t.allocator);
}

/// Write both states to $WEBMUX_TEST_DUMP (if set) for inspection.
fn dumpDiff(a: []const u8, b: []const u8, ca: anytype, cb: anytype) void {
    var env = t.environ.createMap(t.allocator) catch return;
    defer env.deinit();
    const dir = env.get("WEBMUX_TEST_DUMP") orelse return;
    var n: [2]u8 = undefined;
    _ = &n;
    const pa = std.fmt.allocPrint(t.allocator, "{s}/a-{d}.txt", .{ dir, net.Conn.now() }) catch return;
    defer t.allocator.free(pa);
    const body = std.fmt.allocPrint(t.allocator, "cursor A {any} B {any}\n=== A\n{s}\n=== B\n{s}\n", .{ ca, cb, a, b }) catch return;
    defer t.allocator.free(body);
    std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = pa, .data = body }) catch {};
}

fn sameState(x: *Sink, y: *Sink) !bool {
    const sx = try x.text();
    defer t.allocator.free(sx);
    const sy = try y.text();
    defer t.allocator.free(sy);
    const cx = x.term.screens.active.cursor;
    const cy = y.term.screens.active.cursor;
    // Rows are compared with line breaks removed: the host's snapshot
    // writes soft-wrapped rows as CRLF-separated rows, so lines wrapped
    // before the attach cannot reflow locally (they do in the host's own
    // mirror). Everything else, the cursor included, must match exactly.
    const jx = try joinRows(sx);
    defer t.allocator.free(jx);
    const jy = try joinRows(sy);
    defer t.allocator.free(jy);
    const same = std.mem.eql(u8, jx, jy) and cx.x == cy.x and cx.y == cy.y;
    if (!same) dumpDiff(sx, sy, .{ cx.x, cx.y }, .{ cy.x, cy.y });
    return same;
}

test "webmux: snapshot replay at the remote grid matches the host mirror; at the local grid it does not" {
    const host = try startHost();
    defer host.deinit();

    var results: [2]bool = undefined;
    for ([_]replay.Strategy{ .remote_grid, .local_grid }, 0..) |strategy, i| {
        // Remote 80x24 with 30 lines of output and the prompt at the bottom,
        // plus a line longer than the remote width (wraps at 80).
        const id = try newSession(host, 80, 24);
        defer t.allocator.free(id);
        {
            const w = try Sink.create(t.allocator, 80, 24);
            defer w.destroy();
            const cw = try attach(host, w, id);
            defer detach(cw);
            try w.waitSnapshots(1, 5000);
            cw.input("seq 1 30; printf 'L%.0s' $(seq 1 130); echo\r");
            try w.waitText("LLLL\n$", 5000);
        }

        // Attach a bigger local terminal (100x40).
        const s = try Sink.create(t.allocator, 100, 40);
        defer s.destroy();
        s.strategy = strategy;
        const c = try attach(host, s, id);
        defer detach(c);
        try s.waitSnapshots(1, 5000);
        // Wait until the host has applied our resize.
        var tries: usize = 0;
        while (!std.meta.eql(try hostSessionSize(host, id), .{ @as(i64, 100), @as(i64, 40) })) : (tries += 1) {
            if (tries > 250) return error.Timeout;
            try sleep(20);
        }
        try sleep(100);

        const g = try groundTruth(host, id, 100, 40);
        defer g.destroy();
        results[i] = try sameState(s, g);
    }
    // remote_grid: identical to the host mirror after its resize.
    try t.expect(results[0]);
    // local_grid (the Electron client's way): diverges.
    try t.expect(!results[1]);
}

test "webmux: alternate screen app, modes and Kitty flags survive reattach; stale state does not" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);

    const s = try Sink.create(t.allocator, 80, 24);
    defer s.destroy();
    {
        const c = try attach(host, s, id);
        defer detach(c);
        try s.waitSnapshots(1, 5000);
        c.input("echo PRIMARY-''LINE\r");
        try s.waitText("PRIMARY-LINE\n$", 5000);
        // An "app": alternate screen, focus reporting, mouse tracking, Kitty
        // flags 5, a hyperlink, then wait in cat.
        c.input("printf '\\033[?1049h\\033[H\\033[?1004h\\033[?1000h\\033[>5u\\033]8;;http://x.test/\\033\\\\LINK\\033]8;;\\033\\\\ ALT-''SCREEN'; cat\r");
        try s.waitText("ALT-SCREEN", 5000);
        try t.expect(s.term.screens.active_key == .alternate);
    }

    // Reattach a fresh terminal: everything comes back.
    const r = try Sink.create(t.allocator, 80, 24);
    defer r.destroy();
    {
        const c = try attach(host, r, id);
        defer detach(c);
        try r.waitSnapshots(1, 5000);
        try r.waitText("ALT-SCREEN", 5000);
        try t.expect(r.term.screens.active_key == .alternate);
        try t.expect(r.term.modes.get(.focus_event));
        try t.expect(r.term.modes.get(.mouse_event_normal));
        try t.expectEqual(@as(u5, 5), r.term.screens.active.kitty_keyboard.current().int());
        // The primary screen (and its history) is behind the alt screen.
        r.stream.nextSlice("\x1b[?1049l");
        const p = try r.text();
        defer t.allocator.free(p);
        try t.expect(std.mem.indexOf(u8, p, "PRIMARY-LINE") != null);
        try t.expect(std.mem.indexOf(u8, p, "ALT-SCREEN") == null);
        r.stream.nextSlice("\x1b[?1049h");

        // Leave the app: ^C cat, back to the primary screen, modes off.
        c.input("\x03");
        try sleep(100);
        c.input("printf '\\033[<u\\033[?1000l\\033[?1004l\\033[?1049l'; echo BACK\r");
        try r.waitText("BACK\n$", 5000);
    }

    // `s` still holds the stale alt-screen state from before. Reattaching it
    // (as a reconnect does) must clear all of it and not duplicate history.
    {
        const c = try attach(host, s, id);
        defer detach(c);
        try s.waitSnapshots(2, 5000);
        try s.waitText("BACK", 5000);
        try t.expect(s.term.screens.active_key == .primary);
        try t.expect(!s.term.modes.get(.focus_event));
        try t.expect(!s.term.modes.get(.mouse_event_normal));
        try t.expectEqual(@as(u5, 0), s.term.screens.active.kitty_keyboard.current().int());
        const txt = try s.text();
        defer t.allocator.free(txt);
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, txt, "PRIMARY-LINE\n"));
        try t.expect(std.mem.indexOf(u8, txt, "ALT-SCREEN") == null);
        const g = try groundTruth(host, id, 80, 24);
        defer g.destroy();
        try t.expect(try sameState(s, g));
    }
}

test "webmux: titles, invalid UTF-8 input, session exit" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);

    const s = try Sink.create(t.allocator, 80, 24);
    defer s.destroy();
    const c = try attach(host, s, id);
    defer detach(c);
    try s.waitSnapshots(1, 5000);
    try t.expect(s.count(.title) >= 1); // snapshot title (empty)

    c.input("printf '\\033]2;my-title\\007'\r");
    try s.waitCount(.session_title, 1, 5000);
    try t.expectEqualStrings("my-title", s.lastEvent(.title).?.text);
    try t.expectEqualStrings("my-title", s.lastEvent(.session_title).?.text);

    // A byte that is not UTF-8 arrives as U+FFFD.
    c.input("echo X\xffY | od -An -tx1\r");
    try s.waitText("58 ef bf bd 59", 5000);

    c.input("exit 3\r");
    try s.waitCount(.exit, 1, 5000);
    try t.expectEqual(@as(i64, 3), s.lastEvent(.exit).?.code);
    try s.waitText("[session exited: 3]", 2000);
    // Final: no reconnect attempts follow.
    try sleep(500);
    try t.expectEqual(@as(usize, 0), s.count(.link_down));
    try t.expectEqual(@as(usize, 1), s.count(.link_up));
}

test "webmux: missing session is final" {
    const host = try startHost();
    defer host.deinit();
    const s = try Sink.create(t.allocator, 80, 24);
    defer s.destroy();
    const c = try attach(host, s, "no-such-session");
    defer detach(c);
    try s.waitCount(.session_error, 1, 5000);
    try t.expectEqualStrings("no such session", s.lastEvent(.session_error).?.text);
    try sleep(500);
    try t.expectEqual(@as(usize, 1), s.count(.link_up));
    try t.expectEqual(@as(usize, 0), s.count(.link_down));
}

test "webmux: killed server, then a restarted one: reconnect repaints without duplicates" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);

    const s = try Sink.create(t.allocator, 80, 24);
    defer s.destroy();
    const c = try attach(host, s, id);
    defer detach(c);
    try s.waitSnapshots(1, 5000);
    c.input("seq 1 60\r");
    try s.waitText("\n60\n$", 5000);

    host.stopServer();
    try s.waitCount(.link_down, 1, 5000);
    try s.waitText("[disconnected \u{2014} reconnecting\u{2026}]", 2000);
    // Input while down is dropped, not queued.
    c.input("echo LOST\r");
    // Several failed retries (refused) report link_down only once.
    try sleep(900);
    try t.expectEqual(@as(usize, 1), s.count(.link_down));

    try host.startServer();
    try s.waitSnapshots(2, 5000);
    try s.waitCount(.link_up, 2, 5000);
    const txt = try s.text();
    defer t.allocator.free(txt);
    try expectSeqOnce(txt, 60);
    try t.expect(std.mem.indexOf(u8, txt, "disconnected") == null);
    try t.expect(std.mem.indexOf(u8, txt, "LOST") == null);
    c.input("echo AFTER-$((2*21))\r");
    try s.waitText("AFTER-42", 5000);
}

test "webmux: stop is prompt in every state, repeatedly" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);

    const State = enum { immediately, attached, streaming, reconnecting, refused };
    var worst: [5]i64 = @splat(0);
    var round: usize = 0;
    while (round < 30) : (round += 1) {
        const state: State = @fromBackingInt(@intCast(round % 5));
        const s = try Sink.create(t.allocator, 80, 24);
        defer s.destroy();
        if (state == .refused) host.stopServer();
        const c = try attach(host, s, id);
        switch (state) {
            .immediately => {},
            .attached => try s.waitSnapshots(1, 5000),
            .streaming => {
                try s.waitSnapshots(1, 5000);
                c.input("seq 1 100000\r");
                try sleep(30);
            },
            .reconnecting => {
                try s.waitSnapshots(1, 5000);
                host.stopServer();
                try s.waitCount(.link_down, 1, 5000);
            },
            .refused => try sleep(150),
        }
        const t0 = net.Conn.now();
        c.stop();
        const ms = @divFloor(net.Conn.now() - t0, ns_per_ms);
        c.destroy();
        worst[@backingInt(state)] = @max(worst[@backingInt(state)], ms);
        // Stop interrupts reads, writes and sleeps at once; the only wait is
        // for the frame being parsed to finish (slow in Debug builds while
        // a flood of output streams in).
        const limit: i64 = if (state == .streaming) 1500 else 300;
        if (ms > limit) {
            std.log.err("stop took {d} ms in state {t}", .{ ms, state });
            return error.TestUnexpectedResult;
        }
        if (host.server == null) try host.startServer();
        if (state == .streaming) {
            // Let the burst finish so the next round starts at a prompt.
            const w = try Sink.create(t.allocator, 80, 24);
            defer w.destroy();
            const cw = try attach(host, w, id);
            defer detach(cw);
            try w.waitSnapshots(1, 5000);
            cw.input("clear\r");
            try sleep(200);
        }
    }
}

test "webmux: a 5000-line scrollback snapshot replays whole" {
    const host = try startHost();
    defer host.deinit();
    const id = try newSession(host, 80, 24);
    defer t.allocator.free(id);
    {
        const w = try Sink.create(t.allocator, 80, 24);
        defer w.destroy();
        const c = try attach(host, w, id);
        defer detach(c);
        try w.waitSnapshots(1, 5000);
        c.input("seq 1 6000\r");
        try w.waitText("\n6000\n$", 10_000);
    }
    const s = try Sink.create(t.allocator, 80, 24);
    defer s.destroy();
    const c = try attach(host, s, id);
    defer detach(c);
    try s.waitSnapshots(1, 10_000);
    const txt = try s.text();
    defer t.allocator.free(txt);
    // Every line the host kept is there exactly once, contiguous up to
    // 6000. (As of this writing the host's mirror keeps far fewer than
    // its configured 5000 lines: about 800 rows of `seq` output.)
    var it = std.mem.splitScalar(u8, txt, '\n');
    const first = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, it.next().?, " "), 10);
    try t.expect(first < 6000 - 500);
    var expect = first + 1;
    while (it.next()) |l| {
        const row = std.mem.trimEnd(u8, l, " ");
        if (std.mem.startsWith(u8, row, "$")) break;
        try t.expectEqual(expect, try std.fmt.parseInt(usize, row, 10));
        expect += 1;
    }
    try t.expectEqual(@as(usize, 6001), expect);
    const ev = s.lastEvent(.snapshot_applied);
    try t.expect(ev != null);
}
