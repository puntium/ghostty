//! The header bar (electron/header.html, in GNOME's clothes: deviation
//! 66). An `AdwHeaderBar`, so it is the window's title bar: dragging its
//! empty parts moves the window, and it carries the window controls. New
//! terminal and new file browser on the left, one pill per connection in
//! the centre (status dot, name, ✕; click to show, drag to reorder; the
//! word "webmux" when there are none), settings, connections and the menu
//! button (ruling N-16) on the right, all standard flat icon buttons.
//! Nothing on it takes keyboard focus: a click completes and the content
//! view keeps the keys (W-05).
//!
//! Pills are kept per entry and updated in place, so a status push during
//! a drag never destroys the widget under the pointer.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const hub = @import("hub.zig");
const menu = @import("menu.zig");

const log = std.log.scoped(.webmux_chrome);
const alloc = std.heap.c_allocator;

pub const Pill = struct {
    entry_id: u64,
    root: *gtk.Box,
    dot: *gtk.Widget,
    label: *gtk.Label,
    x: *gtk.Button,
    /// The state class currently on the dot.
    dot_class: [:0]const u8 = "unknown",
    drag_started: bool = false,
    drag_start_x: f64 = 0,
};

pub const Header = struct {
    root: *adw.HeaderBar,
    /// Shown in the centre while there are no pills.
    title: *gtk.Label,
    scroller: *gtk.ScrolledWindow,
    new_term: *gtk.Button,
    new_files: *gtk.Button,
    pills_box: *gtk.Box,
    settings: *gtk.Button,
    connections: *gtk.Button,
    menu_button: *gtk.MenuButton,
    pills: std.ArrayList(*Pill) = .empty,
    /// Pill being dragged (by entry id), and the slot it would land in.
    drag_id: ?u64 = null,
    drop_slot: ?usize = null,
    alive: bool = true,

    pub fn widget(h: *Header) *gtk.Widget {
        return h.root.as(gtk.Widget);
    }

    pub fn create() *Header {
        const h = alloc.create(Header) catch @panic("OOM");
        const root = adw.HeaderBar.new();
        const rw = root.as(gtk.Widget);
        rw.addCssClass("wm-header");
        rw.setFocusable(0);

        const new_term = button(themed("tab-new-symbolic", "list-add-symbolic"), "wm-newterm", "New terminal in a new column (Ctrl+Shift+Enter)");
        const new_files = button("folder-symbolic", "wm-newfiles", "New file browser in a new column (Ctrl+Shift+B)");
        root.packStart(new_term.as(gtk.Widget));
        root.packStart(new_files.as(gtk.Widget));

        const centre = gtk.Box.new(.horizontal, 0);
        const title = gtk.Label.new("webmux");
        title.as(gtk.Widget).addCssClass("title");
        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.external, .never);
        scroller.setPropagateNaturalWidth(1);
        scroller.as(gtk.Widget).addCssClass("wm-pills-scroll");
        scroller.as(gtk.Widget).setFocusable(0);
        const pills_box = gtk.Box.new(.horizontal, 6);
        pills_box.as(gtk.Widget).addCssClass("wm-pills");
        pills_box.as(gtk.Widget).setValign(.center);
        scroller.setChild(pills_box.as(gtk.Widget));
        centre.append(title.as(gtk.Widget));
        centre.append(scroller.as(gtk.Widget));
        root.setTitleWidget(centre.as(gtk.Widget));

        // Packed from the window controls inwards: menu, connections,
        // settings reads settings, connections, menu left to right.
        const settings = button("emblem-system-symbolic", "wm-settings", "Settings (Ctrl+,)");
        const connections = button("network-server-symbolic", "wm-connections", "Manage connections (Ctrl+Shift+O)");
        const mb = gtk.MenuButton.new();
        mb.setIconName("open-menu-symbolic");
        mb.as(gtk.Widget).addCssClass("wm-menubutton");
        mb.as(gtk.Widget).setTooltipText("Menu");
        mb.as(gtk.Widget).setFocusOnClick(0);
        mb.setMenuModel(menu.model());
        root.packEnd(mb.as(gtk.Widget));
        root.packEnd(connections.as(gtk.Widget));
        root.packEnd(settings.as(gtk.Widget));

        h.* = .{
            .root = root,
            .title = title,
            .scroller = scroller,
            .new_term = new_term,
            .new_files = new_files,
            .pills_box = pills_box,
            .settings = settings,
            .connections = connections,
            .menu_button = mb,
        };
        _ = gtk.Button.signals.clicked.connect(new_term, *Header, onNewTerm, h, .{});
        _ = gtk.Button.signals.clicked.connect(new_files, *Header, onNewFiles, h, .{});
        _ = gtk.Button.signals.clicked.connect(settings, *Header, onSettings, h, .{});
        _ = gtk.Button.signals.clicked.connect(connections, *Header, onConnections, h, .{});
        // The menu's popover hands focus back when it closes; make sure it
        // lands in the content view, not on the button.
        if (mb.getPopover()) |pop| _ = gtk.Popover.signals.closed.connect(pop, *Header, onMenuClosed, h, .{});
        h.update();
        return h;
    }

    /// `name` if the icon theme has it, else `bundled`, which must be one
    /// of the icons GTK carries in its own resources. Every other icon
    /// here is a bundled one, so the header never shows a missing-icon
    /// placeholder, whatever theme is (or is not) installed.
    fn themed(name: [:0]const u8, bundled: [:0]const u8) [:0]const u8 {
        const display = gdk.Display.getDefault() orelse return bundled;
        return if (gtk.IconTheme.getForDisplay(display).hasIcon(name.ptr) != 0) name else bundled;
    }

    fn button(icon: [:0]const u8, class: [:0]const u8, tip: [:0]const u8) *gtk.Button {
        const b = gtk.Button.newFromIconName(icon.ptr);
        const w = b.as(gtk.Widget);
        w.addCssClass(class.ptr);
        w.setTooltipText(tip.ptr);
        w.setFocusOnClick(0);
        w.setFocusable(0);
        return b;
    }

    pub fn destroyed(h: *Header) void {
        h.alive = false;
        for (h.pills.items) |p| alloc.destroy(p);
        h.pills.deinit(alloc);
        alloc.destroy(h);
    }

    // -- buttons (W-18): act on the visible host, then focus returns ------

    pub fn clickNewTerminal(_: *Header) void {
        if (hub.hub.active == null) return;
        hub.paneCommand("new-terminal");
    }
    pub fn clickNewFiles(_: *Header) void {
        if (hub.hub.active == null) return;
        hub.paneCommand("new-files");
    }
    /// Settings open with no host in front too (deviation 32, ruling on
    /// E-10).
    pub fn clickSettings(_: *Header) void {
        menu.activateApp(iface.actions.show_settings);
        hub.focusContent();
    }
    pub fn clickConnections(_: *Header) void {
        hub.userShow(null);
    }

    fn onNewTerm(_: *gtk.Button, h: *Header) callconv(.c) void {
        h.clickNewTerminal();
    }
    fn onNewFiles(_: *gtk.Button, h: *Header) callconv(.c) void {
        h.clickNewFiles();
    }
    fn onSettings(_: *gtk.Button, h: *Header) callconv(.c) void {
        h.clickSettings();
    }
    fn onConnections(_: *gtk.Button, h: *Header) callconv(.c) void {
        h.clickConnections();
    }
    fn onMenuClosed(_: *gtk.Popover, _: *Header) callconv(.c) void {
        // Back to what had focus before the menu opened (N1).
        hub.scheduleFocusRestore();
    }

    // -- render ------------------------------------------------------------

    pub fn update(h: *Header) void {
        if (!h.alive) return;
        const entries = hub.hub.entries.items;
        // Drop pills whose entry is gone.
        var i: usize = 0;
        while (i < h.pills.items.len) {
            const p = h.pills.items[i];
            if (hub.findId(p.entry_id) == null) {
                h.pills_box.remove(p.root.as(gtk.Widget));
                _ = h.pills.orderedRemove(i);
                if (h.drag_id == p.entry_id) h.endDrag();
                alloc.destroy(p);
            } else i += 1;
        }
        // Create, update, and order.
        var prev: ?*gtk.Widget = null;
        for (entries, 0..) |e, n| {
            const p = h.pillFor(e.id) orelse h.newPill(e) orelse continue;
            h.updatePill(p, e, n);
            if (h.drag_id == null) h.pills_box.reorderChildAfter(p.root.as(gtk.Widget), prev);
            prev = p.root.as(gtk.Widget);
        }
        // Keep h.pills in entry order too (drop-slot maths reads it).
        if (h.drag_id == null) {
            var k: usize = 0;
            for (entries) |e| {
                for (h.pills.items[k..], k..) |p, j| if (p.entry_id == e.id) {
                    std.mem.swap(*Pill, &h.pills.items[k], &h.pills.items[j]);
                    k += 1;
                    break;
                };
            }
        }

        // No pills: the centre says "webmux", like any title bar.
        const none = entries.len == 0;
        h.title.as(gtk.Widget).setVisible(@intFromBool(none));
        h.scroller.as(gtk.Widget).setVisible(@intFromBool(!none));

        const on_page = hub.hub.active == null;
        setClass(h.connections.as(gtk.Widget), "active", on_page);
        h.new_term.as(gtk.Widget).setSensitive(@intFromBool(!on_page));
        h.new_files.as(gtk.Widget).setSensitive(@intFromBool(!on_page));
        h.settings.as(gtk.Widget).setSensitive(1);
    }

    pub fn pillFor(h: *Header, id: u64) ?*Pill {
        for (h.pills.items) |p| if (p.entry_id == id) return p;
        return null;
    }

    fn newPill(h: *Header, e: *hub.Entry) ?*Pill {
        const p = alloc.create(Pill) catch return null;
        const root = gtk.Box.new(.horizontal, 7);
        const rw = root.as(gtk.Widget);
        rw.addCssClass("wm-pill");
        rw.setValign(.center);
        const dot = gtk.Box.new(.horizontal, 0);
        dot.as(gtk.Widget).addCssClass("wm-dot");
        dot.as(gtk.Widget).setValign(.center);
        const label = gtk.Label.new(null);
        // A long name never widens the header (N3); the tooltip has it.
        label.setEllipsize(.end);
        label.setMaxWidthChars(28);
        const x = gtk.Button.newWithLabel("✕");
        x.as(gtk.Widget).addCssClass("wm-x");
        x.as(gtk.Widget).setTooltipText("Disconnect");
        x.as(gtk.Widget).setFocusOnClick(0);
        x.as(gtk.Widget).setFocusable(0);
        root.append(dot.as(gtk.Widget));
        root.append(label.as(gtk.Widget));
        root.append(x.as(gtk.Widget));
        p.* = .{ .entry_id = e.id, .root = root, .dot = dot.as(gtk.Widget), .label = label, .x = x };

        _ = gtk.Button.signals.clicked.connect(x, *Pill, onPillX, p, .{});
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(gdk.BUTTON_PRIMARY);
        _ = gtk.GestureClick.signals.released.connect(click, *Pill, onPillReleased, p, .{});
        rw.addController(click.as(gtk.EventController));
        // The pill sits in the title bar, whose own drag moves the window:
        // the pill's gestures claim the press (onDragBegin) so a drag
        // reorders pills instead. Grouped, so the click shares the claim.
        const drag = gtk.GestureDrag.new();
        drag.as(gtk.Gesture).group(click.as(gtk.Gesture));
        drag.as(gtk.GestureSingle).setButton(gdk.BUTTON_PRIMARY);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Pill, onDragBegin, p, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Pill, onDragUpdate, p, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Pill, onDragEnd, p, .{});
        rw.addController(drag.as(gtk.EventController));

        h.pills_box.append(rw);
        h.pills.append(alloc, p) catch {};
        return p;
    }

    fn updatePill(_: *Header, p: *Pill, e: *hub.Entry, n: usize) void {
        var nb: [4096]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&nb, "{s}", .{e.name}, 0) catch "?";
        p.label.setText(name.ptr);
        // Pills never shrink (Electron `flex: none`): the row scrolls.
        // Only names over 28 characters are ellipsized.
        const chars: c_int = @intCast(@min(std.unicode.utf8CountCodepoints(e.name) catch e.name.len, 28));
        p.label.setWidthChars(chars);
        const rw = p.root.as(gtk.Widget);
        setClass(rw, "active", hub.hub.active == e);
        const cls: [:0]const u8 = dotClass(e);
        if (!std.mem.eql(u8, cls, p.dot_class)) {
            p.dot.removeCssClass(p.dot_class.ptr);
            p.dot.addCssClass(cls.ptr);
            p.dot_class = cls;
        }
        var tb: [4608]u8 = undefined;
        rw.setTooltipText(pillTooltip(e, n, &tb).ptr);
    }

    // -- pills: click, ✕, drag (W-15, W-16) ------------------------------

    /// A click on a pill shows that host.
    pub fn clickPill(_: *Header, id: u64) void {
        const e = hub.findId(id) orelse return;
        hub.userShow(e);
    }

    pub fn clickPillX(_: *Header, id: u64) void {
        const e = hub.findId(id) orelse return;
        hub.disconnect(e.name);
        hub.focusContent();
    }

    /// Start dragging a pill: it fades (`dragging`).
    pub fn beginDrag(h: *Header, id: u64) void {
        const p = h.pillFor(id) orelse return;
        h.drag_id = id;
        h.drop_slot = null;
        p.root.as(gtk.Widget).addCssClass("dragging");
    }

    /// The pointer is at `x` (pills-box coordinates): mark the slot.
    pub fn dragOver(h: *Header, x: f64) void {
        if (h.drag_id == null) return;
        h.clearDropMarks();
        var others_buf: [64]*Pill = undefined;
        const others = h.otherPills(&others_buf);
        if (others.len == 0) return;
        const slot = h.dropSlot(x, others);
        h.drop_slot = slot;
        if (slot < others.len)
            others[slot].root.as(gtk.Widget).addCssClass("drop-before")
        else
            others[others.len - 1].root.as(gtk.Widget).addCssClass("drop-after");
    }

    /// Drop at `x`: reorder optimistically and tell the engine (W-16).
    pub fn drop(h: *Header, x: f64) void {
        const id = h.drag_id orelse return;
        var others_buf: [64]*Pill = undefined;
        const others = h.otherPills(&others_buf);
        const slot = h.dropSlot(x, others);
        var names: [65][]const u8 = undefined;
        var n: usize = 0;
        for (others[0..@min(slot, others.len)]) |p| if (hub.findId(p.entry_id)) |e| {
            names[n] = e.name;
            n += 1;
        };
        if (hub.findId(id)) |e| {
            names[n] = e.name;
            n += 1;
        }
        for (others[@min(slot, others.len)..]) |p| if (hub.findId(p.entry_id)) |e| {
            names[n] = e.name;
            n += 1;
        };
        h.endDrag();
        hub.reorder(names[0..n]);
        hub.focusContent();
    }

    pub fn endDrag(h: *Header) void {
        if (h.drag_id) |id| if (h.pillFor(id)) |p| p.root.as(gtk.Widget).removeCssClass("dragging");
        h.drag_id = null;
        h.drop_slot = null;
        h.clearDropMarks();
    }

    fn clearDropMarks(h: *Header) void {
        for (h.pills.items) |p| {
            p.root.as(gtk.Widget).removeCssClass("drop-before");
            p.root.as(gtk.Widget).removeCssClass("drop-after");
        }
    }

    fn otherPills(h: *Header, buf: []*Pill) []*Pill {
        var n: usize = 0;
        for (h.pills.items) |p| {
            if (p.entry_id == h.drag_id) continue;
            if (n == buf.len) break;
            buf[n] = p;
            n += 1;
        }
        return buf[0..n];
    }

    /// How many other pills have their midpoint left of `x`.
    fn dropSlot(h: *Header, x: f64, others: []*Pill) usize {
        var n: usize = 0;
        for (others) |p| {
            const mid = h.pillMid(p) orelse continue;
            if (mid < x) n += 1;
        }
        return n;
    }

    /// A pill's horizontal midpoint in pills-box coordinates.
    pub fn pillMid(h: *Header, p: *Pill) ?f64 {
        var r: graphene.Rect = undefined;
        if (p.root.as(gtk.Widget).computeBounds(h.pills_box.as(gtk.Widget), &r) == 0) return null;
        return @as(f64, r.f_origin.f_x) + @as(f64, r.f_size.f_width) / 2;
    }

    fn onPillX(_: *gtk.Button, p: *Pill) callconv(.c) void {
        const h = hub.hub.header orelse return;
        h.clickPillX(p.entry_id);
    }

    fn onPillReleased(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, p: *Pill) callconv(.c) void {
        const h = hub.hub.header orelse return;
        if (h.drag_id != null) return;
        h.clickPill(p.entry_id);
    }

    fn onDragBegin(g: *gtk.GestureDrag, x: f64, y: f64, p: *Pill) callconv(.c) void {
        // A press on the ✕ is the button's: claiming it here would cancel
        // the button's own click.
        const xw = p.x.as(gtk.Widget);
        const on_x = if (p.root.as(gtk.Widget).pick(x, y, .{})) |t| t == xw or t.isAncestor(xw) != 0 else false;
        _ = g.as(gtk.Gesture).setState(if (on_x) .denied else .claimed);
        p.drag_started = false;
        p.drag_start_x = x;
    }

    fn pointInBox(h: *Header, p: *Pill, x: f64) f64 {
        const in: graphene.Point = .{ .f_x = @floatCast(x), .f_y = 0 };
        var out: graphene.Point = undefined;
        if (p.root.as(gtk.Widget).computePoint(h.pills_box.as(gtk.Widget), &in, &out) == 0) return x;
        return out.f_x;
    }

    fn onDragUpdate(_: *gtk.GestureDrag, dx: f64, _: f64, p: *Pill) callconv(.c) void {
        const h = hub.hub.header orelse return;
        if (!p.drag_started) {
            if (@abs(dx) < 8) return;
            p.drag_started = true;
            h.beginDrag(p.entry_id);
        }
        h.dragOver(h.pointInBox(p, p.drag_start_x + dx));
    }

    fn onDragEnd(_: *gtk.GestureDrag, dx: f64, _: f64, p: *Pill) callconv(.c) void {
        const h = hub.hub.header orelse return;
        if (!p.drag_started) return;
        p.drag_started = false;
        h.drop(h.pointInBox(p, p.drag_start_x + dx));
    }
};

