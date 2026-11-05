//! Rendered markdown for the preview column: a `markdown.Doc` turned into
//! a GTK widget tree (labels with Pango markup for text, a grid for
//! tables, pictures for images). Typography follows index.html's
//! `.files-md` rules (files.css). Raw HTML is shown as text; links and
//! images go back to the browser through `Host`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const md = @import("markdown.zig");
const scrolling = @import("scrolling.zig");
const paths = @import("paths.zig");

pub const Host = struct {
    ctx: *anyopaque,
    /// Fetch the local file `path` and show it in `picture` (async).
    loadImage: *const fn (ctx: *anyopaque, path: []const u8, picture: *gtk.Picture) void,
    /// A link was clicked (`shift`: with Shift held).
    activateLink: *const fn (ctx: *anyopaque, href: []const u8, shift: bool) void,
};

/// Per-view state reachable from signal handlers; freed with the root.
const View = struct {
    alloc: Allocator,
    host: Host,
    /// Modifier state of the last button press anywhere in the view
    /// (GtkLabel's activate-link carries no event).
    shift: bool = false,
    /// Link targets of clickable pictures, owned here.
    hrefs: std.ArrayList([:0]u8) = .empty,
    /// The markup of every label with links (index + 1 in "md-markup").
    markups: std.ArrayList([:0]u8) = .empty,
    /// The label whose link is underlined under the pointer, and its href.
    hover_label: ?*gtk.Label = null,
    hover_uri: ?[:0]u8 = null,
    dark: bool = true,
};

/// Build the widget for `doc`. `file_dir` resolves relative images.
pub fn build(alloc: Allocator, doc: *const md.Doc, file_dir: []const u8, host: Host, dark: bool) !*gtk.Widget {
    const view = try alloc.create(View);
    view.* = .{ .alloc = alloc, .host = host, .dark = dark };
    const root = vbox();
    root.as(gtk.Widget).addCssClass("files-md");
    gobject.Object.weakRef(root.as(gobject.Object), onRootFinalized, view);

    const gc = gtk.GestureClick.new();
    gc.as(gtk.GestureSingle).setButton(0);
    gc.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.GestureClick.signals.pressed.connect(gc, *View, onPressed, view, .{});
    root.as(gtk.Widget).addController(gc.as(gtk.EventController));

    var b: Builder = .{ .alloc = alloc, .view = view, .file_dir = file_dir, .dark = dark };
    try b.blocks(root, doc.blocks, 0, false);
    return root.as(gtk.Widget);
}

fn onRootFinalized(data: ?*anyopaque, _: *gobject.Object) callconv(.c) void {
    const view: *View = @ptrCast(@alignCast(data.?));
    for (view.hrefs.items) |h| view.alloc.free(h);
    view.hrefs.deinit(view.alloc);
    for (view.markups.items) |m| view.alloc.free(m);
    view.markups.deinit(view.alloc);
    if (view.hover_uri) |u| view.alloc.free(u);
    view.alloc.destroy(view);
}

fn onPressed(gc: *gtk.GestureClick, _: c_int, _: f64, _: f64, view: *View) callconv(.c) void {
    const state = gc.as(gtk.EventController).getCurrentEventState();
    view.shift = state.shift_mask;
}

fn onActivateLink(_: *gtk.Label, uri: [*:0]u8, view: *View) callconv(.c) c_int {
    view.host.activateLink(view.host.ctx, std.mem.span(uri), view.shift);
    return 1; // handled: never the default launcher
}

fn onPictureClicked(gc: *gtk.GestureClick, _: c_int, _: f64, _: f64, view: *View) callconv(.c) void {
    const w = gc.as(gtk.EventController).getWidget() orelse return;
    const idx: usize = @intFromPtr(gobject.Object.getData(w.as(gobject.Object), "md-href") orelse return) - 1;
    if (idx >= view.hrefs.items.len) return;
    const state = gc.as(gtk.EventController).getCurrentEventState();
    view.host.activateLink(view.host.ctx, view.hrefs.items[idx], state.shift_mask);
}

fn vbox() *gtk.Box {
    return gtk.Box.new(.vertical, 0);
}

fn hbox() *gtk.Box {
    return gtk.Box.new(.horizontal, 0);
}

