//! The connection manager page (electron/connect.html): profile cards with
//! live state and Connect / Show / Disconnect / Cancel, the ⋯ menu
//! (Restart Sessions, Delete Profile, both confirmed in place), the
//! profile form, per-connection status detail (deploy progress, retry
//! countdown, ssh's stderr), notices, the Log button and the help text.
//!
//! Cards are updated in place on status pushes (an open ⋯ menu survives);
//! the list is rebuilt only when the profiles change. Status pushes never
//! touch an open form (W-29).
const std = @import("std");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const adw = @import("adw");

const conn = @import("../../../webmux/conn.zig");
const iface = @import("../iface.zig");
const hub = @import("hub.zig");
const keyring = @import("keyring.zig");
const menu = @import("menu.zig");
const header = @import("header.zig");
const text_mod = @import("text.zig");
const profile_mod = @import("../../../webmux/conn/profile.zig");

const log = std.log.scoped(.webmux_chrome);
const alloc = std.heap.c_allocator;

pub const HINT =
    "A host needs nothing but ssh: connecting pushes the webmux server (one small static binary) to " ++
    "<tt>~/.webmux/dist</tt> on the host and starts it — updates are pushed the same way, and sessions " ++
    "survive them. Connect to several hosts at once — each connection gets a pill in the header bar above " ++
    "(Ctrl+1…9 or Ctrl+PageUp/PageDown switch, Ctrl+Shift+O returns here). Key auth needs no prompt (use " ++
    "ssh-agent for passphrases); or save a password per profile — it is stored in the system keyring " ++
    "(GNOME Keyring or KWallet, via the Secret Service) and fed to ssh through an askpass helper. " ++
    "Ctrl+Shift+R reconnects the current host.";

const Card = struct {
    name: []u8,
    root: *gtk.Box,
    dot: *gtk.Widget,
    dot_class: [:0]const u8 = "none",
    name_label: *gtk.Label,
    state_label: *gtk.Label,
    detail: *gtk.Label,
    /// "connected on …; Reconnect to use the edit" (hidden unless so).
    live: *gtk.Label,
    /// The stored profile's host, instance (or "default"), port.
    host: []u8,
    instance: []u8,
    ssh_port: u32,
    buttons: *gtk.Box,
    /// Which button set is showing (rebuilt only when it changes).
    mode: enum { none, up, busy, idle } = .none,
    menu_button: *gtk.MenuButton,
    popover: *gtk.Popover,
    restart_btn: *gtk.Button,
    delete_btn: *gtk.Button,
};

pub const Form = struct {
    /// Original name of the profile being edited; "" for a new one.
    editing: []u8,
    root: *gtk.Box,
    name: *gtk.Entry,
    host: *gtk.Entry,
    ssh_port: *gtk.Entry,
    identity: *gtk.Entry,
    password: *gtk.Entry,
    clear: ?*gtk.CheckButton,
    instance: *gtk.Entry,
    extra: *gtk.Entry,
    advanced: *gtk.Expander,
    submit: *gtk.Button,
    cancel: *gtk.Button,
    err: *gtk.Label,
    busy: bool = false,
};

