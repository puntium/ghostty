//! Control-socket commands of the chrome (see control.zig for the
//! protocol). The UI commands enter at the same functions the widgets'
//! signal handlers call (the headless seat has no pointer device):
//!
//!   conns                       everything: title, front view, entries,
//!                               pills, header buttons, page state, keyring
//!   page   {action, name, field, value}
//!          action = new | edit | cancel | set | submit | connect |
//!                   disconnect | restart | delete | confirm | refuse |
//!                   escape | log
//!   pill   {action: click|pane|close|drag, name, pane | slot | x}
//!          (drag-begin, drag-over {x}, drag-cancel: the steps of a drag)
//!   header {button: new-terminal|new-files|settings|connections}
//!   show   {name?}              userShow (no name: the Connections page)
//!   connect / disconnect {name} straight to the engine (no reveal)
//!   menu   {action: list|activate, label}
//!   sleep-resume                as logind's PrepareForSleep(false)
//!   keyring {action: state|store|lookup|clear, id, password, expect}
//!                               lookup never returns the secret: only its
//!                               length and whether it equals `expect`
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");
const gobject = @import("gobject");
const gdk = @import("gdk");

const control = @import("../control.zig");
const Request = control.Request;
const hub_mod = @import("hub.zig");
const hub = &hub_mod.hub;
const header_mod = @import("header.zig");
const page_mod = @import("page.zig");
const settings_panel = @import("../panels/settings_panel.zig");
const menu = @import("menu.zig");
const keyring = @import("keyring.zig");
const sleep = @import("sleep.zig");

pub fn register() void {
    control.register(.{ .name = "conns", .help = "chrome state: title, front view, connections, pills, header, page, keyring", .handler = &conns });
    control.register(.{ .name = "page", .help = "{action:new|edit|cancel|set|submit|connect|disconnect|restart|delete|confirm|refuse|escape|log, name, field, value}: drive the Connections page (restart and delete ask; confirm and refuse answer)", .handler = &pageCmd });
    control.register(.{ .name = "pill", .help = "{action:click|pane|close|drag, name, pane|slot|x}: a header pill (pane: a click on that pane in its minimap)", .handler = &pillCmd });
    control.register(.{ .name = "header", .help = "{button:new-terminal|new-files|settings|connections}: a header button", .handler = &headerCmd });
    control.register(.{ .name = "show", .help = "{name?}: show a host (as a pill click) or, without a name, the Connections page", .handler = &showCmd });
    control.register(.{ .name = "connect", .help = "{name}: engine connect (no reveal)", .handler = &connectCmd });
    control.register(.{ .name = "disconnect", .help = "{name}: disconnect", .handler = &disconnectCmd });
    control.register(.{ .name = "menu", .help = "{action:list|activate, label}: the header menu's items", .handler = &menuCmd });
    control.register(.{ .name = "sleep-resume", .help = "act as if the system just woke from suspend", .handler = &sleepCmd });
    control.register(.{ .name = "chrome-bounds", .help = "where the chrome's clickable widgets are, in window coordinates ({x,y,w,h} by name: header buttons, pills and their ✕, profile rows and their buttons, form rows and buttons, the landing button), for webmux-dev/realpointer", .handler = &boundsCmd });
    control.register(.{ .name = "keyring", .help = "{action:state|store|lookup|clear, id, password, expect}: the Secret Service store (lookup never returns the secret)", .handler = &keyringCmd });
}

// ---------------------------------------------------------------------------

const EntryDump = struct {
    name: []const u8,
    state: []const u8,
    step: []const u8,
    msg: []const u8,
    stderr: []const u8,
    push_sent: u64,
    push_total: u64,
    retry_delay_s: u32,
    retry_in_s: ?u32,
    socket_path: ?[]const u8,
    panes: usize,
    offline: bool,
    reveal: bool,
    view: []const u8,
    front: bool,
};

