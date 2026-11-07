//! Control-socket commands for the file browser (one line in
//! control/commands.zig). They find the browser panes in the active
//! window (`pane`: index, default 0) and either dump their state or enter
//! at the same functions the GTK handlers call: `files-key` at the key
//! controller's `handleKey`, `files-click` at the row / preview / button
//! handlers, `files-drop` at the drop handler (after GTK has turned the
//! drop into local paths), `files-download` at the save dialog's result.
const std = @import("std");
const gdk = @import("gdk");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const control = @import("../control.zig");
const Request = control.Request;
const Application = @import("../application.zig").Application;
const key_event = @import("../key_event.zig");
const browser_mod = @import("browser.zig");
const Browser = browser_mod.Browser;
const Col = browser_mod.Col;
const md = @import("markdown.zig");
const title = @import("title.zig");

pub fn register() void {
    const cmds = [_]control.Command{
        .{ .name = "files-state", .help = "{pane=0, entries=true, limit=200}: file browser state: dir, cursor, columns (key, kind, widths, entries, highlight), preview (kind, narrow, md view, image size), drilled, watchers, rename, confirm, idle", .handler = &state },
        .{ .name = "files-key", .help = "{key, pane}: one key into the browser (its key controller's handler), e.g. Down, l, shift+D, F2, BackSpace", .handler = &key },
        .{ .name = "files-click", .help = "{column, row} | {target: preview|download|rename|delete|rendered|source}: a click, through the click handlers", .handler = &click },
        .{ .name = "files-rename", .help = "{text, commit=true}: type into the open rename field and press Enter (commit) or Escape", .handler = &rename },
        .{ .name = "files-confirm", .help = "{answer: delete|cancel|escape|backdrop}: answer the delete confirmation", .handler = &confirm },
        .{ .name = "files-drop", .help = "{paths:[…], column | target:browser|preview}: drop local files on a column (the drop handler)", .handler = &drop },
        .{ .name = "files-drag", .help = "{column | target, leave=false}: show (or clear) the drop-target highlight as a hovering file drag does", .handler = &drag },
        .{ .name = "files-paste", .help = "paste the clipboard into the browser (Ctrl+V)", .handler = &paste },
        .{ .name = "files-download", .help = "{path?, dest | cancel:true | dialog:true}: download the cursor file (or `path`): saved to `dest`, cancelled, or through the real save dialog", .handler = &download },
        .{ .name = "files-dialog-cancel", .help = "cancel the open save dialog", .handler = &dialogCancel },
        .{ .name = "files-open", .help = "{dir, cursor}: navigate (as a relative markdown link does)", .handler = &open },
        .{ .name = "files-link", .help = "{href, shift=false}: activate a markdown link in the preview", .handler = &link },
        .{ .name = "files-focus", .help = "{window=false}: focus the browser from outside (F-61), or simulate the window regaining focus", .handler = &focus },
        .{ .name = "files-scroll", .help = "{dx}: a wheel gesture on the strip (cancels the horizontal easing) scrolling by dx", .handler = &scroll },
        .{ .name = "files-wait", .help = "{timeout_ms=5000, pane}: answer once the browser is idle (no render, request or animation pending)", .handler = &wait },
        .{ .name = "files-locate", .help = "{what: row:<name> | act-rename | act-delete | download | rendered | source | link:<href> | preview-body | confirm-cancel | confirm-delete}: centre of that thing in window coordinates (for webmux-dev/realpointer)", .handler = &locate },
        .{ .name = "files-motion", .help = "{reduce:true|false}: set GTK's gtk-enable-animations off/on (reduced motion)", .handler = &motion },
        .{ .name = "files-fit-title", .help = "{text, width}: the title fitted to a label of that width (F-15)", .handler = &fitTitle },
    };
    for (cmds) |c| control.register(c);
}

fn find(req: *Request) ?*Browser {
    const app = Application.default();
    const win = app.activeWindow() orelse return null;
    var buf: [16]*Browser = undefined;
    var n: usize = 0;
    collect(win.as(gtk.Widget), &buf, &n);
    const idx: usize = @intCast(@max(0, req.int("pane") orelse 0));
    return if (idx < n) buf[idx] else null;
}

