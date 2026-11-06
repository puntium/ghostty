//! `iface.factories.files`: a file-browser pane (browser.zig) behind the
//! `iface.Pane` vtable. A files pane needs no server session; its state
//! (`{type, dir, cursor}`) comes back through `create` and goes out
//! through `saveState` (F-01, F-02).
const std = @import("std");
const Allocator = std.mem.Allocator;
const gtk = @import("gtk");

const iface = @import("../iface.zig");
const wire = @import("wire.zig");
const Browser = @import("browser.zig").Browser;

const log = std.log.scoped(.webmux_files);

pub fn create(c: *const iface.Conn, id: []const u8, state: ?[]const u8, host: iface.PaneHost) anyerror!iface.Pane {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const st = wire.parseState(arena.allocator(), state);
    const b = try Browser.new(.{
        .socket_path = c.socket_path,
        .conn_name = c.name,
        .id = id,
        .host = host,
        .dir = st.dir,
        .cursor = st.cursor,
    });
    log.debug("files pane {s} on {s}: {s}", .{ id, c.name, st.dir });
    return .{ .widget = b.as(gtk.Widget), .ctx = b, .vtable = &vtable };
}

const vtable: iface.Pane.VTable = .{
    .grabFocus = grabFocus,
    .title = title,
    .saveState = saveState,
    .setShown = setShown,
    .cellWidthPx = cellWidthPx,
    .fade = fade,
    .holdResize = holdResize,
};

fn browser(ctx: *anyopaque) *Browser {
    return @ptrCast(@alignCast(ctx));
}

fn grabFocus(ctx: *anyopaque) void {
    _ = browser(ctx).as(gtk.Widget).grabFocus();
}

fn title(ctx: *anyopaque) ?[:0]const u8 {
    return browser(ctx).getTitle();
}

fn saveState(ctx: *anyopaque, a: Allocator) Allocator.Error!?[]u8 {
    return try browser(ctx).saveState(a);
}

fn setShown(ctx: *anyopaque, shown: bool) void {
    browser(ctx).setShown(shown);
}

fn fade(_: *anyopaque, _: f32, _: [3]f32) ?iface.Pane.Rect {
    return null;
}

fn holdResize(_: *anyopaque, _: bool) void {}

fn cellWidthPx(_: *anyopaque) ?u32 {
    return null;
}
