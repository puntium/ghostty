//! The one place every feature area registers itself at application start
//! (`Application.startup`, before the first window exists). Same pattern as
//! control/commands.zig: each area exposes `pub fn register() void` in its
//! own directory and adds one line here. A register() sets its entries in
//! `iface` (factories, workspace_factory, services) and nothing else; it
//! must not create widgets.

pub fn registerAll() void {
    @import("terminal/factory.zig").register();
    @import("workspace/register.zig").register();
    @import("files/register.zig").register();
    @import("chrome/register.zig").register();
    @import("panels/register.zig").register();
}
