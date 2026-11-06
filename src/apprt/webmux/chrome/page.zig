//! The Connections page of the preferences dialog (deviation 67), and the
//! landing view the window shows when no host is in front.
//!
//! One row per profile with its live state and Connect / Show / Disconnect
//! / Cancel; a click on a row opens the profile form as a subpage, which
//! also has Restart Sessions and Delete Profile. Below the rows: notices,
//! per-connection status detail (deploy progress, retry countdown, ssh's
//! stderr) and the help text.
//!
//! Rows are updated in place on status pushes; the list is rebuilt only
//! when the profiles change. Status pushes never touch an open form (W-29).
const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gtk = @import("gtk");

const conn = @import("../../../webmux/conn.zig");
const iface = @import("../iface.zig");
const hub = @import("hub.zig");
const keyring = @import("keyring.zig");
const menu = @import("menu.zig");
const header = @import("header.zig");
const text_mod = @import("text.zig");
const profile_mod = @import("../../../webmux/conn/profile.zig");
const settings_panel = @import("../panels/settings_panel.zig");

const alloc = std.heap.c_allocator;

pub const HINT =
    "A host needs nothing but ssh: connecting pushes the webmux server (one small static binary) to " ++
    "<tt>~/.webmux/dist</tt> on the host and starts it — updates are pushed the same way, and sessions " ++
    "survive them. Connect to several hosts at once — each connection gets a pill in the header bar " ++
    "(Ctrl+1…9 or Ctrl+PageUp/PageDown switch, Ctrl+Shift+O opens this page). Key auth needs no prompt (use " ++
    "ssh-agent for passphrases); or save a password per profile — it is stored in the system keyring " ++
    "(GNOME Keyring or KWallet, via the Secret Service) and fed to ssh through an askpass helper. " ++
    "Ctrl+Shift+R reconnects the current host.";

const Card = struct {
    name: []u8,
    root: *adw.ActionRow,
    dot: *gtk.Widget,
    dot_class: [:0]const u8 = "none",
    state_label: *gtk.Label,
    /// `<host>[ -p <port>][ → <instance>]`, the row's subtitle.
    detail: [:0]u8,
    /// "on …; Reconnect to use the edit", the subtitle's second line.
    live: ?[]u8 = null,
    /// The stored profile's host, instance (or "default"), port.
    host: []u8,
    instance: []u8,
    ssh_port: u32,
    buttons: *gtk.Box,
    /// Which button set is showing (rebuilt only when it changes).
    mode: enum { none, up, busy, idle } = .none,
};

pub const Form = struct {
    /// Original name of the profile being edited; "" for a new one.
    editing: []u8,
    page: *adw.NavigationPage,
    name: *adw.EntryRow,
    host: *adw.EntryRow,
    ssh_port: *adw.EntryRow,
    identity: *adw.EntryRow,
    password: *adw.EntryRow,
    clear: ?*adw.SwitchRow,
    instance: *adw.EntryRow,
    extra: *adw.EntryRow,
    advanced: *adw.ExpanderRow,
    submit: *gtk.Button,
    cancel: *gtk.Button,
    err: *gtk.Label,
    restart: ?*adw.ButtonRow,
    delete: ?*adw.ButtonRow,
    /// Where focus was when the dialog closed over the form (borrowed: a
    /// widget of the dialog, which outlives the form).
    back: ?*gtk.Widget = null,
    busy: bool = false,
};

const Confirm = enum { restart, delete };