const PillDump = struct {
    name: []const u8,
    /// The state class (W-12): unknown, connecting, connected, degraded,
    /// retry, failed. Colours the pill (deviation 73).
    state: []const u8,
    active: bool,
    dragging: bool,
    drop: ?[]const u8,
    tooltip: []const u8,
    mid_x: ?f64,
    minimap: MinimapDump,
};

/// The pill's minimap: pane ids in map order, the focused one, whether
/// the viewport outline shows, and the map's size (0×0 while hidden).
const MinimapDump = struct {
    shown: bool,
    panes: []const []const u8,
    focused: ?[]const u8,
    viewport: bool,
    w: f64,
    h: f64,
};

const CardDump = struct {
    name: []const u8,
    state_label: []const u8,
    detail: []const u8,
    buttons: []const []const u8,
    /// N8: what a live connection is on while an edit waits, else null.
    live: ?[]const u8,
};

fn labelText(a: std.mem.Allocator, l: *gtk.Label) []const u8 {
    return a.dupe(u8, std.mem.span(l.getText())) catch "";
}

fn conns(req: *Request) void {
    connsInner(req) catch |err| req.fail("conns failed: {t}", .{err});
}

fn connsInner(req: *Request) !void {
    const a = req.allocator();
    var title_buf: [128]u8 = undefined;
    var entries: std.ArrayList(EntryDump) = .empty;
    for (hub.entries.items) |e| {
        const st = e.status;
        try entries.append(a, .{
            .name = e.name,
            .state = e.stateName(),
            .step = if (st) |s| @tagName(s.step) else "idle",
            .msg = if (st) |s| s.msg else "",
            .stderr = if (st) |s| s.stderr else "",
            .push_sent = if (st) |s| s.push_sent else 0,
            .push_total = if (st) |s| s.push_total else 0,
            .retry_delay_s = if (st) |s| s.retry_delay_s else 0,
            .retry_in_s = hub_mod.retrySeconds(e),
            .socket_path = if (st) |s| s.socket_path else null,
            .panes = e.panes,
            .offline = e.offline,
            .reveal = e.reveal,
            .view = e.view.kind(),
            .front = hub.active == e,
        });
    }

    var pills: std.ArrayList(PillDump) = .empty;
    var hdr: ?struct {
        connections_active: bool,
        new_terminal_enabled: bool,
        new_files_enabled: bool,
        settings_enabled: bool,
        pills: []PillDump,
    } = null;
    if (hub.header) |h| {
        for (h.pills.items) |p| {
            const w = p.root.as(gtk.Widget);
            const tip = w.getTooltipText();
            const m = p.map.map();
            var ids: std.ArrayList([]const u8) = .empty;
            var focused: ?[]const u8 = null;
            for (m.cells) |c| {
                try ids.append(a, try a.dupe(u8, c.id));
                if (c.focused) focused = ids.items[ids.items.len - 1];
            }
            try pills.append(a, .{
                .name = labelText(a, p.label),
                .state = p.state_class,
                .minimap = .{
                    .shown = p.map.as(gtk.Widget).getVisible() != 0,
                    .panes = ids.items,
                    .focused = focused,
                    .viewport = m.viewport != null,
                    .w = m.width,
                    .h = m.height,
                },
                .active = w.hasCssClass("active") != 0,
                .dragging = w.hasCssClass("dragging") != 0,
                .drop = if (w.hasCssClass("drop-before") != 0) "before" else if (w.hasCssClass("drop-after") != 0) "after" else null,
                .tooltip = if (tip) |t| try a.dupe(u8, std.mem.span(t)) else "",
                .mid_x = h.pillMid(p),
            });
        }
        hdr = .{
            .connections_active = h.connections.as(gtk.Widget).hasCssClass("active") != 0,
            .new_terminal_enabled = h.new_term.as(gtk.Widget).getSensitive() != 0,
            .new_files_enabled = h.new_files.as(gtk.Widget).getSensitive() != 0,
            .settings_enabled = h.settings.as(gtk.Widget).getSensitive() != 0,
            .pills = pills.items,
        };
    }

    var page: ?struct {
        /// The dialog is up (on any of its pages).
        open: bool,
        mode: []const u8,
        empty: bool,
        cards: []CardDump,
        status_text: []const []const u8,
        form: ?struct {
            editing: []const u8,
            error_text: []const u8,
            submit: []const u8,
            has_clear: bool,
            password_title: []const u8,
            busy: bool,
            /// What the fields hold (the password only as its length).
            fields: struct { name: []const u8, host: []const u8, ssh_port: []const u8, identity_file: []const u8, instance: []const u8, extra_options: []const u8, password_len: usize },
        },
        /// The profile a confirmation is open for.
        confirm: ?[]const u8,
        /// Every wrapping label of the status area is set through
        /// hyphen-free markup (no '-' drawn that is not in the text).
        status_hyphen_free: bool,
    } = null;
    if (hub.page) |p| {
        var cards: std.ArrayList(CardDump) = .empty;
        for (p.cards.items) |c| {
            var btns: std.ArrayList([]const u8) = .empty;
            var child = c.buttons.as(gtk.Widget).getFirstChild();
            while (child) |w| : (child = w.getNextSibling()) {
                if (gobject.ext.cast(gtk.Button, w)) |b| try btns.append(a, try a.dupe(u8, std.mem.span(b.getLabel() orelse "")));
            }
            try cards.append(a, .{
                .name = c.name,
                .state_label = if (c.state_label.as(gtk.Widget).getVisible() != 0) labelText(a, c.state_label) else "",
                .detail = c.detail,
                .buttons = btns.items,
                .live = c.live,
            });
        }
        var texts: std.ArrayList([]const u8) = .empty;
        try collectLabels(a, p.status.as(gtk.Widget), &texts);
        page = .{
            .open = settings_panel.isOpen(),
            .mode = if (p.form != null) "form" else "list",
            .empty = p.empty_row != null,
            .cards = cards.items,
            .status_text = texts.items,
            .form = if (p.form) |f| .{
                .editing = f.editing,
                .error_text = labelText(a, f.err),
                .submit = try a.dupe(u8, std.mem.span(f.submit.getLabel() orelse "")),
                .has_clear = f.clear != null,
                .password_title = try a.dupe(u8, std.mem.span(f.password.as(adw.PreferencesRow).getTitle())),
                .fields = .{
                    .name = try entryText(a, f.name),
                    .host = try entryText(a, f.host),
                    .ssh_port = try entryText(a, f.ssh_port),
                    .identity_file = try entryText(a, f.identity),
                    .instance = try entryText(a, f.instance),
                    .extra_options = try entryText(a, f.extra),
                    .password_len = std.unicode.utf8CountCodepoints(std.mem.span(f.password.as(gtk.Editable).getText())) catch 0,
                },
                .busy = f.busy,
            } else null,
            .confirm = p.confirm_name,
            .status_hyphen_free = hyphenFree(p.status.as(gtk.Widget)),
        };
    }

    req.ok(.{
        .title = try a.dupe(u8, hub_mod.titleText(&title_buf)),
        .front = if (hub.active) |e| e.name else null,
        .engine = hub.engine != null,
        .entries = entries.items,
        .header = hdr,
        .page = page,
        .keyring = .{ .service = @tagName(keyring.serviceState()) },
        .config_problem = if (hub.engine) |e| e.configProblem() else null,
        // Keyboard focus: the focus widget's CSS name (null: nothing has
        // focus), "popover:" in front while it is inside a popover.
        .focus = focusName(a),
        .config_banner = if (hub.page) |p| p.config_banner != null else false,
    });
}

