//! webmux: the C entry points the native macOS client (mac/ in the webmux
//! repo) needs beyond the seam in embedded.zig, for the pane behaviours
//! the GTK shell implements in `apprt/webmux/pane.zig` from the core's
//! state. Each mirrors one GTK function, named in its doc comment; the
//! pure parts are shared (`apprt/webmux/terminal/links.zig`). Pulled into
//! the library by the `comptime` reference in `embedded.CAPI`.
//!
//! Positions are the view coordinates `ghostty_surface_mouse_pos` takes
//! (unscaled, origin top-left); the content scale is applied here.
const std = @import("std");
const embedded = @import("../embedded.zig");
const Surface = embedded.Surface;
const global = @import("../../global.zig");
const String = @import("../../main_c.zig").String;
const links = @import("../webmux/terminal/links.zig");

const log = std.log.scoped(.webmux_capi);

/// The viewport cell under an unscaled view position, or null outside
/// the grid. Caller holds the renderer mutex (`core.size` is read).
fn cellAt(surface: *Surface, x: f64, y: f64) ?links.Cell {
    const scale = surface.getContentScale() catch return null;
    return links.cellAt(surface.core_surface.size, x * scale.x, y * scale.y);
}

/// True while the program has the kitty keyboard protocol enabled on
/// the active screen (what `pane.zig` `encodeKey` checks): the shell then
/// leaves every key to Ghostty's encoder instead of applying the xterm.js
/// fixups (PARITY T-13).
export fn ghostty_surface_webmux_kitty_keyboard(surface: *Surface) bool {
    const core = &surface.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    const flags = core.renderer_state.terminal.screens.active.kitty_keyboard.current();
    return @as(u5, @bitCast(flags)) != 0;
}

/// The OSC 8 hyperlink URI at the cell under a view position
/// (`pane.zig` `updateOsc8Hover`; T-25). Empty (`ptr == NULL`) when the
/// cell carries no hyperlink or lies outside the grid. Free the result
/// with `ghostty_string_free`. The core only reports OSC 8 links with
/// Ctrl/⌘ held; the shell tracks them itself for the pointer cursor and
/// the plain click.
export fn ghostty_surface_webmux_osc8_at(surface: *Surface, x: f64, y: f64) String {
    const core = &surface.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    const cell = cellAt(surface, x, y) orelse return .empty;
    const uri = links.osc8At(global.alloc(), core.renderer_state.terminal, cell) orelse return .empty;
    return .fromSlice(uri);
}

/// T-20: Alt+click (no drag) on the viewport moves the shell's cursor to
/// the clicked cell by sending arrow keys, as xterm.js's
/// `altClickMovesCursor` (`pane.zig` `altClickMoveCursor`, the arrows from
/// `links.moveToCell`). Nothing is sent, and false returned, when the
/// program has mouse reporting on (the click was its), the viewport is
/// scrolled up, the position is outside the grid, or the cell is the
/// cursor's. The shell checks the modifiers and that press and release
/// landed on the same cell.
export fn ghostty_surface_webmux_alt_click(surface: *Surface, x: f64, y: f64) bool {
    const core = &surface.core_surface;
    const alloc = global.alloc();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const t = core.renderer_state.terminal;
        if (t.flags.mouse_event != .none) return false;
        const target = cellAt(surface, x, y) orelse return false;
        // Only with the viewport at the bottom (xterm: ybase == ydisp).
        const sb = t.screens.active.pages.scrollbar();
        if (sb.offset + sb.len < sb.total) return false;
        const cursor = t.screens.active.cursor;
        links.moveToCell(
            &out,
            alloc,
            .{ .col = cursor.x, .row = cursor.y },
            target,
            @intCast(t.cols),
            t.screens.active_key == .primary,
            t.modes.get(.cursor_keys),
        ) catch return false;
    }
    if (out.items.len == 0) return false;
    // Escape for the `text:` binding parser (\x1b).
    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(alloc);
    for (out.items) |b| {
        if (b == 0x1b) esc.appendSlice(alloc, "\\x1b") catch return false else esc.append(alloc, b) catch return false;
    }
    _ = core.performBindingAction(.{ .text = esc.items }) catch |err| {
        log.warn("alt-click cursor move failed err={}", .{err});
        return false;
    };
    return true;
}