pub const Page = struct {
    landing: *adw.StatusPage,
    landing_btn: *gtk.Button,
    prefs: *adw.PreferencesPage,
    problems: *adw.PreferencesGroup,
    list: *adw.PreferencesGroup,
    status_group: *adw.PreferencesGroup,
    status: *gtk.Box,
    log_btn: *gtk.Button,
    new_btn: *gtk.Button,

    cards: std.ArrayList(*Card) = .empty,
    empty_row: ?*adw.ActionRow = null,
    form: ?*Form = null,
    /// The open confirmation, what it is for, and for which profile.
    confirm: ?*adw.AlertDialog = null,
    confirm_kind: Confirm = .restart,
    confirm_name: ?[]u8 = null,
    notice: ?[:0]u8 = null,
    notice_source: c_uint = 0,
    form_tag: u64 = 0,
    /// The input of a save waiting for the keyring (owned by `pending`).
    pending: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    pending_input: ?conn.ProfileInput = null,
    /// The config problem banner (engine.configProblem), if any.
    config_banner: ?*gtk.Label = null,
    alive: bool = true,

    /// The view in the window's stack.
    pub fn widget(p: *Page) *gtk.Widget {
        return p.landing.as(gtk.Widget);
    }

    pub fn create() *Page {
        const p = alloc.create(Page) catch @panic("OOM");

        const landing = adw.StatusPage.new();
        landing.setTitle("webmux");
        landing.setDescription("No host is open.");
        landing.as(gtk.Widget).setFocusable(1);
        const landing_btn = gtk.Button.newWithLabel("Connections…");
        landing_btn.as(gtk.Widget).addCssClass("pill");
        landing_btn.as(gtk.Widget).addCssClass("suggested-action");
        landing_btn.as(gtk.Widget).setHalign(.center);
        landing.setChild(landing_btn.as(gtk.Widget));

        const prefs = adw.PreferencesPage.new();
        prefs.setTitle("Connections");
        prefs.setIconName("network-server-symbolic");

        const problems = adw.PreferencesGroup.new();
        problems.as(gtk.Widget).setVisible(0);
        prefs.add(problems);

        const list = adw.PreferencesGroup.new();
        list.setTitle("Profiles");
        const actions = gtk.Box.new(.horizontal, 6);
        const log_btn = gtk.Button.newWithLabel("Log");
        log_btn.as(gtk.Widget).setTooltipText("Connection log (Ctrl+Shift+G)");
        const new_btn = gtk.Button.newWithLabel("New Profile");
        new_btn.as(gtk.Widget).addCssClass("suggested-action");
        actions.append(log_btn.as(gtk.Widget));
        actions.append(new_btn.as(gtk.Widget));
        list.setHeaderSuffix(actions.as(gtk.Widget));
        prefs.add(list);

        const status_group = adw.PreferencesGroup.new();
        const status = gtk.Box.new(.vertical, 6);
        status_group.add(status.as(gtk.Widget));
        prefs.add(status_group);

        const help = adw.PreferencesGroup.new();
        const hint = gtk.Label.new(null);
        text_mod.setMarkup(hint, HINT);
        hint.setWrap(1);
        hint.setWrapMode(.word_char);
        hint.setXalign(0);
        hint.as(gtk.Widget).addCssClass("dim-label");
        hint.as(gtk.Widget).addCssClass("caption");
        help.add(hint.as(gtk.Widget));
        prefs.add(help);

        p.* = .{
            .landing = landing,
            .landing_btn = landing_btn,
            .prefs = prefs,
            .problems = problems,
            .list = list,
            .status_group = status_group,
            .status = status,
            .log_btn = log_btn,
            .new_btn = new_btn,
        };
        _ = gtk.Button.signals.clicked.connect(landing_btn, *Page, onLanding, p, .{});
        _ = gtk.Button.signals.clicked.connect(log_btn, *Page, onLog, p, .{});
        _ = gtk.Button.signals.clicked.connect(new_btn, *Page, onNew, p, .{});

        // Connections goes first, then General.
        settings_panel.dialog().add(prefs);
        _ = settings_panel.ensure();
        settings_panel.on_closing = onDialogClosing;
        settings_panel.on_closed = onDialogClosed;

        p.rebuildList();
        p.update();
        return p;
    }

    pub fn destroyed(p: *Page) void {
        p.alive = false;
        if (p.notice_source != 0) _ = glib.Source.remove(p.notice_source);
        p.notice_source = 0;
        settings_panel.on_closing = null;
        settings_panel.on_closed = null;
        settings_panel.reset();
        for (p.cards.items) |c| freeCard(c);
        p.cards.deinit(alloc);
        if (p.form) |f| freeForm(f);
        freeOpt(&p.confirm_name);
        if (p.notice) |n| alloc.free(n);
        p.pending.deinit();
        alloc.destroy(p);
    }

    /// Show the dialog on this page. An open form stays as it was.
    pub fn present(p: *Page) void {
        const win = hub.hub.window orelse return;
        const was_open = settings_panel.isOpen();
        settings_panel.dialog().setVisiblePage(p.prefs);
        settings_panel.present(win.as(gtk.Widget));
        if (was_open) return;
        // Back to the field the user was in, as it was.
        if (p.form) |f| {
            _ = hub.refocus(f.back orelse f.name.as(gtk.Widget));
            f.back = null;
        }
    }

    /// Keyboard focus for the landing view.
    pub fn focus(p: *Page) void {
        _ = p.landing.as(gtk.Widget).grabFocus();
    }

    fn onDialogClosing() void {
        const p = hub.hub.page orelse return;
        if (p.form) |f| f.back = settings_panel.dialog().as(adw.Dialog).getFocus();
    }

    fn onDialogClosed() void {
        hub.focusContent();
    }

    fn addProblem(p: *Page, text: []const u8) *gtk.Label {
        const l = gtk.Label.new(null);
        text_mod.set(l, text);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.setXalign(0);
        l.setSelectable(1);
        l.as(gtk.Widget).addCssClass("error");
        p.problems.add(l.as(gtk.Widget));
        p.problems.as(gtk.Widget).setVisible(1);
        return l;
    }

    pub fn showEngineError(p: *Page, msg: []const u8) void {
        var buf: [512]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "The connection engine failed to start: {s}. See the application log.", .{msg}) catch "The connection engine failed to start.";
        _ = p.addProblem(t);
    }

    /// config.json could not be loaded (engine.configProblem): say so above
    /// the list, for as long as the app runs.
    pub fn showConfigProblem(p: *Page, msg: []const u8) void {
        if (p.config_banner != null) return;
        const t = std.fmt.allocPrint(alloc, "{s}. Fix or restore the file and restart to get the old profiles back; the connection log has the details.", .{msg}) catch "config.json could not be read; see the connection log.";
        p.config_banner = p.addProblem(t);
    }

    // -- top buttons ------------------------------------------------------

    pub fn clickLog(_: *Page) void {
        menu.activateApp(iface.actions.show_log);
    }

    pub fn clickNew(p: *Page) void {
        p.openForm("");
    }

    fn onLanding(_: *gtk.Button, _: *Page) callconv(.c) void {
        hub.userShow(null);
    }
    fn onLog(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.clickLog();
    }
    fn onNew(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.clickNew();
    }

    /// Escape, for the control socket: cancel the form (W-28).
    pub fn escape(p: *Page) bool {
        if (p.form == null) return false;
        p.closeForm();
        return true;
    }

    // -- the list -----------------------------------------------------------

    /// The profiles changed: rebuild the rows.
    pub fn rebuildList(p: *Page) void {
        for (p.cards.items) |c| {
            p.list.remove(c.root.as(gtk.Widget));
            freeCard(c);
        }
        p.cards.clearRetainingCapacity();
        if (p.empty_row) |r| p.list.remove(r.as(gtk.Widget));
        p.empty_row = null;

        const engine = hub.hub.engine orelse return;
        var profiles = engine.listProfiles(alloc) catch return;
        defer profiles.deinit();
        if (profiles.profiles.len == 0) {
            const r = adw.ActionRow.new();
            r.as(adw.PreferencesRow).setTitle("No profiles yet — create one to connect.");
            p.list.add(r.as(gtk.Widget));
            p.empty_row = r;
        }
        for (profiles.profiles) |prof| {
            const c = newCard(prof) catch continue;
            p.cards.append(alloc, c) catch continue;
            p.list.add(c.root.as(gtk.Widget));
        }
        p.update();
    }

    fn newCard(prof: conn.Profile) !*Card {
        const c = try alloc.create(Card);
        const row = adw.ActionRow.new();
        // Profile names and hosts are text, not markup.
        row.as(adw.PreferencesRow).setUseMarkup(0);
        var nb: [4096]u8 = undefined;
        row.as(adw.PreferencesRow).setTitle(cz(&nb, prof.name).ptr);
        row.as(gtk.Widget).setTooltipText(cz(&nb, prof.name).ptr);
        // Long names and hosts never widen the window (N3).
        row.setTitleLines(1);
        row.setSubtitleLines(2);
        row.as(gtk.ListBoxRow).setActivatable(1);

        const dot = gtk.Box.new(.horizontal, 0);
        dot.as(gtk.Widget).addCssClass("wm-dot");
        dot.as(gtk.Widget).setValign(.center);
        row.addPrefix(dot.as(gtk.Widget));

        const state_label = gtk.Label.new(null);
        state_label.as(gtk.Widget).addCssClass("dim-label");
        state_label.as(gtk.Widget).addCssClass("caption");
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.as(gtk.Widget).setValign(.center);
        row.addSuffix(state_label.as(gtk.Widget));
        row.addSuffix(buttons.as(gtk.Widget));
        row.addSuffix(gtk.Image.newFromIconName("go-next-symbolic").as(gtk.Widget));

        var db: [600]u8 = undefined;
        c.* = .{
            .name = try alloc.dupe(u8, prof.name),
            .root = row,
            .dot = dot.as(gtk.Widget),
            .state_label = state_label,
            .detail = try alloc.dupeSentinel(u8, profileDetail(prof, &db), 0),
            .host = try alloc.dupe(u8, prof.host),
            .instance = try alloc.dupe(u8, prof.instanceOrDefault()),
            .ssh_port = prof.ssh_port,
            .buttons = buttons,
        };
        _ = adw.ActionRow.signals.activated.connect(row, *Card, onRow, c, .{});
        return c;
    }

    /// Status push: rows and the status area (never the form).
    pub fn update(p: *Page) void {
        if (!p.alive) return;
        for (p.cards.items) |c| updateCard(c);
        p.renderStatus();
    }

    fn updateCard(c: *Card) void {
        const e = hub.find(c.name);
        const dot_class: [:0]const u8 = if (e) |x| header.dotClass(x) else "none";
        if (!std.mem.eql(u8, dot_class, c.dot_class)) {
            c.dot.removeCssClass(c.dot_class.ptr);
            c.dot.addCssClass(dot_class.ptr);
            c.dot_class = dot_class;
        }
        c.dot.setVisible(@intFromBool(e != null));
        const sl: [:0]const u8 = if (e) |x| stateLabel(x) else "";
        c.state_label.setText(sl.ptr);
        c.state_label.as(gtk.Widget).setVisible(@intFromBool(e != null));

        // N8: a live connection on something other than the stored
        // profile (edited while connected; applies at Reconnect).
        var lb: [700]u8 = undefined;
        var w: std.Io.Writer = .fixed(&lb);
        if (e) |x| if (x.status) |st| {
            if (!std.mem.eql(u8, st.host, c.host) or !std.mem.eql(u8, st.instance, c.instance) or st.ssh_port != c.ssh_port) {
                w.print("on {s}", .{st.host}) catch {};
                if (st.ssh_port > 0) w.print(" -p {d}", .{st.ssh_port}) catch {};
                if (!std.mem.eql(u8, st.instance, "default")) w.print(" → {s}", .{st.instance}) catch {};
                w.writeAll(" until Reconnect (Ctrl+Shift+R) applies the edit") catch {};
            }
        };
        freeOpt(&c.live);
        if (w.end > 0) setOpt(&c.live, lb[0..w.end]);
        var sb: [1400]u8 = undefined;
        const subtitle = if (c.live) |l|
            std.fmt.bufPrintSentinel(&sb, "{s}\n{s}", .{ c.detail, l }, 0) catch c.detail
        else
            c.detail;
        c.root.setSubtitle(subtitle.ptr);

        const mode: @TypeOf(c.mode) = if (e) |x| switch (x.state) {
            .connected => .up,
            .connecting, .retry => .busy,
            .failed => .idle,
        } else .idle;
        if (mode != c.mode) {
            c.mode = mode;
            while (c.buttons.as(gtk.Widget).getFirstChild()) |b| c.buttons.remove(b);
            switch (mode) {
                .up => {
                    addCardButton(c, "Disconnect", .disconnect, false);
                    addCardButton(c, "Show", .connect, true);
                },
                .busy => addCardButton(c, "Cancel", .disconnect, false),
                .idle, .none => addCardButton(c, "Connect", .connect, true),
            }
        }
    }

    const CardAction = enum { connect, disconnect };

    fn addCardButton(c: *Card, label: [:0]const u8, action: CardAction, primary: bool) void {
        const b = gtk.Button.newWithLabel(label.ptr);
        if (primary) b.as(gtk.Widget).addCssClass("suggested-action");
        const handler = switch (action) {
            .connect => &onConnect,
            .disconnect => &onDisconnect,
        };
        _ = gtk.Button.signals.clicked.connect(b, *Card, handler, c, .{});
        c.buttons.append(b.as(gtk.Widget));
    }

    // -- row actions (also the control socket's entry points) -------------

    pub fn clickConnect(p: *Page, name: []const u8) void {
        if (hub.connectProfile(name)) |err| p.showNotice("{s}: {s}", .{ name, err });
    }

    pub fn clickDisconnect(_: *Page, name: []const u8) void {
        hub.disconnect(name);
    }

    pub fn clickEdit(p: *Page, name: []const u8) void {
        p.openForm(name);
    }

    pub fn clickRestart(p: *Page, name: []const u8) void {
        p.ask(.restart, name, "Restart sessions?", "This kills every shell on the host.", "Restart Sessions");
    }

    pub fn clickDelete(p: *Page, name: []const u8) void {
        p.ask(.delete, name, "Delete this profile?", "This removes the profile and its saved password.", "Delete Profile");
    }

    fn ask(p: *Page, kind: Confirm, name: []const u8, heading: [:0]const u8, body: [:0]const u8, label: [:0]const u8) void {
        if (p.confirm != null) return;
        const win = hub.hub.window orelse return;
        setOpt(&p.confirm_name, name);
        p.confirm_kind = kind;
        const d = adw.AlertDialog.new(heading.ptr, body.ptr);
        d.addResponse("cancel", "Cancel");
        d.addResponse("ok", label.ptr);
        d.setResponseAppearance("ok", .destructive);
        d.setDefaultResponse("cancel");
        d.setCloseResponse("cancel");
        _ = adw.AlertDialog.signals.response.connect(d, *Page, onConfirm, p, .{});
        p.confirm = d;
        d.as(adw.Dialog).present(win.as(gtk.Widget));
    }

    /// Answer the open confirmation (the control socket).
    pub fn answer(p: *Page, yes: bool) bool {
        const d = p.confirm orelse return false;
        d.setCloseResponse(if (yes) "ok" else "cancel");
        _ = d.as(adw.Dialog).close();
        return true;
    }

    fn onConfirm(_: *adw.AlertDialog, response: [*:0]const u8, p: *Page) callconv(.c) void {
        p.confirm = null;
        const name = p.confirm_name orelse return;
        defer freeOpt(&p.confirm_name);
        if (!std.mem.eql(u8, std.mem.span(response), "ok")) return;
        // The notices live on the main page, under the form.
        if (p.form != null) p.closeForm();
        switch (p.confirm_kind) {
            .restart => p.restart(name),
            .delete => p.delete(name),
        }
    }

    fn restart(p: *Page, name: []const u8) void {
        const engine = hub.hub.engine orelse return;
        p.showNotice("{s}: restarting sessions…", .{name});
        if (engine.restartSessions(name)) |err| p.showNotice("{s}: {s}", .{ name, err });
    }

    fn delete(p: *Page, name: []const u8) void {
        const engine = hub.hub.engine orelse return;
        var id_buf: [64]u8 = undefined;
        var id: ?[]const u8 = null;
        if (engine.getProfile(alloc, name) catch null) |prof| {
            defer prof.deinit(alloc);
            const n = @min(prof.id.len, id_buf.len);
            @memcpy(id_buf[0..n], prof.id[0..n]);
            id = id_buf[0..n];
        }
        if (engine.deleteProfile(name)) |err| p.showNotice("{s}: {s}", .{ name, err });
        // The saved password goes with the profile, keyring up or not.
        if (id) |i| if (i.len > 0) keyring.forget(i);
        hub.refresh();
        p.rebuildList();
    }

    fn onRow(_: *adw.ActionRow, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickEdit(c.name);
    }
    fn onConnect(_: *gtk.Button, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickConnect(c.name);
    }
    fn onDisconnect(_: *gtk.Button, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickDisconnect(c.name);
    }

    // -- notices (W-25) -----------------------------------------------------

    pub fn showNotice(p: *Page, comptime fmt: []const u8, args: anytype) void {
        if (p.notice) |n| alloc.free(n);
        p.notice = std.fmt.allocPrintSentinel(alloc, fmt, args, 0) catch null;
        if (p.notice_source != 0) _ = glib.Source.remove(p.notice_source);
        p.notice_source = glib.timeoutAdd(8000, clearNotice, p);
        p.renderStatus();
    }

    fn clearNotice(ud: ?*anyopaque) callconv(.c) c_int {
        const p: *Page = @ptrCast(@alignCast(ud.?));
        p.notice_source = 0;
        if (p.notice) |n| alloc.free(n);
        p.notice = null;
        p.renderStatus();
        return 0;
    }

    pub fn restartResult(p: *Page, name: []const u8, msg: []const u8) void {
        p.showNotice("{s}: {s}", .{ name, if (msg.len > 0) msg else "sessions restarted" });
    }

    // -- status detail (W-30) -------------------------------------------

    fn renderStatus(p: *Page) void {
        const box = p.status;
        while (box.as(gtk.Widget).getFirstChild()) |w| box.remove(w);
        if (p.notice) |n| box.append(para(n, null));
        for (hub.hub.entries.items) |e| {
            const show = switch (e.state) {
                .connecting, .retry, .failed => true,
                .connected => e.offline,
            };
            if (!show) continue;
            const h = gtk.Box.new(.horizontal, 6);
            const dot = gtk.Box.new(.horizontal, 0);
            dot.as(gtk.Widget).addCssClass("wm-dot");
            dot.as(gtk.Widget).addCssClass(header.dotClass(e).ptr);
            dot.as(gtk.Widget).setValign(.center);
            var nb: [4096]u8 = undefined;
            const nl = gtk.Label.new(cz(&nb, e.name).ptr);
            nl.as(gtk.Widget).addCssClass("heading");
            nl.setEllipsize(.end);
            nl.setXalign(0);
            h.append(dot.as(gtk.Widget));
            h.append(nl.as(gtk.Widget));
            box.append(h.as(gtk.Widget));
            const st = e.status orelse continue;
            var mb: [1024]u8 = undefined;
            if (st.msg.len > 0) box.append(para(std.fmt.bufPrintSentinel(&mb, "{s}", .{st.msg}, 0) catch "", "dim-label"));
            if (e.state == .connected and e.offline) {
                box.append(para("The tunnel is up but the workspace's session sockets are down and retrying — the server may be restarting. The client reconnects on its own if the server stops answering.", "dim-label"));
            }
            if (e.state == .retry) {
                var rb: [160]u8 = undefined;
                const t = if (hub.retrySeconds(e)) |s|
                    std.fmt.bufPrintSentinel(&rb, "Connection interrupted — retrying in {d}s… (sessions keep running on the server)", .{s}, 0) catch ""
                else
                    "Connection interrupted — retrying… (sessions keep running on the server)";
                box.append(para(t, "dim-label"));
            }
            if (e.state == .failed) {
                box.append(para("Not retrying automatically — hit Connect to try again. The connection log (Log button above) has the full sequence.", "dim-label"));
            }
            if (st.stderr.len > 0) box.append(pre(st.stderr));
        }
        p.status_group.as(gtk.Widget).setVisible(@intFromBool(box.as(gtk.Widget).getFirstChild() != null));
    }

    fn para(text: [:0]const u8, class: ?[:0]const u8) *gtk.Widget {
        const l = gtk.Label.new(null);
        text_mod.set(l, text);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.setXalign(0);
        l.setSelectable(1);
        l.as(gtk.Widget).setFocusable(0);
        if (class) |c| l.as(gtk.Widget).addCssClass(c.ptr);
        return l.as(gtk.Widget);
    }

    fn pre(text: []const u8) *gtk.Widget {
        const sw = gtk.ScrolledWindow.new();
        sw.setPolicy(.never, .automatic);
        sw.setMaxContentHeight(140);
        sw.setPropagateNaturalHeight(1);
        sw.as(gtk.Widget).addCssClass("card");
        const z = alloc.dupeSentinel(u8, text, 0) catch return sw.as(gtk.Widget);
        defer alloc.free(z);
        const l = gtk.Label.new(null);
        text_mod.set(l, z);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.setXalign(0);
        l.setYalign(0);
        l.setSelectable(1);
        const lw = l.as(gtk.Widget);
        lw.setFocusable(0);
        lw.addCssClass("monospace");
        lw.setMarginStart(10);
        lw.setMarginEnd(10);
        lw.setMarginTop(8);
        lw.setMarginBottom(8);
        sw.setChild(lw);
        return sw.as(gtk.Widget);
    }

    // -- the form (W-27, W-28) ------------------------------------------

    pub fn openForm(p: *Page, editing: []const u8) void {
        if (p.form != null) p.closeForm();
        const engine = hub.hub.engine orelse return;
        var prof: conn.Profile = .{};
        var owned: ?conn.Profile = null;
        defer if (owned) |o| o.deinit(alloc);
        if (editing.len > 0) {
            owned = engine.getProfile(alloc, editing) catch null;
            if (owned) |o| prof = o;
        }
        const has_pw = prof.id.len > 0 and keyring.has(prof.id);
        const f = buildForm(editing, prof, has_pw) catch return;
        p.form = f;
        _ = gtk.Button.signals.clicked.connect(f.submit, *Page, onSubmit, p, .{});
        _ = gtk.Button.signals.clicked.connect(f.cancel, *Page, onCancel, p, .{});
        _ = adw.NavigationPage.signals.hidden.connect(f.page, *Page, onFormHidden, p, .{});
        _ = adw.NavigationPage.signals.shown.connect(f.page, *Page, onFormShown, p, .{});
        for ([_]*adw.EntryRow{ f.name, f.host, f.ssh_port, f.identity, f.password, f.instance, f.extra }) |en| {
            _ = adw.EntryRow.signals.entry_activated.connect(en, *Page, onEntryActivate, p, .{});
        }
        if (f.restart) |b| _ = adw.ButtonRow.signals.activated.connect(b, *Page, onFormRestart, p, .{});
        if (f.delete) |b| _ = adw.ButtonRow.signals.activated.connect(b, *Page, onFormDelete, p, .{});
        p.present();
        settings_panel.dialog().pushSubpage(f.page);
    }

    pub fn closeForm(p: *Page) void {
        if (p.form) |f| {
            p.form = null;
            freeForm(f);
            _ = settings_panel.dialog().popSubpage();
        }
        p.form_tag += 1;
        p.rebuildList();
    }

    /// The first field takes focus (W-27), once the page has slid in: the
    /// navigation view moves focus itself during the transition.
    fn onFormShown(np: *adw.NavigationPage, p: *Page) callconv(.c) void {
        const f = p.form orelse return;
        if (f.page == np) _ = f.name.as(gtk.Widget).grabFocus();
    }

    /// The form left the screen some other way (Escape).
    fn onFormHidden(np: *adw.NavigationPage, p: *Page) callconv(.c) void {
        const f = p.form orelse return;
        if (f.page == np) p.closeForm();
    }

    fn onSubmit(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.submit();
    }
    fn onCancel(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.closeForm();
    }
    fn onEntryActivate(_: *adw.EntryRow, p: *Page) callconv(.c) void {
        p.submit();
    }
    fn onFormRestart(_: *adw.ButtonRow, p: *Page) callconv(.c) void {
        const f = p.form orelse return;
        p.clickRestart(f.editing);
    }
    fn onFormDelete(_: *adw.ButtonRow, p: *Page) callconv(.c) void {
        const f = p.form orelse return;
        p.clickDelete(f.editing);
    }

    /// Set a field (control socket; the same widgets a user types into).
    pub fn setField(p: *Page, field: []const u8, value: []const u8) bool {
        const f = p.form orelse return false;
        const z = alloc.dupeSentinel(u8, value, 0) catch return false;
        defer alloc.free(z);
        if (std.mem.eql(u8, field, "clear")) {
            const c = f.clear orelse return false;
            c.setActive(@intFromBool(std.mem.eql(u8, value, "true")));
            return true;
        }
        const en: *adw.EntryRow = if (std.mem.eql(u8, field, "name")) f.name else if (std.mem.eql(u8, field, "host")) f.host else if (std.mem.eql(u8, field, "ssh_port")) f.ssh_port else if (std.mem.eql(u8, field, "identity_file")) f.identity else if (std.mem.eql(u8, field, "password")) f.password else if (std.mem.eql(u8, field, "instance")) f.instance else if (std.mem.eql(u8, field, "extra_options")) f.extra else return false;
        en.as(gtk.Editable).setText(z.ptr);
        return true;
    }

    fn setError(f: *Form, msg: []const u8) void {
        text_mod.set(f.err, msg);
        f.err.as(gtk.Widget).setVisible(@intFromBool(msg.len > 0));
    }

    /// Save (& Connect), as main.js profiles:save: validate first; with a
    /// new password, store it in the keyring before anything is saved and
    /// reject the whole save if that fails (the form keeps everything the
    /// user typed); then save, clear a password if asked, close the form
    /// (and connect a new profile). Errors stay inline, the form open.
    pub fn submit(p: *Page) void {
        const f = p.form orelse return;
        if (f.busy) return;
        const engine = hub.hub.engine orelse return;
        const text = struct {
            fn get(e: *adw.EntryRow) []const u8 {
                return std.mem.span(e.as(gtk.Editable).getText());
            }
        }.get;
        // Number(x) || 0 for the port; what cannot be a port is refused
        // here (main.js passed it to ssh, which failed later).
        // Deviation 39: blank, or a whole number 1–65535 in decimal.
        const port: u32 = profile_mod.parsePort(text(f.ssh_port)) orelse return setError(f, profile_mod.PORT_ERROR);
        // Owned copies: the save may finish after the keyring answers.
        p.pending.deinit();
        p.pending = .init(alloc);
        const pa = p.pending.allocator();
        var input: conn.ProfileInput = .{
            .name = pa.dupe(u8, text(f.name)) catch return,
            .host = pa.dupe(u8, text(f.host)) catch return,
            .ssh_port = port,
            .identity_file = pa.dupe(u8, text(f.identity)) catch return,
            .instance = pa.dupe(u8, text(f.instance)) catch return,
            .extra_options = pa.dupe(u8, text(f.extra)) catch return,
        };
        const original: ?[]const u8 = if (f.editing.len > 0) f.editing else null;
        if (engine.validateProfile(input, original)) |err| return setError(f, err);

        const pw_text = text(f.password);
        const clear = if (f.clear) |c| c.getActive() != 0 else false;
        if (pw_text.len == 0) {
            _ = p.commitSave(input, clear);
            return;
        }

        // The id the keyring entry is keyed on: the profile's own, or a
        // new one the save will use.
        var id_buf: [64]u8 = undefined;
        var id_len: usize = 0;
        if (engine.getProfile(alloc, original orelse std.mem.trim(u8, input.name, " \t\r\n")) catch null) |prof| {
            defer prof.deinit(alloc);
            if (original != null) {
                id_len = @min(prof.id.len, id_buf.len);
                @memcpy(id_buf[0..id_len], prof.id[0..id_len]);
            }
        }
        if (id_len == 0) {
            var nid: [16]u8 = undefined;
            engine.newProfileId(&nid);
            @memcpy(id_buf[0..16], &nid);
            id_len = 16;
        }
        input.id = pa.dupe(u8, id_buf[0..id_len]) catch return;
        p.pending_input = input;
        f.busy = true;
        f.submit.as(gtk.Widget).setSensitive(0);
        setError(f, "storing the password in the system keyring…");
        p.form_tag += 1;
        const name = std.mem.trim(u8, input.name, " \t\r\n");
        keyring.storeAsync(id_buf[0..id_len], name, pw_text, p.form_tag, onStored);
    }

    fn onStored(r: keyring.Done) void {
        const p = hub.hub.page orelse return;
        if (r.tag != p.form_tag) return; // the form was closed meanwhile
        const f = p.form orelse return;
        f.busy = false;
        f.submit.as(gtk.Widget).setSensitive(1);
        const input = p.pending_input orelse return;
        p.pending_input = null;
        if (r.err) |err| {
            // Nothing was saved; the form keeps what was typed.
            setError(f, err);
            return;
        }
        f.password.as(gtk.Editable).setText("");
        if (!p.commitSave(input, false)) {
            // The save failed after the password went in: a new profile's
            // password must not outlive the attempt.
            if (f.editing.len == 0) if (input.id) |id| keyring.forget(id);
        }
    }

    /// Save the validated input; returns false (with the error shown) if
    /// the engine refused.
    fn commitSave(p: *Page, input: conn.ProfileInput, clear: bool) bool {
        const f = p.form orelse return false;
        const engine = hub.hub.engine orelse return false;
        const original: ?[]const u8 = if (f.editing.len > 0) f.editing else null;
        const was_new = original == null;
        if (engine.saveProfile(input, original)) |err| {
            setError(f, err);
            return false;
        }
        const name = std.mem.trim(u8, input.name, " \t\r\n");
        const name_copy = alloc.dupe(u8, name) catch return false;
        defer alloc.free(name_copy);
        if (original) |o| if (!std.mem.eql(u8, o, name_copy)) hub.renamed(o, name_copy);
        if (clear) {
            if (engine.getProfile(alloc, name_copy) catch null) |prof| {
                defer prof.deinit(alloc);
                keyring.forget(prof.id);
            }
        }
        p.closeForm();
        if (was_new) p.clickConnect(name_copy);
        return true;
    }
};