fn collectLabels(a: std.mem.Allocator, w: *gtk.Widget, out: *std.ArrayList([]const u8)) !void {
    if (gobject.ext.cast(gtk.Label, w)) |l| {
        const t = std.mem.span(l.getText());
        if (t.len > 0) try out.append(a, try a.dupe(u8, t));
        return;
    }
    var child = w.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) try collectLabels(a, c, out);
}

// ---------------------------------------------------------------------------

fn pageCmd(req: *Request) void {
    const p = hub.page orelse return req.fail("no connection page", .{});
    const action = req.string("action") orelse return req.fail("action required", .{});
    const name = req.string("name") orelse "";
    const eq = std.mem.eql;
    if (eq(u8, action, "new")) {
        p.clickNew();
    } else if (eq(u8, action, "edit")) {
        p.clickEdit(name);
    } else if (eq(u8, action, "cancel")) {
        p.closeForm();
    } else if (eq(u8, action, "set")) {
        const field = req.string("field") orelse return req.fail("field required", .{});
        const value = req.string("value") orelse "";
        if (!p.setField(field, value)) return req.fail("no form, or unknown field {s}", .{field});
    } else if (eq(u8, action, "submit")) {
        p.submit();
    } else if (eq(u8, action, "connect")) {
        p.clickConnect(name);
    } else if (eq(u8, action, "disconnect")) {
        p.clickDisconnect(name);
    } else if (eq(u8, action, "restart")) {
        p.clickRestart(name);
    } else if (eq(u8, action, "delete")) {
        p.clickDelete(name);
    } else if (eq(u8, action, "confirm") or eq(u8, action, "refuse")) {
        if (!p.answer(eq(u8, action, "confirm"))) return req.fail("nothing to answer", .{});
    } else if (eq(u8, action, "escape")) {
        return req.ok(.{ .consumed = p.escape() });
    } else if (eq(u8, action, "log")) {
        p.clickLog();
    } else return req.fail("unknown action {s}", .{action});
    req.ok(.{ .done = true });
}

