//! webmux-gtk workspace layout: the pure model behind the strip of columns
//! (no GTK). See `layout/Layout.zig` for the model and its commands,
//! `layout/width.zig` for the width rule and geometry, `layout/change.zig`
//! for animation change descriptions, and `layout/persist.zig` for the
//! saved file and startup reconciliation.
//!
//! Test: `zig test src/webmux/layout.zig`.

pub const Layout = @import("layout/Layout.zig");
pub const width = @import("layout/width.zig");
pub const change = @import("layout/change.zig");
pub const persist = @import("layout/persist.zig");

pub const Pane = Layout.Pane;
pub const Column = Layout.Column;
pub const Kind = Layout.Kind;
pub const Command = Layout.Command;
pub const Snapshot = change.Snapshot;
pub const Change = change.Change;

test {
    _ = Layout;
    _ = width;
    _ = change;
    _ = persist;
    _ = @import("layout/test_layout.zig");
    _ = @import("layout/test_width.zig");
    _ = @import("layout/test_change.zig");
    _ = @import("layout/test_persist.zig");
    _ = @import("layout/test_trace.zig");
}