// ---------------------------------------------------------------------------

fn buildForm(editing: []const u8, prof: conn.Profile, has_pw: bool) !*Form {
    const f = try alloc.create(Form);
    errdefer alloc.destroy(f);
    const content = adw.PreferencesPage.new();

    const err = gtk.Label.new(null);
    err.as(gtk.Widget).addCssClass("error");
    err.as(gtk.Widget).setVisible(0);
    err.setWrap(1);
    err.setWrapMode(.word_char);
    err.setXalign(0);
    const errors = adw.PreferencesGroup.new();
    errors.add(err.as(gtk.Widget));
    content.add(errors);

    const main = adw.PreferencesGroup.new();
    main.setDescription("The host is anything ssh accepts, such as me@devbox.example.com. Port and identity file are optional.");
    const name = addEntry(main, "Profile name", prof.name);
    const host = addEntry(main, "Host", prof.host);
    var pb: [8]u8 = undefined;
    const port_s: []const u8 = if (prof.ssh_port > 0) (std.fmt.bufPrint(&pb, "{d}", .{prof.ssh_port}) catch "") else "";
    const ssh_port = addEntry(main, "SSH port", port_s);
    const identity = addEntry(main, "Identity file", prof.identity_file);
    const password = adw.PasswordEntryRow.new().as(adw.EntryRow);
    password.as(adw.PreferencesRow).setTitle(if (has_pw) "Password (saved — leave blank to keep)" else "Password (blank = key auth, recommended)");
    main.add(password.as(gtk.Widget));
    var clear: ?*adw.SwitchRow = null;
    if (has_pw) {
        const c = adw.SwitchRow.new();
        c.as(adw.PreferencesRow).setTitle("Clear saved password");
        main.add(c.as(gtk.Widget));
        clear = c;
    }
    content.add(main);

    const more = adw.PreferencesGroup.new();
    const adv = adw.ExpanderRow.new();
    adv.as(adw.PreferencesRow).setTitle("Advanced");
    adv.setSubtitle("Separate instances have separate sessions; blank is the default instance. Extra options go to ssh, such as -o ProxyJump=bastion.");
    const instance = adw.EntryRow.new();
    instance.as(adw.PreferencesRow).setTitle("Instance name");
    setText(instance, prof.instance);
    const extra = adw.EntryRow.new();
    extra.as(adw.PreferencesRow).setTitle("Extra ssh options");
    setText(extra, prof.extra_options);
    adv.addRow(instance.as(gtk.Widget));
    adv.addRow(extra.as(gtk.Widget));
    more.add(adv.as(gtk.Widget));
    content.add(more);

    var restart: ?*adw.ButtonRow = null;
    var delete: ?*adw.ButtonRow = null;
    if (editing.len > 0) {
        const danger = adw.PreferencesGroup.new();
        const r = adw.ButtonRow.new();
        r.as(adw.PreferencesRow).setTitle("Restart Sessions…");
        const d = adw.ButtonRow.new();
        d.as(adw.PreferencesRow).setTitle("Delete Profile…");
        d.as(gtk.Widget).addCssClass("destructive-action");
        danger.add(r.as(gtk.Widget));
        danger.add(d.as(gtk.Widget));
        content.add(danger);
        restart = r;
        delete = d;
    }

    const bar = adw.HeaderBar.new();
    bar.setShowStartTitleButtons(0);
    bar.setShowEndTitleButtons(0);
    bar.setShowBackButton(0);
    const cancel = gtk.Button.newWithLabel("Cancel");
    const submit = gtk.Button.newWithLabel(if (editing.len > 0) "Save" else "Save & Connect");
    submit.as(gtk.Widget).addCssClass("suggested-action");
    bar.packStart(cancel.as(gtk.Widget));
    bar.packEnd(submit.as(gtk.Widget));

    const view = adw.ToolbarView.new();
    view.addTopBar(bar.as(gtk.Widget));
    view.setContent(content.as(gtk.Widget));

    f.* = .{
        .editing = try alloc.dupe(u8, editing),
        .page = adw.NavigationPage.new(view.as(gtk.Widget), if (editing.len > 0) "Edit Profile" else "New Profile"),
        .name = name,
        .host = host,
        .ssh_port = ssh_port,
        .identity = identity,
        .password = password,
        .clear = clear,
        .instance = instance,
        .extra = extra,
        .advanced = adv,
        .submit = submit,
        .cancel = cancel,
        .err = err,
        .restart = restart,
        .delete = delete,
    };
    return f;
}