fn pillCmd(req: *Request) void {
    const h = hub.header orelse return req.fail("no header", .{});
    const action = req.string("action") orelse return req.fail("action required", .{});
    const name = req.string("name") orelse return req.fail("name required", .{});
    const e = hub_mod.find(name) orelse return req.fail("no connection {s}", .{name});
    const eq = std.mem.eql;
    if (eq(u8, action, "click")) {
        h.clickPill(e.id);
    } else if (eq(u8, action, "pane")) {
        // A click on a pane in the pill's minimap.
        const pane = req.string("pane") orelse return req.fail("pane required", .{});
        h.clickPillPane(e.id, pane);
    } else if (eq(u8, action, "close")) {
        h.clickPillX(e.id);
    } else if (eq(u8, action, "drag-begin")) {
        h.beginDrag(e.id);
    } else if (eq(u8, action, "drag-over")) {
        const x: f64 = if (req.get("x")) |v| switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => return req.fail("x must be a number", .{}),
        } else return req.fail("x required", .{});
        h.dragOver(x);
        return req.ok(.{ .slot = h.drop_slot });
    } else if (eq(u8, action, "drag-cancel")) {
        h.endDrag();
    } else if (eq(u8, action, "drag")) {
        // Pointer x in pills-box coordinates: given, or just right of the
        // midpoint of the pill before `slot` among the others.
        const x: f64 = if (req.get("x")) |v| switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => return req.fail("x must be a number", .{}),
        } else blk: {
            const slot: usize = @intCast(req.int("slot") orelse return req.fail("slot or x required", .{}));
            if (slot == 0) break :blk 0;
            var k: usize = 0;
            for (h.pills.items) |p| {
                if (p.entry_id == e.id) continue;
                k += 1;
                if (k == slot) break :blk (h.pillMid(p) orelse 0) + 1;
            }
            break :blk 100000;
        };
        h.beginDrag(e.id);
        h.dragOver(x);
        const marks = struct { slot: ?usize }{ .slot = h.drop_slot };
        h.drop(x);
        return req.ok(.{ .x = x, .slot = marks.slot });
    } else return req.fail("unknown action {s}", .{action});
    req.ok(.{ .done = true });
}

