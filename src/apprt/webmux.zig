//! The webmux-gtk application runtime ("apprt"): a GTK4/libadwaita shell
//! for the webmux client, replacing Ghostty's own GTK shell.
//!
//! Selected at compile time by `zig build -Dwebmux=true` (see WEBMUX.md
//! › Build). `src/apprt.zig` resolves `apprt.runtime` to this file when the
//! `webmux` build option is present; `build_config.app_runtime` stays `.gtk`
//! so every core type that registers itself with GObject keeps working.
//!
//! Nothing in here imports from `src/apprt/gtk/`. Files that started life as
//! copies of the stock shell say so in their header.

// The required comptime API for any apprt.
pub const App = @import("webmux/App.zig");
pub const Surface = @import("webmux/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

// The shell's own exported API.
pub const Application = @import("webmux/application.zig").Application;
pub const Window = @import("webmux/window.zig").Window;
pub const TerminalPane = @import("webmux/pane.zig").TerminalPane;
pub const mainloop = @import("webmux/mainloop.zig");
pub const control = @import("webmux/control.zig");
pub const WeakRef = @import("webmux/weak_ref.zig").WeakRef;
pub const iface = @import("webmux/iface.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("webmux/mainloop.zig");
    _ = @import("webmux/control.zig");
    _ = @import("webmux/config.zig");
    _ = @import("webmux/shortcuts.zig");
    _ = @import("webmux/iface_test.zig");
    _ = @import("webmux/terminal/remote.zig");
    _ = @import("webmux/terminal/links.zig");
    _ = @import("webmux/terminal/selection.zig");
    _ = @import("webmux/workspace/tests.zig");
    _ = @import("webmux/perf.zig");
    _ = @import("webmux/chrome/tests.zig");
    _ = @import("webmux/terminal/clipboard.zig");
    _ = @import("webmux/panels/model.zig");
    _ = @import("webmux/files/markdown.zig");
    _ = @import("webmux/files/paths.zig");
    _ = @import("webmux/files/wire.zig");
    _ = @import("webmux/files/uploads.zig");
    _ = @import("webmux/files/savefile.zig");
}