fn collect(w: *gtk.Widget, buf: []*Browser, n: *usize) void {
    if (n.* >= buf.len) return;
    if (gobject.ext.cast(Browser, w)) |b| {
        buf[n.*] = b;
        n.* += 1;
        return;
    }
    var child = w.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) collect(c, buf, n);
}

fn need(req: *Request) ?*Browser {
    return find(req) orelse {
        req.fail("no file browser pane", .{});
        return null;
    };
}

// --- files-state ----------------------------------------------------------------

const ColDump = struct {
    key: []const u8,
    kind: []const u8,
    width: f64,
    target_width: f64,
    x: ?f64,
    leaving: bool,
    error_code: ?[]const u8 = null,
    count: ?usize = null,
    truncated: ?bool = null,
    highlight: ?[]const u8 = null,
    highlight_kind: ?[]const u8 = null,
    scroll_y: ?f64 = null,
    drop_highlight: bool,
    entries: ?[]const EntryDump = null,
    preview: ?PreviewDump = null,
};

const EntryDump = struct { name: []const u8, dir: bool, symlink: bool, row_classes: []const []const u8 };

const PreviewDump = struct {
    path: ?[]const u8,
    loaded: bool,
    kind: ?[]const u8,
    narrow: bool,
    err: ?[]const u8,
    failed: bool,
    size: ?f64,
    meta: ?[]const u8,
    text_len: ?usize,
    truncated: ?bool,
    zip_rows: ?usize,
    markdown: ?[]const u8,
    md_blocks: ?[]const []const u8,
    md_images: u32,
    md_images_loaded: u32,
    md_images_failed: u32,
    /// A rendered-markdown link is underlined under the pointer.
    md_hover: bool,
    /// Allocated width of the preview's content (header + body): never
    /// more than the column, or the header's buttons are cut off (D1).
    content_width: ?c_int,
    image: ?struct { w: c_int, h: c_int },
    image_failed: bool,
    has_download: bool,
    scroll_y: ?f64,
    scroll_upper: ?f64,
    drilled_head: bool,
};

fn classes(a: std.mem.Allocator, w: *gtk.Widget) ![]const []const u8 {
    const raw: [*:null]?[*:0]u8 = @ptrCast(w.getCssClasses());
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (raw[i]) |c| : (i += 1) try out.append(a, try a.dupe(u8, std.mem.span(c)));
    @import("glib").strfreev(raw);
    return out.toOwnedSlice(a);
}

fn colDump(req: *Request, b: *Browser, c: *Col, with_entries: bool, limit: usize) !ColDump {
    const a = req.allocator();
    var x: ?f64 = null;
    var bounds: graphene.Rect = undefined;
    if (c.clip.as(gtk.Widget).computeBounds(b.scrollerWidget().as(gtk.Widget), &bounds) != 0) x = bounds.f_origin.f_x;
    var d: ColDump = .{
        .key = c.key,
        .kind = @tagName(c.kind),
        .width = c.clip.currentWidth(),
        .target_width = c.clip.targetWidth(),
        .x = x,
        .leaving = c.leaving,
        .drop_highlight = b.dropHighlight() == c.frame.as(gtk.Widget),
    };
    switch (c.kind) {
        .listing => if (c.listing) |l| {
            d.error_code = l.err;
            d.count = l.entries.len;
            d.truncated = l.truncated;
            if (c.hl) |i| {
                d.highlight = l.entries[i].name;
                d.highlight_kind = if (c.cursor_col) "cursor" else "on-path";
            }
            if (c.scroller) |sw| d.scroll_y = sw.getVadjustment().getValue();
            if (with_entries) {
                const n = @min(limit, l.entries.len);
                const es = try a.alloc(EntryDump, n);
                for (l.entries[0..n], es, 0..) |e, *o, i| o.* = .{
                    .name = e.name,
                    .dir = e.dir,
                    .symlink = e.symlink,
                    .row_classes = if (i < c.rows.items.len) try classes(a, c.rows.items[i].as(gtk.Widget)) else &.{},
                };
                d.entries = es;
            }
        },
        .preview => {
            const pv = &c.pv;
            var blocks: ?[]const []const u8 = null;
            if (pv.doc) |doc| {
                const bs = try a.alloc([]const u8, doc.blocks.len);
                for (doc.blocks, bs) |blk, *o| o.* = @tagName(blk);
                blocks = bs;
            }
            var meta: ?[]const u8 = null;
            if (pv.content) |content| meta = findMeta(a, content);
            d.preview = .{
                .path = pv.path,
                .loaded = pv.loaded,
                .kind = if (pv.info) |i| @tagName(i.kind) else null,
                .narrow = pv.narrow,
                .err = pv.err,
                .failed = pv.failed,
                .size = if (pv.info) |i| i.size else null,
                .meta = meta,
                .text_len = if (pv.info) |i| (if (i.kind == .text) i.content.len else null) else null,
                .truncated = if (pv.info) |i| i.truncated else null,
                .zip_rows = if (pv.info) |i| (if (i.kind == .zip) i.entries.len else null) else null,
                .markdown = if (pv.info) |i| (if (i.kind == .text and pv.toggle[0] != null) (if (pv.rendered_md) "rendered" else "source") else null) else null,
                .md_blocks = blocks,
                .md_images = pv.md_images,
                .md_images_loaded = pv.md_images_loaded,
                .md_images_failed = pv.md_images_failed,
                .md_hover = if (pv.content) |w| findWidget(w, @as([]const u8, "md-hover"), hasClass) != null else false,
                .content_width = if (pv.content) |w| w.getWidth() else null,
                .image = if (pv.image) |im| .{ .w = im.w, .h = im.h } else null,
                .image_failed = pv.image_failed,
                .has_download = pv.download != null,
                .scroll_y = if (pv.body) |sw| sw.getVadjustment().getValue() else null,
                .scroll_upper = if (pv.body) |sw| sw.getVadjustment().getUpper() else null,
                .drilled_head = b.drilled() != null,
            };
        },
    }
    return d;
}