fn headerCmd(req: *Request) void {
    const h = hub.header orelse return req.fail("no header", .{});
    const b = req.string("button") orelse return req.fail("button required", .{});
    const eq = std.mem.eql;
    if (eq(u8, b, "new-terminal")) h.clickNewTerminal() else if (eq(u8, b, "new-files")) h.clickNewFiles() else if (eq(u8, b, "settings")) h.clickSettings() else if (eq(u8, b, "connections")) h.clickConnections() else return req.fail("unknown button {s}", .{b});
    req.ok(.{ .done = true });
}

fn showCmd(req: *Request) void {
    if (req.string("name")) |name| {
        const e = hub_mod.find(name) orelse return req.fail("no connection {s}", .{name});
        hub_mod.userShow(e);
    } else hub_mod.userShow(null);
    req.ok(.{ .front = if (hub.active) |e| e.name else null });
}

fn connectCmd(req: *Request) void {
    const engine = hub.engine orelse return req.fail("no engine", .{});
    const name = req.string("name") orelse return req.fail("name required", .{});
    if (engine.connect(name)) |err| return req.fail("{s}", .{err});
    hub_mod.refresh();
    req.ok(.{ .done = true });
}

fn disconnectCmd(req: *Request) void {
    const name = req.string("name") orelse return req.fail("name required", .{});
    hub_mod.disconnect(name);
    req.ok(.{ .done = true });
}

fn menuCmd(req: *Request) void {
    const action = req.string("action") orelse "list";
    const items = menu.listItems(req.allocator()) catch return req.fail("out of memory", .{});
    if (std.mem.eql(u8, action, "list")) return req.ok(items);
    const label = req.string("label") orelse return req.fail("label required", .{});
    for (items) |it| {
        if (!std.mem.eql(u8, it.label, label)) continue;
        if (!menu.activateItem(it.action, it.target)) return req.fail("{s}: action {s} is not registered", .{ label, it.action });
        return req.ok(.{ .activated = it.action, .target = it.target });
    }
    req.fail("no menu item {s}", .{label});
}

fn sleepCmd(req: *Request) void {
    sleep.resumed();
    req.ok(.{ .done = true });
}

// ---------------------------------------------------------------------------

var pending_keyring: ?*Request = null;

fn keyringCmd(req: *Request) void {
    const action = req.string("action") orelse "state";
    const eq = std.mem.eql;
    if (eq(u8, action, "state")) {
        const id = req.string("id");
        return req.ok(.{ .service = @tagName(keyring.serviceState()), .has = if (id) |i| keyring.has(i) else null });
    }
    const id = req.string("id") orelse return req.fail("id required", .{});
    if (eq(u8, action, "store")) {
        if (pending_keyring != null) return req.fail("another keyring request is running", .{});
        pending_keyring = req;
        keyring.storeAsync(id, id, req.string("password") orelse "", 0, onKeyringDone);
        return;
    }
    if (eq(u8, action, "clear")) {
        if (pending_keyring != null) return req.fail("another keyring request is running", .{});
        pending_keyring = req;
        keyring.clearAsync(id, 0, onKeyringDone);
        return;
    }
    if (eq(u8, action, "lookup")) {
        if (pending_keyring != null) return req.fail("another keyring request is running", .{});
        pending_keyring = req;
        const Job = struct {
            id: []u8,
            expect: ?[]u8,
            fn run(j: *@This()) void {
                var buf: [1024]u8 = undefined;
                defer std.crypto.secureZero(u8, &buf);
                const r = keyring.lookup(j.id, &buf);
                const Res = struct {
                    kind: []const u8,
                    len: usize = 0,
                    matches: ?bool = null,
                    why: ?[]const u8 = null,
                };
                const res: Res = switch (r) {
                    .none => .{ .kind = "none" },
                    .found => |n| .{ .kind = "found", .len = n, .matches = if (j.expect) |e| std.mem.eql(u8, e, buf[0..n]) else null },
                    .unavailable => |w| .{ .kind = "unavailable", .why = w },
                };
                const Post = struct {
                    res: Res,
                    fn run(p: *@This()) void {
                        const rq = pending_keyring orelse return;
                        pending_keyring = null;
                        rq.ok(p.res);
                    }
                };
                @import("../mainloop.zig").post(Post{ .res = res }, Post.run);
                std.heap.c_allocator.free(j.id);
                if (j.expect) |e| {
                    std.crypto.secureZero(u8, e);
                    std.heap.c_allocator.free(e);
                }
            }
        };
        const a = std.heap.c_allocator;
        const job: Job = .{
            .id = a.dupe(u8, id) catch return req.fail("oom", .{}),
            .expect = if (req.string("expect")) |e| a.dupe(u8, e) catch null else null,
        };
        const t = std.Thread.spawn(.{}, struct {
            fn f(j: Job) void {
                var jj = j;
                Job.run(&jj);
            }
        }.f, .{job}) catch return req.fail("cannot spawn", .{});
        t.detach();
        return;
    }
    req.fail("unknown action {s}", .{action});
}

