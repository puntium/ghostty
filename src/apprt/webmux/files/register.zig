//! The file browser's registrations (one line in features.zig).
const iface = @import("../iface.zig");
const factory = @import("factory.zig");

pub fn register() void {
    iface.factories.files = .{ .create = factory.create };
}