/// The `.fmeta` label's text inside the preview content.
fn findMeta(a: std.mem.Allocator, w: *gtk.Widget) ?[]const u8 {
    if (w.hasCssClass("fmeta") != 0) {
        if (gobject.ext.cast(gtk.Label, w)) |l| return a.dupe(u8, std.mem.span(l.getText())) catch null;
    }
    var child = w.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) {
        if (findMeta(a, c)) |m| return m;
    }
    return null;
}

fn state(req: *Request) void {
    const b = need(req) orelse return;
    const a = req.allocator();
    const with_entries = req.boolean("entries") orelse true;
    const limit: usize = @intCast(@max(0, req.int("limit") orelse 200));
    var cols: std.ArrayList(ColDump) = .empty;
    for (b.columns()) |c| cols.append(a, colDump(req, b, c, with_entries, limit) catch return req.fail("dump failed", .{})) catch return req.fail("out of memory", .{});
    for (b.leavingColumns()) |c| cols.append(a, colDump(req, b, c, false, 0) catch return req.fail("dump failed", .{})) catch return req.fail("out of memory", .{});
    const hadj = b.scrollerWidget().getHadjustment();
    const rn = b.renameActive();
    var rename_text: ?[]const u8 = null;
    var rename_sel: ?[2]c_int = null;
    if (b.renameEntry()) |e| {
        rename_text = a.dupe(u8, std.mem.span(e.as(gtk.Editable).getText())) catch null;
        var s: c_int = 0;
        var en: c_int = 0;
        if (e.as(gtk.Editable).getSelectionBounds(&s, &en) != 0) rename_sel = .{ s, en };
    }
    const root = b.as(gtk.Widget).getRoot();
    const focus_w: ?*gtk.Widget = if (root) |r| r.getFocus() else null;
    req.ok(.{
        .dir = b.dir(),
        .cursor = b.cursor(),
        .home = b.home(),
        .title = if (b.getTitle()) |t| @as([]const u8, t) else null,
        .drilled = b.drilled(),
        .rightmost = b.rightmostDir(),
        .md_source = b.mdSource(),
        .renders = b.renderCount(),
        .idle = b.idle(),
        .focused = b.containsFocus(),
        .focus_widget = if (focus_w) |f| std.mem.span(f.getCssName()) else null,
        .browser_classes = classes(a, b.as(gtk.Widget)) catch &.{},
        .reduced_motion = Browser.reducedMotion(),
        .last_animation_ms = b.lastAnimationMs(),
        .last_dialog_folder = b.lastDialogFolder(),
        // Wrapping labels whose text Pango may hyphenate (N4): must be 0.
        .hyphenating_labels = countHyphenating(b.as(gtk.Widget)),
        .size = .{ .width = b.as(gtk.Widget).getWidth(), .height = b.as(gtk.Widget).getHeight() },
        .hscroll = .{ .value = hadj.getValue(), .upper = hadj.getUpper(), .page = hadj.getPageSize(), .target = b.followTarget(), .pinned = b.pinnedRight() },
        .watchers = b.watchedDirs(a) catch &.{},
        .rename = if (rn != null) .{ .text = rename_text, .selection = rename_sel } else null,
        .confirm = b.confirmText(),
        .downloads = b.pendingDownloads(),
        .last_status = b.lastStatus(),
        .saved_state = b.saveState(a) catch null,
        .columns = cols.items,
    });
}