fn onKeyringDone(r: keyring.Done) void {
    const rq = pending_keyring orelse return;
    pending_keyring = null;
    if (r.err) |e| return rq.fail("{s}", .{e});
    rq.ok(.{ .done = true });
}

comptime {
    _ = header_mod;
    _ = page_mod;
}

// ---------------------------------------------------------------------------

const Box = struct { name: []const u8, x: f64, y: f64, w: f64, h: f64, visible: bool };

fn addBox(a: std.mem.Allocator, out: *std.ArrayList(Box), win: *gtk.Widget, w: *gtk.Widget, name: []const u8) void {
    var r: @import("graphene").Rect = undefined;
    var ox: f64 = 0;
    var oy: f64 = 0;
    const native = w.getNative() orelse return;
    const native_w = native.as(gtk.Widget);
    if (native_w == win) {
        if (w.computeBounds(win, &r) == 0) return;
    } else {
        // In a popover (its own surface): bounds in the popover, plus the
        // popup's place relative to the window's surface, minus the
        // shadow margins of both surfaces.
        if (w.computeBounds(native_w, &r) == 0) return;
        const surf = native.getSurface() orelse return;
        const popup = gobject.ext.cast(gdk.Popup, surf) orelse return;
        var px: f64 = 0;
        var py: f64 = 0;
        native.getSurfaceTransform(&px, &py);
        var wx: f64 = 0;
        var wy: f64 = 0;
        (gobject.ext.cast(gtk.Native, win) orelse return).getSurfaceTransform(&wx, &wy);
        ox = @as(f64, @floatFromInt(popup.getPositionX())) + px - wx;
        oy = @as(f64, @floatFromInt(popup.getPositionY())) + py - wy;
    }
    out.append(a, .{
        .name = a.dupe(u8, name) catch return,
        .x = r.f_origin.f_x + ox,
        .y = r.f_origin.f_y + oy,
        .w = r.f_size.f_width,
        .h = r.f_size.f_height,
        .visible = w.isDrawable() != 0,
    }) catch {};
}

