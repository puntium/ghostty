//! The workspace's display-free tests:
//!   nix develop . -c zig test -lc src/apprt/webmux/workspace/tests.zig
test {
    _ = @import("anim.zig");
    _ = @import("geometry.zig");
    _ = @import("minimap.zig");
    _ = @import("store.zig");
}
