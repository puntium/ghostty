//! webmux: the link configuration both webmux shells apply after
//! `Config.finalize` (the GTK shell in `apprt/webmux/config.zig`, the
//! native macOS client through `ghostty_config_webmux_links`). It cannot
//! be expressed in config-file syntax: `link` has no `parseCLI`
//! (`RepeatableLink`), and Ghostty's default URL link needs Ctrl/⌘ for
//! both the underline and the click, where xterm.js's web-links addon
//! (the Electron client, gtk/PARITY.md T-24/T-25) needs no modifier.
const Config = @import("Config.zig");

/// xterm.js web-links addon's URL regex (@xterm/addon-web-links,
/// `strictUrlRegex`), in Oniguruma syntax: http(s) only, no trailing
/// punctuation. NUL is excluded as well: the renderer writes an empty
/// cell as U+0000 (`RenderState.string`), so without it the underline of
/// a URL that ends its row would run on to the right edge.
pub const url_regex =
    \\(?:https?|HTTPS?)://[^\s\x00"'!*(){}|\\\^<>`]*[^\s\x00"':,.!?{}|\\\^~\[\]`()<>]
;

/// URLs underline and click without a modifier, like xterm.js's
/// web-links addon (Ghostty's default needs Ctrl). Only http(s) URLs,
/// matched like the web-links addon (anything else is inert in the
/// Electron client, PARITY T-25). Call after `finalize` (which drops the
/// default link when `link-url` is false); a no-op when it is.
pub fn links(config: *Config) void {
    if (!config.@"link-url") return;
    if (config.link.links.items.len == 0) return;
    config.link.links.items[0].highlight = .hover;
    config.link.links.items[0].regex = url_regex;
}
