//! Label text without Pango's inserted hyphens: a wrapping label breaks
//! long words (host names, paths) but must not draw a '-' that is not in
//! the text (a host name may contain '-'). Through markup, because a Pango
//! attribute list would need a direct libpango call (as panels/url.zig).
const std = @import("std");
const glib = @import("glib");
const gtk = @import("gtk");

const alloc = std.heap.c_allocator;

/// Set `text` (plain, any length) on a wrapping label, hyphen-free.
pub fn set(label: *gtk.Label, text: []const u8) void {
    const z = alloc.dupeSentinel(u8, text, 0) catch return;
    defer alloc.free(z);
    const escaped = glib.markupEscapeText(z.ptr, -1);
    defer glib.free(escaped);
    const markup = std.fmt.allocPrintSentinel(alloc, "<span insert_hyphens=\"false\">{s}</span>", .{std.mem.span(escaped)}, 0) catch return;
    defer alloc.free(markup);
    label.setMarkup(markup.ptr);
}

/// The same for text that is already markup (static, trusted).
pub fn setMarkup(label: *gtk.Label, comptime markup: []const u8) void {
    label.setMarkup("<span insert_hyphens=\"false\">" ++ markup ++ "</span>");
}

/// A new wrapping label (word, then anywhere), hyphen-free.
pub fn wrapping(text: []const u8) *gtk.Label {
    const l = gtk.Label.new(null);
    l.setWrap(1);
    l.setWrapMode(.word_char);
    set(l, text);
    return l;
}