// --- input ------------------------------------------------------------------------

fn key(req: *Request) void {
    const b = need(req) orelse return;
    const spec = req.string("key") orelse return req.fail("missing \"key\"", .{});
    const chord = key_event.parseChord(spec) catch |err| return req.fail("bad key \"{s}\": {t}", .{ spec, err });
    var kv = chord.keyval;
    if (chord.state.shift_mask) kv = gdk.keyvalToUpper(kv);
    req.ok(.{ .consumed = b.handleKey(kv, chord.state) });
}

fn click(req: *Request) void {
    const b = need(req) orelse return;
    if (req.string("target")) |t| {
        if (std.mem.eql(u8, t, "preview")) {
            b.clickPreview();
        } else if (std.mem.eql(u8, t, "rename")) {
            b.startRename(); // the ✎ button's handler
        } else if (std.mem.eql(u8, t, "delete")) {
            b.deleteCursor(); // the ✕ button's handler
        } else if (std.mem.eql(u8, t, "download")) {
            const pv = previewCol(b) orelse return req.fail("no preview", .{});
            const btn = pv.pv.download orelse return req.fail("no download button", .{});
            _ = btn.as(gtk.Widget).activate(); // emits clicked
        } else if (std.mem.eql(u8, t, "rendered") or std.mem.eql(u8, t, "source")) {
            const pv = previewCol(b) orelse return req.fail("no preview", .{});
            const tb = pv.pv.toggle[if (t[0] == 'r') 0 else 1] orelse return req.fail("no markdown toggle", .{});
            tb.setActive(1); // emits toggled, as a click does
        } else return req.fail("unknown target {s}", .{t});
        return req.ok(.{ .ok = true });
    }
    const ci: usize = @intCast(@max(0, req.int("column") orelse return req.fail("missing \"column\" or \"target\"", .{})));
    const ri: usize = @intCast(@max(0, req.int("row") orelse return req.fail("missing \"row\"", .{})));
    const cols = b.columns();
    if (ci >= cols.len) return req.fail("no column {d}", .{ci});
    b.clickRow(cols[ci], ri);
    req.ok(.{ .ok = true });
}

fn previewCol(b: *Browser) ?*Col {
    for (b.columns()) |c| if (c.kind == .preview) return c;
    return null;
}

fn rename(req: *Request) void {
    const b = need(req) orelse return;
    const e = b.renameEntry() orelse return req.fail("no rename field open", .{});
    if (req.string("text")) |t| {
        const z = req.allocator().dupeSentinel(u8, t, 0) catch return req.fail("out of memory", .{});
        e.as(gtk.Editable).setText(z.ptr);
    }
    if (req.boolean("commit") orelse true) {
        b.finishRename(true); // what the entry's activate (Enter) handler calls
    } else b.finishRename(false); // Escape
    req.ok(.{ .ok = true });
}

fn confirm(req: *Request) void {
    const b = need(req) orelse return;
    if (b.confirmText() == null) return req.fail("no confirmation open", .{});
    const ans = req.string("answer") orelse "cancel";
    if (std.mem.eql(u8, ans, "escape")) {
        _ = b.handleKey(gdk.KEY_Escape, .{});
    } else b.finishConfirm(std.mem.eql(u8, ans, "delete"));
    req.ok(.{ .ok = true });
}