pub const Page = struct {
    root: *gtk.ScrolledWindow,
    wrap: *gtk.Box,
    list: *gtk.Box,
    form_holder: *gtk.Box,
    status: *gtk.Box,
    log_btn: *gtk.Button,
    new_btn: *gtk.Button,
    engine_error: ?*gtk.Label = null,

    cards: std.ArrayList(*Card) = .empty,
    empty_label: ?*gtk.Label = null,
    form: ?*Form = null,
    /// Profile whose ⋯ menu is open, and pending confirmations.
    menu_for: ?[]u8 = null,
    confirm_restart: ?[]u8 = null,
    confirm_delete: ?[]u8 = null,
    notice: ?[:0]u8 = null,
    notice_source: c_uint = 0,
    form_tag: u64 = 0,
    /// The input of a save waiting for the keyring (owned by `pending`).
    pending: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    pending_input: ?conn.ProfileInput = null,
    /// The config problem banner (engine.configProblem), if any.
    config_banner: ?*gtk.Label = null,
    alive: bool = true,

    pub fn widget(p: *Page) *gtk.Widget {
        return p.root.as(gtk.Widget);
    }

    pub fn create() *Page {
        const p = alloc.create(Page) catch @panic("OOM");
        const root = gtk.ScrolledWindow.new();
        root.setPolicy(.never, .automatic);
        const rw = root.as(gtk.Widget);
        rw.addCssClass("wm-page");
        rw.setFocusable(1);

        const clamp = adw.Clamp.new();
        clamp.setMaximumSize(620);
        clamp.setTighteningThreshold(620);
        const wrap = gtk.Box.new(.vertical, 0);
        wrap.as(gtk.Widget).addCssClass("wm-wrap");
        clamp.setChild(wrap.as(gtk.Widget));
        root.setChild(clamp.as(gtk.Widget));

        const topbar = gtk.Box.new(.horizontal, 12);
        topbar.as(gtk.Widget).addCssClass("wm-topbar");
        const title = gtk.Label.new("webmux");
        title.as(gtk.Widget).addCssClass("wm-title");
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        const log_btn = gtk.Button.newWithLabel("Log");
        log_btn.as(gtk.Widget).setTooltipText("Connection log (Ctrl+Shift+G)");
        const new_btn = gtk.Button.newWithLabel("New Profile");
        new_btn.as(gtk.Widget).addCssClass("primary");
        topbar.append(title.as(gtk.Widget));
        topbar.append(spacer.as(gtk.Widget));
        topbar.append(log_btn.as(gtk.Widget));
        topbar.append(new_btn.as(gtk.Widget));
        wrap.append(topbar.as(gtk.Widget));

        const list = gtk.Box.new(.vertical, 10);
        list.as(gtk.Widget).addCssClass("wm-list");
        const form_holder = gtk.Box.new(.vertical, 0);
        const status = gtk.Box.new(.vertical, 0);
        status.as(gtk.Widget).addCssClass("wm-status-detail");
        wrap.append(list.as(gtk.Widget));
        wrap.append(form_holder.as(gtk.Widget));
        wrap.append(status.as(gtk.Widget));

        const hint = gtk.Label.new(null);
        text_mod.setMarkup(hint, HINT);
        hint.setWrap(1);
        hint.setWrapMode(.word_char);
        hint.setXalign(0);
        hint.as(gtk.Widget).addCssClass("wm-hint");
        wrap.append(hint.as(gtk.Widget));

        p.* = .{
            .root = root,
            .wrap = wrap,
            .list = list,
            .form_holder = form_holder,
            .status = status,
            .log_btn = log_btn,
            .new_btn = new_btn,
        };
        _ = gtk.Button.signals.clicked.connect(log_btn, *Page, onLog, p, .{});
        _ = gtk.Button.signals.clicked.connect(new_btn, *Page, onNew, p, .{});
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Page, onKey, p, .{});
        rw.addController(keys.as(gtk.EventController));

        p.rebuildList();
        p.update();
        return p;
    }

    pub fn destroyed(p: *Page) void {
        p.alive = false;
        if (p.notice_source != 0) _ = glib.Source.remove(p.notice_source);
        p.notice_source = 0;
        for (p.cards.items) |c| freeCard(c);
        p.cards.deinit(alloc);
        if (p.form) |f| freeForm(f);
        freeOpt(&p.menu_for);
        freeOpt(&p.confirm_restart);
        freeOpt(&p.confirm_delete);
        if (p.notice) |n| alloc.free(n);
        p.pending.deinit();
        alloc.destroy(p);
    }

    pub fn focus(p: *Page) void {
        if (p.form) |f| {
            // Back to the field the user was in, as it was (Connections,
            // a dialog closing); the first field only for a fresh form.
            if (hub.contentFocusIn(f.root.as(gtk.Widget))) |w| {
                if (hub.refocus(w)) return;
            }
            _ = f.name.as(gtk.Widget).grabFocus();
            return;
        }
        _ = p.root.as(gtk.Widget).grabFocus();
    }

    pub fn showEngineError(p: *Page, msg: []const u8) void {
        var buf: [512]u8 = undefined;
        const t = std.fmt.bufPrintSentinel(&buf, "The connection engine failed to start: {s}. See the application log.", .{msg}, 0) catch "The connection engine failed to start.";
        const l = gtk.Label.new(null);
        text_mod.set(l, t);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.as(gtk.Widget).addCssClass("wm-form-error");
        p.wrap.insertChildAfter(l.as(gtk.Widget), p.wrap.as(gtk.Widget).getFirstChild());
        p.engine_error = l;
    }

    /// config.json could not be loaded (engine.configProblem): say so above
    /// the list, for as long as the app runs.
    pub fn showConfigProblem(p: *Page, msg: []const u8) void {
        if (p.config_banner != null) return;
        const t = std.fmt.allocPrint(alloc, "{s}. Fix or restore the file and restart to get the old profiles back; the connection log has the details.", .{msg}) catch "config.json could not be read; see the connection log.";
        const l = gtk.Label.new(null);
        text_mod.set(l, t);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.setXalign(0);
        l.setSelectable(1);
        l.as(gtk.Widget).addCssClass("wm-form-error");
        l.as(gtk.Widget).addCssClass("wm-config-problem");
        p.wrap.insertChildAfter(l.as(gtk.Widget), p.wrap.as(gtk.Widget).getFirstChild());
        p.config_banner = l;
    }

    // -- top buttons ------------------------------------------------------

    pub fn clickLog(_: *Page) void {
        menu.activateApp(iface.actions.show_log);
    }

    pub fn clickNew(p: *Page) void {
        p.closeMenu();
        p.openForm("");
    }

    fn onLog(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.clickLog();
    }
    fn onNew(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.clickNew();
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, p: *Page) callconv(.c) c_int {
        if (keyval != gdk.KEY_Escape) return 0;
        return @intFromBool(p.escape());
    }

    /// Escape: close the ⋯ menu, else cancel the form (W-24, W-28).
    pub fn escape(p: *Page) bool {
        if (p.menu_for != null) {
            p.closeMenu();
            return true;
        }
        if (p.form != null) {
            p.closeForm();
            return true;
        }
        return false;
    }

    // -- the list -----------------------------------------------------------

    /// The profiles changed: rebuild the cards (closes an open ⋯ menu).
    pub fn rebuildList(p: *Page) void {
        for (p.cards.items) |c| {
            p.list.remove(c.root.as(gtk.Widget));
            freeCard(c);
        }
        p.cards.clearRetainingCapacity();
        if (p.empty_label) |l| p.list.remove(l.as(gtk.Widget));
        p.empty_label = null;
        freeOpt(&p.menu_for);
        freeOpt(&p.confirm_restart);
        freeOpt(&p.confirm_delete);

        const engine = hub.hub.engine orelse return;
        var profiles = engine.listProfiles(alloc) catch return;
        defer profiles.deinit();
        if (profiles.profiles.len == 0) {
            const l = gtk.Label.new("No profiles yet — create one to connect.");
            l.as(gtk.Widget).addCssClass("wm-empty");
            p.list.append(l.as(gtk.Widget));
            p.empty_label = l;
        }
        for (profiles.profiles) |prof| {
            const c = p.newCard(prof) catch continue;
            p.cards.append(alloc, c) catch continue;
            p.list.append(c.root.as(gtk.Widget));
        }
        p.update();
    }

    fn newCard(p: *Page, prof: conn.Profile) !*Card {
        const c = try alloc.create(Card);
        const root = gtk.Box.new(.horizontal, 12);
        root.as(gtk.Widget).addCssClass("wm-card");
        const info = gtk.Box.new(.vertical, 0);
        info.as(gtk.Widget).setHexpand(1);
        info.as(gtk.Widget).addCssClass("info");
        const name_row = gtk.Box.new(.horizontal, 8);
        const dot = gtk.Box.new(.horizontal, 0);
        dot.as(gtk.Widget).addCssClass("wm-dot");
        dot.as(gtk.Widget).setValign(.center);
        var nb: [4096]u8 = undefined;
        const name_label = gtk.Label.new(cz(&nb, prof.name).ptr);
        name_label.as(gtk.Widget).addCssClass("name");
        name_label.setXalign(0);
        // Long names and hosts never widen the page or the window (N3).
        name_label.setEllipsize(.end);
        name_label.as(gtk.Widget).setTooltipText(cz(&nb, prof.name).ptr);
        const state_label = gtk.Label.new(null);
        state_label.as(gtk.Widget).addCssClass("state-label");
        name_row.append(dot.as(gtk.Widget));
        name_row.append(name_label.as(gtk.Widget));
        name_row.append(state_label.as(gtk.Widget));
        var db: [600]u8 = undefined;
        const detail = gtk.Label.new(profileDetail(prof, &db).ptr);
        detail.as(gtk.Widget).addCssClass("detail");
        detail.setXalign(0);
        detail.setEllipsize(.end);
        detail.as(gtk.Widget).setTooltipText(profileDetail(prof, &db).ptr);
        // N8: what a live connection is actually on, when an edit to the
        // profile waits for Reconnect.
        const live = gtk.Label.new(null);
        live.as(gtk.Widget).addCssClass("live-pending");
        live.setXalign(0);
        live.setEllipsize(.end);
        live.as(gtk.Widget).setVisible(0);
        info.append(name_row.as(gtk.Widget));
        info.append(detail.as(gtk.Widget));
        info.append(live.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setValign(.center);

        const mb = gtk.MenuButton.new();
        // A label child (not setLabel) so no dropdown arrow is drawn.
        const dots = gtk.Label.new("⋯");
        mb.setChild(dots.as(gtk.Widget));
        mb.as(gtk.Widget).addCssClass("small");
        mb.as(gtk.Widget).setTooltipText("More actions");
        mb.as(gtk.Widget).setValign(.center);
        const pop = gtk.Popover.new();
        pop.as(gtk.Widget).addCssClass("wm-menu");
        pop.setHasArrow(0);
        const pbox = gtk.Box.new(.vertical, 0);
        const restart_btn = gtk.Button.newWithLabel("Restart Sessions…");
        const delete_btn = gtk.Button.newWithLabel("Delete Profile…");
        delete_btn.as(gtk.Widget).addCssClass("danger");
        restart_btn.as(gtk.Widget).addCssClass("wm-menu-item");
        delete_btn.as(gtk.Widget).addCssClass("wm-menu-item");
        for ([_]*gtk.Button{ restart_btn, delete_btn }) |b| {
            if (b.getChild()) |l| if (gobject.ext.cast(gtk.Label, l)) |lab| lab.setXalign(0);
        }
        pbox.append(restart_btn.as(gtk.Widget));
        pbox.append(delete_btn.as(gtk.Widget));
        pop.setChild(pbox.as(gtk.Widget));
        mb.setPopover(pop);

        root.append(info.as(gtk.Widget));
        root.append(buttons.as(gtk.Widget));
        root.append(mb.as(gtk.Widget));

        c.* = .{
            .name = try alloc.dupe(u8, prof.name),
            .root = root,
            .dot = dot.as(gtk.Widget),
            .name_label = name_label,
            .state_label = state_label,
            .detail = detail,
            .live = live,
            .host = try alloc.dupe(u8, prof.host),
            .instance = try alloc.dupe(u8, prof.instanceOrDefault()),
            .ssh_port = prof.ssh_port,
            .buttons = buttons,
            .menu_button = mb,
            .popover = pop,
            .restart_btn = restart_btn,
            .delete_btn = delete_btn,
        };
        _ = gtk.Button.signals.clicked.connect(restart_btn, *Card, onRestart, c, .{});
        _ = gtk.Button.signals.clicked.connect(delete_btn, *Card, onDelete, c, .{});
        _ = gtk.Popover.signals.closed.connect(pop, *Card, onMenuClosed, c, .{});
        _ = gobject.Object.signals.notify.connect(mb, *Card, onMenuActive, c, .{ .detail = "active" });
        _ = p;
        return c;
    }

    fn cardFor(p: *Page, name: []const u8) ?*Card {
        for (p.cards.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    /// Status push: cards and the status area (never the form).
    pub fn update(p: *Page) void {
        if (!p.alive) return;
        for (p.cards.items) |c| p.updateCard(c);
        p.renderStatus();
    }

    fn updateCard(p: *Page, c: *Card) void {
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
        var pending = false;
        if (e) |x| if (x.status) |st| {
            if (!std.mem.eql(u8, st.host, c.host) or !std.mem.eql(u8, st.instance, c.instance) or st.ssh_port != c.ssh_port) {
                pending = true;
                var lb: [700]u8 = undefined;
                var w: std.Io.Writer = .fixed(lb[0 .. lb.len - 1]);
                w.print("on {s}", .{st.host}) catch {};
                if (st.ssh_port > 0) w.print(" -p {d}", .{st.ssh_port}) catch {};
                if (!std.mem.eql(u8, st.instance, "default")) w.print(" → {s}", .{st.instance}) catch {};
                w.writeAll(" until Reconnect (Ctrl+Shift+R) applies the edit") catch {};
                const n = w.end;
                lb[n] = 0;
                c.live.setText(lb[0..n :0].ptr);
                c.live.as(gtk.Widget).setTooltipText(lb[0..n :0].ptr);
            }
        };
        c.live.as(gtk.Widget).setVisible(@intFromBool(pending));
        const up = if (e) |x| x.isUp() else false;
        header.setClass(c.root.as(gtk.Widget), "active", up);

        const mode: @TypeOf(c.mode) = if (e) |x| switch (x.state) {
            .connected => .up,
            .connecting, .retry => .busy,
            .failed => .idle,
        } else .idle;
        if (mode != c.mode) {
            c.mode = mode;
            while (c.buttons.as(gtk.Widget).getFirstChild()) |w| c.buttons.remove(w);
            p.addCardButton(c, "Edit", .edit, false);
            switch (mode) {
                .up => {
                    p.addCardButton(c, "Disconnect", .disconnect, false);
                    p.addCardButton(c, "Show", .connect, true);
                },
                .busy => p.addCardButton(c, "Cancel", .disconnect, false),
                .idle, .none => p.addCardButton(c, "Connect", .connect, true),
            }
        }
        // ⋯ menu labels follow the pending confirmations (rebuilt in place).
        const confirm_r = if (p.confirm_restart) |n| std.mem.eql(u8, n, c.name) else false;
        const confirm_d = if (p.confirm_delete) |n| std.mem.eql(u8, n, c.name) else false;
        c.restart_btn.setLabel(if (confirm_r) "Sure? This kills every shell" else "Restart Sessions…");
        c.delete_btn.setLabel(if (confirm_d) "Sure? Removes the profile" else "Delete Profile…");
    }

    const CardAction = enum { edit, connect, disconnect };

    fn addCardButton(_: *Page, c: *Card, label: [:0]const u8, action: CardAction, primary: bool) void {
        const b = gtk.Button.newWithLabel(label.ptr);
        b.as(gtk.Widget).addCssClass("small");
        if (primary) b.as(gtk.Widget).addCssClass("primary");
        const handler = switch (action) {
            .edit => &onEdit,
            .connect => &onConnect,
            .disconnect => &onDisconnect,
        };
        _ = gtk.Button.signals.clicked.connect(b, *Card, handler, c, .{});
        c.buttons.append(b.as(gtk.Widget));
    }

    // -- card actions (also the control socket's entry points) -----------

    pub fn clickConnect(p: *Page, name: []const u8) void {
        if (hub.connectProfile(name)) |err| p.showNotice("{s}: {s}", .{ name, err });
    }

    pub fn clickDisconnect(_: *Page, name: []const u8) void {
        hub.disconnect(name);
    }

    pub fn clickEdit(p: *Page, name: []const u8) void {
        p.closeMenu();
        p.openForm(name);
    }

    pub fn clickMenu(p: *Page, name: []const u8) void {
        const c = p.cardFor(name) orelse return;
        const open = if (p.menu_for) |m| !std.mem.eql(u8, m, name) else true;
        p.closeMenu();
        if (open) c.menu_button.popup();
    }

    /// First click relabels; the second restarts (W-24, W-25).
    pub fn clickRestart(p: *Page, name: []const u8) void {
        const pending = if (p.confirm_restart) |n| std.mem.eql(u8, n, name) else false;
        if (!pending) {
            setOpt(&p.confirm_restart, name);
            freeOpt(&p.confirm_delete);
            p.update();
            return;
        }
        p.closeMenu();
        const engine = hub.hub.engine orelse return;
        p.showNotice("{s}: restarting sessions…", .{name});
        if (engine.restartSessions(name)) |err| p.showNotice("{s}: {s}", .{ name, err });
    }

    pub fn clickDelete(p: *Page, name: []const u8) void {
        const pending = if (p.confirm_delete) |n| std.mem.eql(u8, n, name) else false;
        if (!pending) {
            setOpt(&p.confirm_delete, name);
            freeOpt(&p.confirm_restart);
            p.update();
            return;
        }
        p.closeMenu();
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
        // The saved password goes with the profile.
        // The saved password goes with the profile, keyring up or not.
        if (id) |i| if (i.len > 0) keyring.forget(i);
        hub.refresh();
        p.rebuildList();
    }

    fn closeMenu(p: *Page) void {
        const name = p.menu_for;
        p.menu_for = null;
        freeOpt(&p.confirm_restart);
        freeOpt(&p.confirm_delete);
        if (name) |n| {
            if (p.cardFor(n)) |c| c.menu_button.popdown();
            alloc.free(n);
        }
        p.update();
    }

    fn onConnect(_: *gtk.Button, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickConnect(c.name);
    }
    fn onDisconnect(_: *gtk.Button, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickDisconnect(c.name);
    }
    fn onEdit(_: *gtk.Button, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickEdit(c.name);
    }
    fn onRestart(_: *gtk.Button, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickRestart(c.name);
    }
    fn onDelete(_: *gtk.Button, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        p.clickDelete(c.name);
    }
    fn onMenuActive(mb: *gtk.MenuButton, _: *gobject.ParamSpec, c: *Card) callconv(.c) void {
        const p = hub.hub.page orelse return;
        if (mb.getActive() != 0) {
            if (p.menu_for) |m| if (!std.mem.eql(u8, m, c.name)) p.closeMenu();
            setOpt(&p.menu_for, c.name);
        }
    }
    fn onMenuClosed(_: *gtk.Popover, c: *Card) callconv(.c) void {
        hub.scheduleFocusRestore();
        const p = hub.hub.page orelse return;
        // Click outside / Escape: clear pending confirmations (W-24).
        if (p.menu_for) |m| if (std.mem.eql(u8, m, c.name)) {
            freeOpt(&p.menu_for);
            freeOpt(&p.confirm_restart);
            freeOpt(&p.confirm_delete);
            p.update();
        };
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
        if (p.notice) |n| box.append(para(n, "notice"));
        for (hub.hub.entries.items) |e| {
            const show = switch (e.state) {
                .connecting, .retry, .failed => true,
                .connected => e.offline,
            };
            if (!show) continue;
            const h = gtk.Box.new(.horizontal, 6);
            h.as(gtk.Widget).addCssClass("heading");
            const dot = gtk.Box.new(.horizontal, 0);
            dot.as(gtk.Widget).addCssClass("wm-dot");
            dot.as(gtk.Widget).addCssClass(header.dotClass(e).ptr);
            dot.as(gtk.Widget).setValign(.center);
            var nb: [4096]u8 = undefined;
            const nl = gtk.Label.new(cz(&nb, e.name).ptr);
            nl.setEllipsize(.end);
            nl.setXalign(0);
            h.append(dot.as(gtk.Widget));
            h.append(nl.as(gtk.Widget));
            box.append(h.as(gtk.Widget));
            const st = e.status orelse continue;
            var mb: [1024]u8 = undefined;
            if (st.msg.len > 0) box.append(para(std.fmt.bufPrintSentinel(&mb, "{s}", .{st.msg}, 0) catch "", null));
            if (e.state == .connected and e.offline) {
                box.append(para("The tunnel is up but the workspace's session sockets are down and retrying — the server may be restarting. The client reconnects on its own if the server stops answering.", null));
            }
            if (e.state == .retry) {
                var rb: [160]u8 = undefined;
                const t = if (hub.retrySeconds(e)) |s|
                    std.fmt.bufPrintSentinel(&rb, "Connection interrupted — retrying in {d}s… (sessions keep running on the server)", .{s}, 0) catch ""
                else
                    "Connection interrupted — retrying… (sessions keep running on the server)";
                box.append(para(t, "retry"));
            }
            if (e.state == .failed) {
                box.append(para("Not retrying automatically — hit Connect to try again. The connection log (Log button above) has the full sequence.", null));
            }
            if (st.stderr.len > 0) box.append(pre(st.stderr));
        }
    }

    fn para(text: [:0]const u8, class: ?[:0]const u8) *gtk.Widget {
        const l = gtk.Label.new(null);
        text_mod.set(l, text);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.setXalign(0);
        l.setSelectable(1);
        l.as(gtk.Widget).setFocusable(0);
        l.as(gtk.Widget).addCssClass("para");
        if (class) |c| l.as(gtk.Widget).addCssClass(c.ptr);
        return l.as(gtk.Widget);
    }

    fn pre(text: []const u8) *gtk.Widget {
        const sw = gtk.ScrolledWindow.new();
        sw.setPolicy(.never, .automatic);
        sw.setMaxContentHeight(140);
        sw.setPropagateNaturalHeight(1);
        sw.as(gtk.Widget).addCssClass("wm-pre");
        const z = alloc.dupeSentinel(u8, text, 0) catch return sw.as(gtk.Widget);
        defer alloc.free(z);
        const l = gtk.Label.new(null);
        text_mod.set(l, z);
        l.setWrap(1);
        l.setWrapMode(.word_char);
        l.setXalign(0);
        l.setYalign(0);
        l.setSelectable(1);
        l.as(gtk.Widget).setFocusable(0);
        sw.setChild(l.as(gtk.Widget));
        return sw.as(gtk.Widget);
    }

    /// The keyring's has-password set changed: refresh an open form's
    /// placeholder (only if the user has not started typing).
    pub fn keyringChanged(p: *Page) void {
        _ = p;
    }

    // -- the form (W-27, W-28) ------------------------------------------

    pub fn openForm(p: *Page, editing: []const u8) void {
        if (p.form) |f| {
            p.form_holder.remove(f.root.as(gtk.Widget));
            freeForm(f);
            p.form = null;
        }
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
        p.form_holder.append(f.root.as(gtk.Widget));
        p.list.as(gtk.Widget).setVisible(0);
        _ = gtk.Button.signals.clicked.connect(f.submit, *Page, onSubmit, p, .{});
        _ = gtk.Button.signals.clicked.connect(f.cancel, *Page, onCancel, p, .{});
        for ([_]*gtk.Entry{ f.name, f.host, f.ssh_port, f.identity, f.password, f.instance, f.extra }) |en| {
            _ = gtk.Entry.signals.activate.connect(en, *Page, onEntryActivate, p, .{});
        }
        _ = f.name.as(gtk.Widget).grabFocus();
    }

    pub fn closeForm(p: *Page) void {
        if (p.form) |f| {
            p.form_holder.remove(f.root.as(gtk.Widget));
            freeForm(f);
        }
        p.form = null;
        p.form_tag += 1;
        p.list.as(gtk.Widget).setVisible(1);
        p.rebuildList();
        _ = p.root.as(gtk.Widget).grabFocus();
    }

    fn onSubmit(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.submit();
    }
    fn onCancel(_: *gtk.Button, p: *Page) callconv(.c) void {
        p.closeForm();
    }
    fn onEntryActivate(_: *gtk.Entry, p: *Page) callconv(.c) void {
        p.submit();
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
        const en: *gtk.Entry = if (std.mem.eql(u8, field, "name")) f.name else if (std.mem.eql(u8, field, "host")) f.host else if (std.mem.eql(u8, field, "ssh_port")) f.ssh_port else if (std.mem.eql(u8, field, "identity_file")) f.identity else if (std.mem.eql(u8, field, "password")) f.password else if (std.mem.eql(u8, field, "instance")) f.instance else if (std.mem.eql(u8, field, "extra_options")) f.extra else return false;
        en.as(gtk.Editable).setText(z.ptr);
        return true;
    }

    fn setError(f: *Form, msg: []const u8) void {
        text_mod.set(f.err, msg);
    }

    /// Save (& Connect): validate through the engine, store or clear the
    /// password in the keyring, then close the form (and connect a new
    /// profile). Errors stay inline and the form stays open.
    /// Save (& Connect), as main.js profiles:save: validate first; with a
    /// new password, store it in the keyring before anything is saved and
    /// reject the whole save if that fails (the form keeps everything the
    /// user typed); then save, clear a password if asked, close the form
    /// (and connect a new profile).
    pub fn submit(p: *Page) void {
        const f = p.form orelse return;
        if (f.busy) return;
        const engine = hub.hub.engine orelse return;
        const text = struct {
            fn get(e: *gtk.Entry) []const u8 {
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
        p.finishSubmit(was_new, name_copy);
        return true;
    }

    fn finishSubmit(p: *Page, was_new: bool, name: []const u8) void {
        p.closeForm();
        if (was_new) p.clickConnect(name);
    }
};

// ---------------------------------------------------------------------------

fn buildForm(editing: []const u8, prof: conn.Profile, has_pw: bool) !*Form {
    const f = try alloc.create(Form);
    errdefer alloc.destroy(f);
    const root = gtk.Box.new(.vertical, 10);
    root.as(gtk.Widget).addCssClass("wm-form");

    const row1 = row();
    const name = addField(row1, "Profile name", "devbox", prof.name, false);
    const host = addField(row1, "Host (anything ssh accepts)", "me@devbox.example.com", prof.host, false);
    root.append(row1.as(gtk.Widget));

    const row2 = row();
    var pb: [8]u8 = undefined;
    const port_s: []const u8 = if (prof.ssh_port > 0) (std.fmt.bufPrint(&pb, "{d}", .{prof.ssh_port}) catch "") else "";
    const ssh_port = addField(row2, "SSH port (opt.)", "22", port_s, true);
    const identity = addField(row2, "Identity file (opt.)", "~/.ssh/id_ed25519", prof.identity_file, false);
    root.append(row2.as(gtk.Widget));

    const row3 = row();
    const password = addField(row3, "Password (opt. — stored encrypted in the system keyring)", if (has_pw) "saved — leave blank to keep" else "blank = key auth (recommended)", "", false);
    password.setVisibility(0);
    password.setInputPurpose(.password);
    var clear: ?*gtk.CheckButton = null;
    if (has_pw) {
        const c = gtk.CheckButton.newWithLabel("clear saved");
        c.as(gtk.Widget).setValign(.end);
        c.as(gtk.Widget).addCssClass("narrow");
        c.as(gtk.Widget).setSizeRequest(130, -1);
        row3.append(c.as(gtk.Widget));
        clear = c;
    }
    root.append(row3.as(gtk.Widget));

    const adv = gtk.Expander.new("Advanced");
    adv.as(gtk.Widget).addCssClass("wm-advanced");
    const advbox = gtk.Box.new(.vertical, 10);
    const row4 = row();
    const instance = addField(row4, "Instance name (blank = default — separate instances have separate sessions)", "default", prof.instance, false);
    advbox.append(row4.as(gtk.Widget));
    const row5 = row();
    const extra = addField(row5, "Extra ssh options", "-o ProxyJump=bastion", prof.extra_options, false);
    advbox.append(row5.as(gtk.Widget));
    adv.setChild(advbox.as(gtk.Widget));
    root.append(adv.as(gtk.Widget));

    const actions = gtk.Box.new(.horizontal, 10);
    actions.as(gtk.Widget).addCssClass("form-actions");
    const submit = gtk.Button.newWithLabel(if (editing.len > 0) "Save" else "Save & Connect");
    submit.as(gtk.Widget).addCssClass("primary");
    const cancel = gtk.Button.newWithLabel("Cancel");
    const err = gtk.Label.new(null);
    err.as(gtk.Widget).addCssClass("wm-form-error");
    err.setWrap(1);
    err.setWrapMode(.word_char);
    err.setXalign(0);
    err.as(gtk.Widget).setHexpand(1);
    actions.append(submit.as(gtk.Widget));
    actions.append(cancel.as(gtk.Widget));
    actions.append(err.as(gtk.Widget));
    root.append(actions.as(gtk.Widget));

    f.* = .{
        .editing = try alloc.dupe(u8, editing),
        .root = root,
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
    };
    return f;
}

fn row() *gtk.Box {
    const b = gtk.Box.new(.horizontal, 12);
    b.as(gtk.Widget).addCssClass("row");
    return b;
}

fn addField(parent: *gtk.Box, label: [:0]const u8, placeholder: [:0]const u8, value: []const u8, narrow: bool) *gtk.Entry {
    const box = gtk.Box.new(.vertical, 3);
    box.as(gtk.Widget).addCssClass("field");
    if (narrow) {
        box.as(gtk.Widget).setSizeRequest(130, -1);
    } else box.as(gtk.Widget).setHexpand(1);
    const l = gtk.Label.new(label.ptr);
    l.setXalign(0);
    l.setWrap(1);
        l.setWrapMode(.word_char);
    l.as(gtk.Widget).addCssClass("field-label");
    const e = gtk.Entry.new();
    e.setPlaceholderText(placeholder.ptr);
    var zb: [1024]u8 = undefined;
    const z = cz(&zb, value);
    e.as(gtk.Editable).setText(z.ptr);
    if (narrow) e.as(gtk.Editable).setWidthChars(6);
    box.append(l.as(gtk.Widget));
    box.append(e.as(gtk.Widget));
    parent.append(box.as(gtk.Widget));
    return e;
}

fn freeCard(c: *Card) void {
    alloc.free(c.name);
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

fn setOpt2(slot: *[]u8, v: []const u8) void {
    const copy = alloc.dupe(u8, v) catch return;
    alloc.free(slot.*);
    slot.* = copy;
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
