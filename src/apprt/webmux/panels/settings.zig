//! Client-wide settings: the one writer of `iface.settings` (PARITY
//! E-01…E-07, E-15).
//!
//! A change is applied at once everywhere: `iface.settings.set` (the
//! workspace listens for the fade and the column widths), the terminal
//! colours and libadwaita's light/dark (`Application.setScheme`), and every
//! panel that shows settings. It is persisted through the connection
//! engine's settings store (`iface.engine`, config.json `settings`); with
//! no engine the settings live in memory only.
//!
//! Startup (E-07): `load()` reads the stored settings and applies them; the
//! chrome calls it right after creating the engine, before the first
//! window is presented. Unreadable settings are defaults (the engine
//! already falls back), and nothing waits.
//!
//! Re-applying is idempotent (E-06): `external` (for the chrome's engine
//! `.settings` event) does nothing when the settings are unchanged, so our
//! own write coming back is not a second change.
const std = @import("std");
const conn = @import("../../../webmux/conn.zig");
const iface = @import("../iface.zig");
const Application = @import("../application.zig").Application;
const termconfig = @import("../config.zig");
const model = @import("model.zig");

const log = std.log.scoped(.webmux_panels);

/// Writes made through the engine (for the control socket and tests).
pub var persisted: u64 = 0;
/// Whether `load` ran (the panel opens with what is applied either way).
pub var loaded: bool = false;
/// Where the last load came from.
pub var source: enum { defaults, engine } = .defaults;

/// Hooks other panels register to follow changes (the settings panel's
/// controls). Called after `iface.settings` has the new value.
pub var on_change: ?*const fn (s: *const conn.Settings) void = null;

pub fn current() conn.Settings {
    return iface.settings.get();
}

/// Read the stored settings (or defaults) and apply them.
pub fn load() void {
    const s: conn.Settings = if (iface.engine) |e| e.settings() else .{};
    source = if (iface.engine != null) .engine else .defaults;
    loaded = true;
    apply(model.normalize(s), true);
    const n = current();
    log.info("settings loaded ({t}): theme={s} fade={d} cols={d}..{d}", .{ source, n.theme.slice(), n.unfocused_fade, n.min_cols, n.max_cols });
}

/// Apply a partial change; `persist` also saves it (a slider drag
/// previews with `persist = false` and saves when it settles).
pub fn update(patch: conn.SettingsPatch, persist: bool) conn.Settings {
    var next = model.applyPatch(current(), patch);
    if (persist) next = save(next);
    apply(next, false);
    return current();
}

/// Persist what is applied now (after a preview).
pub fn persistCurrent() void {
    const s = save(current());
    apply(s, false);
}

fn save(s: conn.Settings) conn.Settings {
    const e = iface.engine orelse return s;
    persisted += 1;
    // The engine sanitizes again (main.js rules) and keeps any valid id;
    // what we apply is our normalized view of what it stored.
    return model.normalize(e.updateSettings(model.toPatch(&s)));
}

/// The settings changed outside the panels (the chrome forwards the
/// engine's `.settings` event here). Idempotent.
pub fn external(s: *const conn.Settings) void {
    apply(model.normalize(s.*), false);
}

fn apply(next: conn.Settings, force: bool) void {
    const old = current();
    if (force or !model.eql(&old, &next)) {
        iface.settings.set(next);
        if (on_change) |f| f(&next);
    }
    applyScheme(&next);
}

/// The terminal scheme and the app's light/dark follow the theme.
fn applyScheme(s: *const conn.Settings) void {
    const want: termconfig.Scheme = if (model.themeOf(s).dark) .dark else .light;
    const app = Application.default();
    if (app.getScheme() == want) return;
    app.setScheme(want) catch |err| log.warn("could not switch the colour scheme: {t}", .{err});
}