const Builder = struct {
    alloc: Allocator,
    view: *View,
    file_dir: []const u8,
    dark: bool,

    fn blocks(b: *Builder, parent: *gtk.Box, bs: []const md.Block, depth: usize, tight: bool) Allocator.Error!void {
        for (bs, 0..) |blk, i| {
            const w = try b.block(blk, depth);
            const widget = w orelse continue;
            widget.addCssClass("md-block");
            if (i == 0) widget.addCssClass("md-first");
            if (tight and (blk == .paragraph or blk == .list)) widget.addCssClass("md-tight");
            if (i == bs.len - 1) widget.addCssClass("md-tight");
            parent.append(widget);
        }
    }

    fn block(b: *Builder, blk: md.Block, depth: usize) Allocator.Error!?*gtk.Widget {
        switch (blk) {
            .heading => |h| {
                const l = try b.markupLabel(h.content);
                l.as(gtk.Widget).addCssClass("md-h");
                var cls: [8:0]u8 = undefined;
                const name = std.fmt.bufPrintSentinel(&cls, "md-h{d}", .{h.level}, 0) catch unreachable;
                l.as(gtk.Widget).addCssClass(name.ptr);
                return l.as(gtk.Widget);
            },
            .paragraph => |p| return try b.paragraph(p),
            .html => |text| {
                const z = try b.alloc.dupeSentinel(u8, text, 0);
                defer b.alloc.free(z);
                const l = gtk.Label.new(null);
                setPlainText(l, z.ptr);
                textLabel(l);
                return l.as(gtk.Widget);
            },
            .code => |c| {
                const z = try b.alloc.dupeSentinel(u8, c.text, 0);
                defer b.alloc.free(z);
                const l = gtk.Label.new(z.ptr);
                l.setXalign(0);
                l.setYalign(0);
                l.as(gtk.Widget).setHalign(.start);
                const sw = gtk.ScrolledWindow.new();
                scrolling.install(sw, false);
                sw.setPolicy(.automatic, .never);
                sw.setPropagateNaturalHeight(1);
                sw.setChild(l.as(gtk.Widget));
                scrolling.noScrollToFocus(sw);
                @import("browser.zig").Browser.naturalScroll(sw);
                sw.as(gtk.Widget).addCssClass("md-pre");
                return sw.as(gtk.Widget);
            },
            .quote => |q| {
                const box = vbox();
                box.as(gtk.Widget).addCssClass("md-quote");
                try b.blocks(box, q, depth, false);
                return box.as(gtk.Widget);
            },
            .list => |l| return try b.list(l, depth),
            .table => |t| return try b.table(t),
            .hr => {
                const s = gtk.Separator.new(.horizontal);
                s.as(gtk.Widget).addCssClass("md-hr");
                return s.as(gtk.Widget);
            },
        }
    }

    fn list(b: *Builder, l: md.List, depth: usize) Allocator.Error!*gtk.Widget {
        const box = vbox();
        box.as(gtk.Widget).addCssClass("md-list");
        const bullets = [_][:0]const u8{ "•", "◦", "▪" };
        for (l.items, 0..) |item, i| {
            const row = hbox();
            row.as(gtk.Widget).addCssClass("md-li");
            var mbuf: [16:0]u8 = undefined;
            const marker: [:0]const u8 = if (l.ordered)
                std.fmt.bufPrintSentinel(&mbuf, "{d}.", .{@as(u64, l.start) + i}, 0) catch "•"
            else
                bullets[@min(depth, bullets.len - 1)];
            const ml = gtk.Label.new(marker.ptr);
            ml.setXalign(1);
            ml.setYalign(0);
            ml.as(gtk.Widget).setValign(.start);
            ml.as(gtk.Widget).addCssClass("md-marker");
            row.append(ml.as(gtk.Widget));
            if (item.task) |checked| {
                const cb = gtk.CheckButton.new();
                cb.setActive(@intFromBool(checked));
                cb.as(gtk.Widget).setSensitive(0);
                cb.as(gtk.Widget).setFocusable(0);
                cb.as(gtk.Widget).setValign(.start);
                cb.as(gtk.Widget).addCssClass("md-task");
                row.append(cb.as(gtk.Widget));
            }
            const content = vbox();
            content.as(gtk.Widget).setHexpand(1);
            try b.blocks(content, item.blocks, depth + 1, l.tight);
            row.append(content.as(gtk.Widget));
            box.append(row.as(gtk.Widget));
        }
        return box.as(gtk.Widget);
    }

    fn table(b: *Builder, t: md.Table) Allocator.Error!*gtk.Widget {
        const grid = gtk.Grid.new();
        grid.as(gtk.Widget).addCssClass("md-table");
        // Both alignments set: with halign START and valign FILL, GTK
        // measures a widget's width for its allocated height
        // (gtk_widget_adjust_size_allocation), which a wrapping grid
        // cannot answer consistently ("Trying to measure GtkGrid … for
        // height of 95, but it needs at least 410", D6).
        grid.as(gtk.Widget).setHalign(.start);
        grid.as(gtk.Widget).setValign(.start);
        for (t.head, 0..) |hc, c| {
            const l = try b.cell(hc, t.aligns[c]);
            l.as(gtk.Widget).addCssClass("md-th");
            grid.attach(l.as(gtk.Widget), @intCast(c), 0, 1, 1);
        }
        for (t.rows, 0..) |row, r| {
            for (row, 0..) |rc, c| {
                const l = try b.cell(rc, t.aligns[c]);
                grid.attach(l.as(gtk.Widget), @intCast(c), @intCast(r + 1), 1, 1);
            }
        }
        return grid.as(gtk.Widget);
    }

    fn cell(b: *Builder, content: md.Cell, al: md.Align) Allocator.Error!*gtk.Label {
        const l = try b.markupLabel(content);
        l.as(gtk.Widget).addCssClass("md-cell");
        l.setYalign(0);
        l.setXalign(switch (al) {
            .center => 0.5,
            .right => 1,
            else => 0,
        });
        return l;
    }

    /// A paragraph: one label, unless it holds images, which are shown as
    /// pictures (a row of them when the paragraph is nothing but images,
    /// as READMEs do with badges).
    fn paragraph(b: *Builder, p: []const md.Inline) Allocator.Error!*gtk.Widget {
        var has_image = false;
        var only_images = true;
        for (p) |n| {
            if (imageOf(n) != null) {
                has_image = true;
            } else if (!isBlankInline(n)) only_images = false;
        }
        if (!has_image) return (try b.markupLabel(p)).as(gtk.Widget);

        const box: *gtk.Box = if (only_images) hbox() else vbox();
        if (only_images) {
            box.setSpacing(4);
            const flow = gtk.FlowBox.new();
            flow.setSelectionMode(.none);
            flow.setHomogeneous(0);
            flow.setColumnSpacing(4);
            flow.setRowSpacing(4);
            flow.setMaxChildrenPerLine(64);
            flow.as(gtk.Widget).setFocusable(0);
            for (p) |n| {
                const im = imageOf(n) orelse continue;
                const pic = try b.picture(im.image, im.href);
                flow.append(pic);
                if (flow.as(gtk.Widget).getLastChild()) |child| child.setFocusable(0);
            }
            return flow.as(gtk.Widget);
        }
        var run: std.ArrayList(md.Inline) = .empty;
        defer run.deinit(b.alloc);
        for (p) |n| {
            if (imageOf(n)) |im| {
                if (run.items.len > 0) {
                    box.append((try b.markupLabel(run.items)).as(gtk.Widget));
                    run.clearRetainingCapacity();
                }
                box.append(try b.picture(im.image, im.href));
            } else if (!(run.items.len == 0 and isBlankInline(n))) try run.append(b.alloc, n);
        }
        if (run.items.len > 0) box.append((try b.markupLabel(run.items)).as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    const ImageRef = struct { image: @FieldType(md.Inline, "image"), href: ?[]const u8 };

    fn imageOf(n: md.Inline) ?ImageRef {
        switch (n) {
            .image => |im| return .{ .image = im, .href = null },
            .link => |l| {
                var found: ?ImageRef = null;
                for (l.content) |c| {
                    if (c == .image) {
                        if (found != null) return null;
                        found = .{ .image = c.image, .href = l.href };
                    } else if (!isBlankInline(c)) return null;
                }
                return found;
            },
            else => return null,
        }
    }

    fn isBlankInline(n: md.Inline) bool {
        return switch (n) {
            .text => |t| std.mem.trim(u8, t, " \t\u{a0}").len == 0,
            .soft_break, .hard_break => true,
            else => false,
        };
    }

    fn picture(b: *Builder, im: @FieldType(md.Inline, "image"), href: ?[]const u8) Allocator.Error!*gtk.Widget {
        const local = try paths.resolveRelative(b.alloc, b.file_dir, im.src);
        defer if (local) |l| b.alloc.free(l);
        const widget: *gtk.Widget = if (local) |path| w: {
            const pic = gtk.Picture.new();
            pic.setCanShrink(1);
            pic.setContentFit(.scale_down);
            pic.as(gtk.Widget).setHalign(.start);
            pic.as(gtk.Widget).setValign(.start);
            if (im.alt.len > 0) {
                const alt = try b.alloc.dupeSentinel(u8, im.alt, 0);
                defer b.alloc.free(alt);
                pic.setAlternativeText(alt.ptr);
            }
            const decoded = try paths.percentDecode(b.alloc, path);
            defer b.alloc.free(decoded);
            b.view.host.loadImage(b.view.host.ctx, decoded, pic);
            break :w pic.as(gtk.Widget);
        } else w: {
            // Remote images are not fetched (no web access from the
            // client); the alt text stands in.
            var aw: std.Io.Writer.Allocating = .init(b.alloc);
            defer aw.deinit();
            aw.writer.print("[{s}]", .{if (im.alt.len > 0) im.alt else "image"}) catch return error.OutOfMemory;
            const z = try b.alloc.dupeSentinel(u8, aw.written(), 0);
            defer b.alloc.free(z);
            const l = gtk.Label.new(z.ptr);
            l.setXalign(0);
            l.as(gtk.Widget).setHalign(.start);
            l.as(gtk.Widget).addCssClass("md-alt");
            break :w l.as(gtk.Widget);
        };
        if (im.title.len > 0) {
            const tt = try b.alloc.dupeSentinel(u8, im.title, 0);
            defer b.alloc.free(tt);
            widget.setTooltipText(tt.ptr);
        }
        if (href) |h| {
            try b.view.hrefs.append(b.alloc, try b.alloc.dupeSentinel(u8, h, 0));
            gobject.Object.setData(widget.as(gobject.Object), "md-href", @ptrFromInt(b.view.hrefs.items.len));
            const gc = gtk.GestureClick.new();
            _ = gtk.GestureClick.signals.released.connect(gc, *View, onPictureClicked, b.view, .{});
            widget.addController(gc.as(gtk.EventController));
            widget.setCursorFromName("pointer");
        }
        return widget;
    }

    fn markupLabel(b: *Builder, nodes: []const md.Inline) Allocator.Error!*gtk.Label {
        var aw: std.Io.Writer.Allocating = .init(b.alloc);
        defer aw.deinit();
        // Text is shown as it is: no hyphens where Pango wraps (N4).
        aw.writer.writeAll("<span insert_hyphens=\"false\">") catch return error.OutOfMemory;
        markup(&aw.writer, nodes, b.dark) catch return error.OutOfMemory;
        aw.writer.writeAll("</span>") catch return error.OutOfMemory;
        aw.writer.writeByte(0) catch return error.OutOfMemory;
        const text = aw.written();
        const l = gtk.Label.new(null);
        l.setMarkup(@ptrCast(text.ptr));
        textLabel(l);
        _ = gtk.Label.signals.activate_link.connect(l, *View, onActivateLink, b.view, .{});
        if (std.mem.indexOf(u8, text, "<a href=") != null) {
            // Links are underlined only under the pointer (F-39). GTK
            // bakes a link's underline into the label's text attributes
            // and does not redo them on hover, so the hovered link gets an
            // underline span in a copy of the markup.
            try b.view.markups.append(b.alloc, try b.alloc.dupeSentinel(u8, text[0 .. text.len - 1], 0));
            gobject.Object.setData(l.as(gobject.Object), "md-markup", @ptrFromInt(b.view.markups.items.len));
            const mc = gtk.EventControllerMotion.new();
            _ = gtk.EventControllerMotion.signals.motion.connect(mc, *View, onLinkMotion, b.view, .{});
            _ = gtk.EventControllerMotion.signals.enter.connect(mc, *View, onLinkMotion, b.view, .{});
            _ = gtk.EventControllerMotion.signals.leave.connect(mc, *View, onLinkLeave, b.view, .{});
            l.as(gtk.Widget).addController(mc.as(gtk.EventController));
        }
        return l;
    }
};

fn markupOf(view: *View, l: *gtk.Label) ?[:0]const u8 {
    const idx: usize = @intFromPtr(gobject.Object.getData(l.as(gobject.Object), "md-markup") orelse return null) - 1;
    return if (idx < view.markups.items.len) view.markups.items[idx] else null;
}

fn setHover(view: *View, l: ?*gtk.Label, uri: ?[]const u8) void {
    const same_label = view.hover_label == l;
    const same_uri = if (view.hover_uri) |h| (uri != null and std.mem.eql(u8, h, uri.?)) else uri == null;
    if (same_label and same_uri) return;
    // Put the previous label back as it was.
    if (view.hover_label) |old| {
        old.as(gtk.Widget).removeCssClass("md-hover");
        if (markupOf(view, old)) |m| old.setMarkup(m.ptr);
        old.as(gtk.Widget).setFocusable(0);
    }
    if (view.hover_uri) |u| view.alloc.free(u);
    view.hover_label = null;
    view.hover_uri = null;
    const label = l orelse return;
    const u = uri orelse return;
    const base = markupOf(view, label) orelse return;
    const marked = underlineLink(view.alloc, base, u, if (view.dark) "#7aa2f7" else "#2e7de9") catch return;
    defer view.alloc.free(marked);
    label.setMarkup(marked.ptr);
    // GTK makes a label focusable when it (re)creates its link state; a
    // focusable label inside the preview would take focus on a click.
    label.as(gtk.Widget).setFocusable(0);
    label.as(gtk.Widget).addCssClass("md-hover");
    view.hover_label = label;
    view.hover_uri = view.alloc.dupeSentinel(u8, u, 0) catch null;
}

fn onLinkMotion(mc: *gtk.EventControllerMotion, _: f64, _: f64, view: *View) callconv(.c) void {
    const w = mc.as(gtk.EventController).getWidget() orelse return;
    const l = gobject.ext.cast(gtk.Label, w) orelse return;
    // GtkLabel updates its link under the pointer in its own handler,
    // which may run after this one: look once the event is done.
    gobject.Object.setData(l.as(gobject.Object), "md-view", view);
    _ = glib.idleAdd(linkHoverIdle, l.as(gobject.Object).ref());
}

fn linkHoverIdle(data: ?*anyopaque) callconv(.c) c_int {
    const obj: *gobject.Object = @ptrCast(@alignCast(data.?));
    defer obj.unref();
    const l = gobject.ext.cast(gtk.Label, obj) orelse return 0;
    // Gone from its view (the preview was replaced): nothing to do.
    if (l.as(gtk.Widget).getRoot() == null) return 0;
    const view: *View = @ptrCast(@alignCast(gobject.Object.getData(obj, "md-view") orelse return 0));
    // A copy: the label's own string goes away when its markup is reset.
    var buf: [2048]u8 = undefined;
    const uri: ?[]const u8 = if (l.getCurrentUri()) |c| blk: {
        const sp = std.mem.span(c);
        if (sp.len > buf.len) break :blk null;
        @memcpy(buf[0..sp.len], sp);
        break :blk buf[0..sp.len];
    } else null;
    if (uri == null and view.hover_label != l) return 0;
    setHover(view, if (uri != null) l else null, uri);
    return 0;
}

fn onLinkLeave(_: *gtk.EventControllerMotion, view: *View) callconv(.c) void {
    setHover(view, null, null);
}

/// `markup` with only the links to `href` left as links; the others
/// become spans in the link colour (`accent`) for as long as the hover
/// lasts, so the label's `md-hover` class underlines just the hovered one.
pub fn underlineLink(a: Allocator, src: []const u8, href: []const u8, accent: []const u8) ![:0]u8 {
    var esc: std.Io.Writer.Allocating = .init(a);
    defer esc.deinit();
    try esc.writer.writeAll("<a href=\"");
    try escape(&esc.writer, href);
    try esc.writer.writeAll("\"");
    const keep = esc.written();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "<a href=\"")) |start| {
        const gt = std.mem.indexOfScalarPos(u8, src, start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, src, gt, "</a>") orelse break;
        if (std.mem.startsWith(u8, src[start..], keep) and src[start + keep.len] != '\"' and
            (src[start + keep.len] == '>' or src[start + keep.len] == ' '))
        {
            try out.writer.writeAll(src[i .. close + 4]);
        } else {
            try out.writer.writeAll(src[i..start]);
            try out.writer.print("<span foreground=\"{s}\">", .{accent});
            try out.writer.writeAll(src[gt + 1 .. close]);
            try out.writer.writeAll("</span>");
        }
        i = close + 4;
    }
    try out.writer.writeAll(src[i..]);
    return a.dupeSentinel(u8, out.written(), 0);
}

