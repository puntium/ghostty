//! Every control-socket command set in the app. Each feature registers its
//! commands from its own file; add one line here per file.

pub fn registerAll() void {
    @import("core_commands.zig").register();
    @import("../chrome/control.zig").register();
    // @import("../layout/control.zig").register();
    @import("../workspace/control.zig").register();
    @import("../panels/control.zig").register();
    @import("../files/control.zig").register();
}