fn addEntry(group: *adw.PreferencesGroup, title: [:0]const u8, value: []const u8) *adw.EntryRow {
    const e = adw.EntryRow.new();
    e.as(adw.PreferencesRow).setTitle(title.ptr);
    setText(e, value);
    group.add(e.as(gtk.Widget));
    return e;
}

fn setText(e: *adw.EntryRow, value: []const u8) void {
    var zb: [1024]u8 = undefined;
    e.as(gtk.Editable).setText(cz(&zb, value).ptr);
}

fn freeCard(c: *Card) void {
    alloc.free(c.name);
    alloc.free(c.detail);
    freeOpt(&c.live);
    alloc.free(c.host);
    alloc.free(c.instance);
    alloc.destroy(c);
}

fn freeForm(f: *Form) void {
    alloc.free(f.editing);
    alloc.destroy(f);
}

fn freeOpt(slot: *?[]u8) void {
    if (slot.*) |s| alloc.free(s);
    slot.* = null;
}

fn setOpt(slot: *?[]u8, v: []const u8) void {
    freeOpt(slot);
    slot.* = alloc.dupe(u8, v) catch null;
}

fn profileDetail(p: conn.Profile, buf: []u8) [:0]const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.writeAll(p.host) catch {};
    if (p.ssh_port > 0) w.print(" -p {d}", .{p.ssh_port}) catch {};
    if (p.instance.len > 0) w.print(" → {s}", .{p.instance}) catch {};
    const n = w.end;
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn stateLabel(e: *const hub.Entry) [:0]const u8 {
    return switch (e.state) {
        .connecting => "connecting…",
        .connected => if (e.offline) "degraded" else "connected",
        .retry => "retrying…",
        .failed => "failed",
    };
}

/// `s` as a NUL-terminated string in `buf` (truncated to fit).
fn cz(buf: []u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}