test "underlineLink keeps only the hovered link" {
    const a = std.testing.allocator;
    const r = try underlineLink(a, "x <a href=\"u1\">one</a> y <a href=\"u2\" title=\"t\">two</a>", "u2", "#123456");
    defer a.free(r);
    try std.testing.expectEqualStrings("x <span foreground=\"#123456\">one</span> y <a href=\"u2\" title=\"t\">two</a>", r);
}

/// Plain text in a wrapping label, without the hyphens Pango would add
/// at breaks inside words (N4). Markup, because a Pango attribute list
/// would need a direct libpango call.
pub fn setPlainText(l: *gtk.Label, text: [*:0]const u8) void {
    const esc = glib.markupEscapeText(text, -1);
    defer glib.free(esc);
    var aw: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer aw.deinit();
    aw.writer.print("<span insert_hyphens=\"false\">{s}</span>\x00", .{std.mem.span(esc)}) catch {
        l.setText(text);
        return;
    };
    l.setMarkup(@ptrCast(aw.written().ptr));
}

/// A markdown image that could not be loaded (missing file, unknown
/// format): its alt text stands in, marked as a broken image (D10).
pub fn imageFailed(pic: *gtk.Picture) void {
    const w = pic.as(gtk.Widget);
    const parent = w.getParent() orelse return;
    const alt: []const u8 = if (pic.getAlternativeText()) |a| std.mem.span(a) else "";
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "⚠ {s}", .{if (alt.len > 0) alt else "image"}, 0) catch "⚠ image";
    const l = gtk.Label.new(null);
    setPlainText(l, text.ptr);
    l.setXalign(0);
    l.setWrap(1);
    l.as(gtk.Widget).setHalign(.start);
    l.as(gtk.Widget).setValign(.start);
    l.as(gtk.Widget).addCssClass("md-alt");
    l.as(gtk.Widget).setTooltipText("image could not be loaded");
    if (gobject.ext.cast(gtk.FlowBoxChild, parent)) |fc| {
        fc.setChild(l.as(gtk.Widget));
    } else if (gobject.ext.cast(gtk.Box, parent)) |box| {
        box.insertChildAfter(l.as(gtk.Widget), w);
        w.setVisible(0);
    }
}