fn boundsCmd(req: *Request) void {
    const a = req.allocator();
    const win = (hub.window orelse return req.fail("no window", .{})).as(gtk.Widget);
    var out: std.ArrayList(Box) = .empty;
    if (hub.header) |h| {
        addBox(a, &out, win, h.new_term.as(gtk.Widget), "header.new-terminal");
        addBox(a, &out, win, h.new_files.as(gtk.Widget), "header.new-files");
        addBox(a, &out, win, h.settings.as(gtk.Widget), "header.settings");
        addBox(a, &out, win, h.connections.as(gtk.Widget), "header.connections");
        addBox(a, &out, win, h.menu_button.as(gtk.Widget), "header.menu");
        for (h.pills.items) |p| {
            const e = hub_mod.findId(p.entry_id) orelse continue;
            addBox(a, &out, win, p.root.as(gtk.Widget), std.fmt.allocPrint(a, "pill.{s}", .{e.name}) catch continue);
            addBox(a, &out, win, p.x.as(gtk.Widget), std.fmt.allocPrint(a, "pill.{s}.x", .{e.name}) catch continue);
            // The minimap and each of its pane cells (`pill.<name>.map.<i>`,
            // in map order), for a real click on a pane.
            const mw = p.map.as(gtk.Widget);
            if (mw.getVisible() != 0) {
                addBox(a, &out, win, mw, std.fmt.allocPrint(a, "pill.{s}.map", .{e.name}) catch continue);
                const before = out.items.len;
                if (before > 0 and std.mem.endsWith(u8, out.items[before - 1].name, ".map")) {
                    const mb = out.items[before - 1];
                    for (p.map.map().cells, 0..) |c, i| {
                        out.append(a, .{
                            .name = std.fmt.allocPrint(a, "pill.{s}.map.{d}", .{ e.name, i }) catch continue,
                            .x = mb.x + c.rect.x,
                            .y = mb.y + c.rect.y,
                            .w = c.rect.w,
                            .h = c.rect.h,
                            .visible = true,
                        }) catch continue;
                    }
                }
            }
        }
    }
    if (hub.page) |p| {
        addBox(a, &out, win, p.landing_btn.as(gtk.Widget), "landing.open");
        addBox(a, &out, win, p.log_btn.as(gtk.Widget), "page.log");
        addBox(a, &out, win, p.new_btn.as(gtk.Widget), "page.new");
        for (p.cards.items) |c| {
            addBox(a, &out, win, c.root.as(gtk.Widget), std.fmt.allocPrint(a, "card.{s}", .{c.name}) catch continue);
            var child = c.buttons.as(gtk.Widget).getFirstChild();
            while (child) |w| : (child = w.getNextSibling()) {
                const b = gobject.ext.cast(gtk.Button, w) orelse continue;
                const label = std.mem.span(b.getLabel() orelse "");
                addBox(a, &out, win, w, std.fmt.allocPrint(a, "card.{s}.{s}", .{ c.name, label }) catch continue);
            }
        }
        if (p.form) |f| {
            addBox(a, &out, win, f.name.as(gtk.Widget), "form.name");
            addBox(a, &out, win, f.host.as(gtk.Widget), "form.host");
            addBox(a, &out, win, f.ssh_port.as(gtk.Widget), "form.ssh_port");
            addBox(a, &out, win, f.password.as(gtk.Widget), "form.password");
            if (f.clear) |c| addBox(a, &out, win, c.as(gtk.Widget), "form.clear");
            addBox(a, &out, win, f.advanced.as(gtk.Widget), "form.advanced");
            addBox(a, &out, win, f.instance.as(gtk.Widget), "form.instance");
            addBox(a, &out, win, f.submit.as(gtk.Widget), "form.submit");
            addBox(a, &out, win, f.cancel.as(gtk.Widget), "form.cancel");
            if (f.restart) |b| addBox(a, &out, win, b.as(gtk.Widget), "form.restart");
            if (f.delete) |b| addBox(a, &out, win, b.as(gtk.Widget), "form.delete");
        }
    }
    req.ok(out.items);
}

fn focusName(a: std.mem.Allocator) ?[]const u8 {
    const win = (hub.window orelse return null).as(gtk.Window);
    const f = win.getFocus() orelse return null;
    const name = std.mem.span(f.getCssName());
    const in_pop = @import("../ext.zig").getAncestor(gtk.Popover, f) != null;
    return std.fmt.allocPrint(a, "{s}{s}", .{ if (in_pop) "popover:" else "", name }) catch null;
}

fn entryText(a: std.mem.Allocator, e: *adw.EntryRow) ![]const u8 {
    return a.dupe(u8, std.mem.span(e.as(gtk.Editable).getText()));
}

fn hyphenFree(w: *gtk.Widget) bool {
    if (gobject.ext.cast(gtk.Label, w)) |l| {
        if (l.getWrap() == 0) return true;
        return std.mem.startsWith(u8, std.mem.span(l.getLabel()), "<span insert_hyphens=\"false\">");
    }
    var child = w.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) if (!hyphenFree(c)) return false;
    return true;
}