pub fn setClass(w: *gtk.Widget, class: [:0]const u8, on: bool) void {
    if (on) w.addCssClass(class.ptr) else w.removeCssClass(class.ptr);
}

pub fn dotClass(e: *const hub.Entry) [:0]const u8 {
    if (e.status == null) return "unknown";
    return switch (e.state) {
        .connecting => "connecting",
        .connected => if (e.offline) "degraded" else "connected",
        .retry => "retry",
        .failed => "failed",
    };
}

/// W-14: `<name> — <state text>[ (Ctrl+<n>)]`.
pub fn pillTooltip(e: *const hub.Entry, n: usize, buf: []u8) [:0]const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print("{s} — ", .{e.name}) catch {};
    switch (e.state) {
        .connecting => w.writeAll("connecting…") catch {},
        .connected => w.writeAll(if (e.offline) "server unreachable — page retrying" else "connected") catch {},
        .retry => if (hub.retrySeconds(e)) |s|
            w.print("interrupted — retrying in {d}s", .{s}) catch {}
        else
            w.writeAll("interrupted — retrying") catch {},
        .failed => w.writeAll("connection failed") catch {},
    }
    if (n < 9) w.print(" (Ctrl+{d})", .{n + 1}) catch {};
    const len = w.end;
    buf[len] = 0;
    return buf[0..len :0];
}

comptime {
    _ = gobject;
    _ = log;
}