fn dropTarget(req: *Request, b: *Browser) ?Browser.DropTarget {
    if (req.int("column")) |ci| {
        const cols = b.columns();
        if (ci < 0 or ci >= cols.len) return null;
        return .{ .col = cols[@intCast(ci)] };
    }
    const t = req.string("target") orelse "browser";
    if (std.mem.eql(u8, t, "preview")) return .{ .col = previewCol(b) orelse return null };
    return .browser;
}

fn drop(req: *Request) void {
    const b = need(req) orelse return;
    const v = req.get("paths") orelse return req.fail("missing \"paths\"", .{});
    if (v != .array) return req.fail("\"paths\" must be an array", .{});
    const a = req.allocator();
    const list = a.alloc([]const u8, v.array.items.len) catch return req.fail("out of memory", .{});
    for (v.array.items, list) |item, *o| {
        if (item != .string) return req.fail("paths must be strings", .{});
        o.* = item.string;
    }
    const target = dropTarget(req, b) orelse return req.fail("no such drop target", .{});
    const dir = a.dupe(u8, b.dropDir(target)) catch "";
    b.dropFiles(target, list);
    req.ok(.{ .dir = dir });
}

fn drag(req: *Request) void {
    const b = need(req) orelse return;
    if (req.boolean("leave") orelse false) {
        b.setDropHighlight(null);
        return req.ok(.{ .ok = true });
    }
    const target = dropTarget(req, b) orelse return req.fail("no such drop target", .{});
    const w: *gtk.Widget = switch (target) {
        .col => |c| c.frame.as(gtk.Widget),
        .browser => b.scrollerWidget().as(gtk.Widget),
    };
    b.setDropHighlight(w);
    req.ok(.{ .dir = b.dropDir(target) });
}

fn paste(req: *Request) void {
    const b = need(req) orelse return;
    b.paste();
    req.ok(.{ .ok = true });
}

fn download(req: *Request) void {
    const b = need(req) orelse return;
    const a = req.allocator();
    const path: []const u8 = if (req.string("path")) |p| p else blk: {
        const cur = b.cursor() orelse return req.fail("no cursor", .{});
        break :blk @import("paths.zig").join(a, b.dir(), cur) catch return req.fail("out of memory", .{});
    };
    if (req.boolean("dialog") orelse false) {
        b.download(path, .dialog);
    } else if (req.boolean("cancel") orelse false) {
        b.download(path, .{ .path = null });
    } else {
        const dest = req.string("dest") orelse return req.fail("missing \"dest\" (or cancel/dialog)", .{});
        b.download(path, .{ .path = dest });
    }
    req.ok(.{ .path = path });
}

fn dialogCancel(req: *Request) void {
    const b = need(req) orelse return;
    req.ok(.{ .cancelled = b.cancelDialog() });
}

fn open(req: *Request) void {
    const b = need(req) orelse return;
    const dir = req.string("dir") orelse return req.fail("missing \"dir\"", .{});
    const cur = req.string("cursor");
    const a = req.allocator();
    const href = if (cur) |c| (@import("paths.zig").join(a, dir, c) catch return req.fail("out of memory", .{})) else dir;
    // Absolute paths resolve like a markdown link from anywhere.
    const target = a.dupe(u8, href) catch return;
    b.navigate(target);
    req.ok(.{ .ok = true });
}

fn link(req: *Request) void {
    const b = need(req) orelse return;
    const href = req.string("href") orelse return req.fail("missing \"href\"", .{});
    b.activateLink(href, req.boolean("shift") orelse false);
    req.ok(.{ .status = b.lastStatus(), .dir = b.dir(), .cursor = b.cursor() });
}

fn focus(req: *Request) void {
    const b = need(req) orelse return;
    if (req.boolean("window") orelse false) {
        b.windowRegainedFocus();
    } else {
        // Move focus out first so the grab is a focus entering from outside.
        if (b.as(gtk.Widget).getRoot()) |r| r.setFocus(null);
        _ = b.as(gtk.Widget).grabFocus();
    }
    req.ok(.{ .focused = b.containsFocus() });
}

