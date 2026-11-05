//! The terminal pane factory (`iface.factories.terminal`): a TerminalPane
//! attached to a host session, wrapped in the `iface.Pane` vtable, with
//! its signals forwarded to the container's `iface.PaneHost`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const TerminalPane = @import("../pane.zig").TerminalPane;

const log = std.log.scoped(.webmux_terminal);
const alloc = std.heap.c_allocator;

/// Called once at application start from features.zig. Also installs
/// `iface.hooks.clipboardSync` (terminal/clipboard.zig).
pub fn register() void {
    iface.factories.terminal = .{ .create = create };
    @import("clipboard.zig").register();
}

/// The vtable's ctx. Lives exactly as long as the pane: freed by a weak
/// notify when the pane is finalized.
const Adapter = struct {
    pane: *TerminalPane,
    host: iface.PaneHost,
    id: []u8,
};

fn create(
    c: *const iface.Conn,
    id: []const u8,
    state: ?[]const u8,
    host: iface.PaneHost,
) anyerror!iface.Pane {
    // Terminal panes persist nothing; whatever an older run saved is
    // ignored.
    _ = state;

    const adapter = try alloc.create(Adapter);
    errdefer alloc.destroy(adapter);
    const id_copy = try alloc.dupe(u8, id);
    errdefer alloc.free(id_copy);

    const pane = TerminalPane.new(.{ .remote = .{
        .socket_path = c.socket_path,
        .session_id = id,
        .conn_name = c.name,
    } });
    adapter.* = .{ .pane = pane, .host = host, .id = id_copy };

    gobject.Object.weakRef(pane.as(gobject.Object), onPaneFinalized, adapter);
    _ = gobject.Object.signals.notify.connect(pane, *Adapter, onTitle, adapter, .{ .detail = "title" });
    _ = gobject.Object.signals.notify.connect(pane, *Adapter, onFocused, adapter, .{ .detail = "focused" });
    _ = TerminalPane.signals.@"close-request".connect(pane, *Adapter, onCloseRequest, adapter, .{});
    _ = TerminalPane.signals.@"link-changed".connect(pane, *Adapter, onLinkChanged, adapter, .{});

    log.debug("terminal pane created conn={s} session={s}", .{ c.name, id });
    return .{
        .widget = pane.as(gtk.Widget),
        .ctx = adapter,
        .vtable = &vtable,
    };
}

const vtable: iface.Pane.VTable = .{
    .grabFocus = grabFocus,
    .title = title,
    .saveState = saveState,
    .setShown = setShown,
    .cellWidthPx = cellWidthPx,
};

fn fromCtx(ctx: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(ctx));
}

fn grabFocus(ctx: *anyopaque) void {
    fromCtx(ctx).pane.grabFocus();
}

fn title(ctx: *anyopaque) ?[:0]const u8 {
    return fromCtx(ctx).pane.getTitle();
}

fn saveState(ctx: *anyopaque, a: Allocator) Allocator.Error!?[]u8 {
    _ = ctx;
    _ = a;
    return null;
}

fn setShown(ctx: *anyopaque, shown: bool) void {
    fromCtx(ctx).pane.setShown(shown);
}

fn cellWidthPx(ctx: *anyopaque) ?u32 {
    const pane = fromCtx(ctx).pane;
    const surface = pane.core() orelse return null;
    const w = surface.size.cell.width;
    return if (w == 0) null else w;
}

fn onTitle(_: *TerminalPane, _: *gobject.ParamSpec, self: *Adapter) callconv(.c) void {
    self.host.titleChanged(self.id);
}

fn onFocused(pane: *TerminalPane, _: *gobject.ParamSpec, self: *Adapter) callconv(.c) void {
    if (pane.getFocused()) self.host.focusEntered(self.id);
}

fn onCloseRequest(_: *TerminalPane, self: *Adapter) callconv(.c) void {
    self.host.closeRequested(self.id);
}

fn onLinkChanged(_: *TerminalPane, up: c_int, self: *Adapter) callconv(.c) void {
    self.host.linkChanged(self.id, up != 0);
}

fn onPaneFinalized(data: ?*anyopaque, _: *gobject.Object) callconv(.c) void {
    const self: *Adapter = @ptrCast(@alignCast(data.?));
    alloc.free(self.id);
    alloc.destroy(self);
}