fn textLabel(l: *gtk.Label) void {
    l.setWrap(1);
    l.setWrapMode(.word_char);
    l.setXalign(0);
    l.as(gtk.Widget).setHalign(.fill);
    l.as(gtk.Widget).setFocusable(0);
}

/// Pango markup for inline content. `dark` picks the inline-code
/// background (index.html: `--raise-strong` over `--panel`).
pub fn markup(w: *std.Io.Writer, nodes: []const md.Inline, dark: bool) std.Io.Writer.Error!void {
    for (nodes) |n| switch (n) {
        .text => |t| try escape(w, t),
        .html => |t| try escape(w, t),
        .code => |t| {
            try w.print("<span font_family=\"JetBrainsMono Nerd Font, JetBrains Mono, DejaVu Sans Mono, monospace\" size=\"88%\" bgcolor=\"{s}\"> ", .{if (dark) "#353541" else "#e3e4e8"});
            try escape(w, t);
            try w.writeAll(" </span>");
        },
        .emph => |c| {
            try w.writeAll("<i>");
            try markup(w, c, dark);
            try w.writeAll("</i>");
        },
        .strong => |c| {
            try w.writeAll("<b>");
            try markup(w, c, dark);
            try w.writeAll("</b>");
        },
        .strike => |c| {
            try w.writeAll("<s>");
            try markup(w, c, dark);
            try w.writeAll("</s>");
        },
        .link => |l| {
            try w.writeAll("<a href=\"");
            try escape(w, if (l.href.len > 0) l.href else "#");
            try w.writeAll("\"");
            if (l.title.len > 0) {
                try w.writeAll(" title=\"");
                try escape(w, l.title);
                try w.writeAll("\"");
            }
            try w.writeAll(">");
            try markup(w, l.content, dark);
            try w.writeAll("</a>");
        },
        // Images inside running text (not split out): their alt text.
        .image => |im| {
            try w.writeAll("[");
            try escape(w, im.alt);
            try w.writeAll("]");
        },
        .soft_break => try w.writeAll(" "),
        .hard_break => try w.writeAll("\n"),
    };
}

fn escape(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        // Pango markup rejects control characters.
        0...8, 11, 12, 14...31 => {},
        else => try w.writeByte(c),
    };
}

comptime {
    _ = gdk;
    _ = glib;
}