fn scroll(req: *Request) void {
    const b = need(req) orelse return;
    const dx: f64 = if (req.get("dx")) |v| switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    } else 0;
    b.wheel(dx);
    req.ok(.{ .value = b.scrollerWidget().getHadjustment().getValue() });
}

const Wait = struct {
    req: *Request,
    pane: i64,
    deadline: i64,
};

fn wait(req: *Request) void {
    _ = need(req) orelse return;
    const w = std.heap.c_allocator.create(Wait) catch return req.fail("out of memory", .{});
    w.* = .{
        .req = req,
        .pane = req.int("pane") orelse 0,
        .deadline = @import("glib").getMonotonicTime() + 1000 * (req.int("timeout_ms") orelse 5000),
    };
    _ = @import("glib").timeoutAdd(20, waitTick, w);
}

fn waitTick(data: ?*anyopaque) callconv(.c) c_int {
    const w: *Wait = @ptrCast(@alignCast(data.?));
    const b = find(w.req) orelse {
        w.req.fail("file browser pane went away", .{});
        std.heap.c_allocator.destroy(w);
        return 0;
    };
    // Idle on two consecutive checks (a render can start a request).
    if (b.idle()) {
        w.req.ok(.{ .idle = true, .dir = b.dir(), .cursor = b.cursor() });
        std.heap.c_allocator.destroy(w);
        return 0;
    }
    if (@import("glib").getMonotonicTime() > w.deadline) {
        w.req.fail("still busy after the timeout", .{});
        std.heap.c_allocator.destroy(w);
        return 0;
    }
    return 1;
}

fn fitTitle(req: *Request) void {
    const b = need(req) orelse return;
    const text = req.string("text") orelse (if (b.getTitle()) |t| @as([]const u8, t) else "");
    const width: f64 = @floatFromInt(req.int("width") orelse 200);
    const l = gtk.Label.new(null);
    _ = l.as(gobject.Object).refSink();
    defer l.unref();
    title.fit(l, text, width);
    req.ok(.{ .fitted = std.mem.span(l.getText()) });
}

comptime {
    _ = md;
}

// --- files-locate: where things are, for real pointer input ------------------

fn centreIn(req: *Request, w: *gtk.Widget) void {
    const root = w.getRoot() orelse return req.fail("not in a window", .{});
    var b: graphene.Rect = undefined;
    if (w.computeBounds(root.as(gtk.Widget), &b) == 0) return req.fail("not laid out", .{});
    req.ok(.{
        .x = @as(i64, @intFromFloat(b.f_origin.f_x + b.f_size.f_width / 2)),
        .y = @as(i64, @intFromFloat(b.f_origin.f_y + b.f_size.f_height / 2)),
        .w = b.f_size.f_width,
        .h = b.f_size.f_height,
        .visible = w.getMapped() != 0,
    });
}

/// The first descendant of `w` matching `pred`.
fn findWidget(w: *gtk.Widget, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *gtk.Widget) bool) ?*gtk.Widget {
    if (pred(ctx, w)) return w;
    var child = w.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) {
        if (findWidget(c, ctx, pred)) |f| return f;
    }
    return null;
}

fn countHyphenating(w: *gtk.Widget) usize {
    var n: usize = 0;
    if (gobject.ext.cast(gtk.Label, w)) |l| {
        if (l.getWrap() != 0 and w.getMapped() != 0) {
            const m = std.mem.span(l.getLabel());
            if (l.getUseMarkup() == 0 or !std.mem.startsWith(u8, m, "<span insert_hyphens=\"false\">")) n += 1;
        }
    }
    var child = w.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) n += countHyphenating(c);
    return n;
}

fn hasClass(cls: []const u8, w: *gtk.Widget) bool {
    var buf: [64]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{cls}, 0) catch return false;
    return w.hasCssClass(z.ptr) != 0;
}

fn isActButton(tip: []const u8, w: *gtk.Widget) bool {
    if (gobject.ext.cast(gtk.Button, w) == null) return false;
    const t = w.getTooltipText() orelse return false;
    return std.mem.eql(u8, std.mem.span(t), tip);
}

fn isButtonLabelled(label: []const u8, w: *gtk.Widget) bool {
    const b = gobject.ext.cast(gtk.Button, w) orelse return false;
    const l = b.getLabel() orelse return false;
    return std.mem.eql(u8, std.mem.span(l), label);
}

