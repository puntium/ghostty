//! Makes the compiler analyse every declaration of iface.zig (the lead's
//! seams file, which must not be edited here), including the nested
//! namespaces and vtable types.
const std = @import("std");
const iface = @import("iface.zig");

test "iface: every declaration compiles" {
    std.testing.refAllDecls(iface);
    std.testing.refAllDecls(iface.Conn);
    std.testing.refAllDecls(iface.PaneHost);
    std.testing.refAllDecls(iface.PaneHost.VTable);
    std.testing.refAllDecls(iface.Pane);
    std.testing.refAllDecls(iface.Pane.VTable);
    std.testing.refAllDecls(iface.PaneFactory);
    std.testing.refAllDecls(iface.factories);
    std.testing.refAllDecls(iface.hooks);
    std.testing.refAllDecls(iface.actions);
    std.testing.refAllDecls(iface.WorkspaceFactory);
    std.testing.refAllDecls(iface.WorkspaceHost);
    std.testing.refAllDecls(iface.WorkspaceHost.VTable);
    std.testing.refAllDecls(iface.Workspace);
    std.testing.refAllDecls(iface.Workspace.VTable);
    std.testing.refAllDecls(iface.settings);
    std.testing.refAllDecls(iface.settings.Listener);
    std.testing.refAllDecls(iface.services);
    _ = iface.factories.get(.terminal);
    _ = iface.settings.get();
}

test "iface: services defaults and settings fan-out" {
    iface.services.status(null, "test status");
    iface.services.status("dev", "test status");
    iface.services.url("https://example.invalid", .choose, null);
    iface.services.connLog(.info, "dev", "test", null);

    const S = struct {
        var calls: usize = 0;
        fn changed(_: *anyopaque, _: *const @import("../../webmux/conn.zig").Settings) void {
            calls += 1;
        }
    };
    var ctx: u8 = 0;
    try std.testing.expect(iface.settings.subscribe(.{ .ctx = &ctx, .changed = S.changed }));
    iface.settings.set(iface.settings.get());
    try std.testing.expectEqual(@as(usize, 1), S.calls);
    iface.settings.unsubscribe(&ctx);
    iface.settings.set(iface.settings.get());
    try std.testing.expectEqual(@as(usize, 1), S.calls);
}

test "terminal factory registers" {
    @import("terminal/factory.zig").register();
    try std.testing.expect(iface.factories.get(.terminal) != null);
    try std.testing.expect(iface.factories.get(.files) == null);
}