fn labelWithLink(href: []const u8, w: *gtk.Widget) bool {
    const l = gobject.ext.cast(gtk.Label, w) orelse return false;
    if (l.getUseMarkup() == 0) return false;
    const m = std.mem.span(l.getLabel());
    var buf: [600]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "href=\"{s}\"", .{href}) catch return false;
    return std.mem.indexOf(u8, m, needle) != null;
}

fn locate(req: *Request) void {
    const b = need(req) orelse return;
    const what = req.string("what") orelse return req.fail("missing \"what\"", .{});
    const bw = b.as(gtk.Widget);
    if (std.mem.startsWith(u8, what, "row:")) {
        const name = what[4..];
        // The cursor column first, then any column.
        var cols = b.columns();
        var i = cols.len;
        while (i > 0) {
            i -= 1;
            const c = cols[i];
            const l = c.listing orelse continue;
            if (l.find(name)) |r| if (r < c.rows.items.len) return centreIn(req, c.rows.items[r].as(gtk.Widget));
        }
        _ = &cols;
        return req.fail("no row {s}", .{name});
    }
    if (std.mem.eql(u8, what, "act-rename")) {
        const w = findWidget(bw, @as([]const u8, "Rename (r)"), isActButton) orelse return req.fail("no rename button", .{});
        return centreIn(req, w);
    }
    if (std.mem.eql(u8, what, "act-delete")) {
        const w = findWidget(bw, @as([]const u8, "Delete (d)"), isActButton) orelse return req.fail("no delete button", .{});
        return centreIn(req, w);
    }
    const pv = previewCol(b);
    if (std.mem.eql(u8, what, "download")) {
        const btn = (pv orelse return req.fail("no preview", .{})).pv.download orelse return req.fail("no download button", .{});
        return centreIn(req, btn.as(gtk.Widget));
    }
    if (std.mem.eql(u8, what, "rendered") or std.mem.eql(u8, what, "source")) {
        const tb = (pv orelse return req.fail("no preview", .{})).pv.toggle[if (what[0] == 'r') 0 else 1] orelse return req.fail("no toggle", .{});
        return centreIn(req, tb.as(gtk.Widget));
    }
    if (std.mem.eql(u8, what, "strip")) {
        // The strip's viewport (the area columns are visible in).
        const vp = b.scrollerWidget().getChild() orelse return req.fail("no viewport", .{});
        return centreIn(req, vp);
    }
    if (std.mem.eql(u8, what, "preview-body")) {
        const body = (pv orelse return req.fail("no preview", .{})).pv.body orelse return req.fail("no body", .{});
        return centreIn(req, body.as(gtk.Widget));
    }
    if (std.mem.startsWith(u8, what, "link:")) {
        const href = what[5..];
        const p = pv orelse return req.fail("no preview", .{});
        const content = p.pv.content orelse return req.fail("no content", .{});
        const w = findWidget(content, href, labelWithLink) orelse return req.fail("no label with link {s}", .{href});
        // The link's place in its label is not exposed by GTK: the label's
        // centre is returned with its bounds; the caller scans it.
        return centreIn(req, w);
    }
    const cd = b.confirmDialog() orelse return req.fail("unknown target {s} (or no confirmation open)", .{what});
    // The alert's buttons, by label (libadwaita exposes nothing else).
    const label: []const u8 = if (std.mem.eql(u8, what, "confirm-cancel"))
        "Cancel"
    else if (std.mem.eql(u8, what, "confirm-delete"))
        "Delete"
    else
        return req.fail("unknown target {s}", .{what});
    const w = findWidget(cd, label, isButtonLabelled) orelse return req.fail("no {s} button in the confirmation", .{label});
    centreIn(req, w);
}

fn motion(req: *Request) void {
    const settings = gtk.Settings.getDefault() orelse return req.fail("no settings", .{});
    var v = std.mem.zeroes(gobject.Value);
    _ = v.init(gobject.ext.types.boolean);
    defer v.unset();
    v.setBoolean(@intFromBool(!(req.boolean("reduce") orelse true)));
    settings.as(gobject.Object).setProperty("gtk-enable-animations", &v);
    req.ok(.{ .reduced = Browser.reducedMotion() });
}
