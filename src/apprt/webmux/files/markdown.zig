//! A markdown parser for the file browser's preview (pure, no GTK). It
//! covers what READMEs and notes use, following CommonMark and the GFM
//! extensions where it matters:
//!
//!   blocks   ATX and setext headings, paragraphs, fenced (``` ~~~) and
//!            indented code, block quotes (nested, lazy continuation),
//!            bullet / ordered / task lists with nesting and tight/loose,
//!            GFM tables with alignment, thematic breaks, link reference
//!            definitions, HTML blocks (kept as literal text)
//!   inlines  emphasis / strong (delimiter-run rules incl. `_` intraword),
//!            ~~strikethrough~~, `code spans`, links (inline, full /
//!            collapsed / shortcut references), images, <autolinks>, bare
//!            http(s):// and www. links, backslash escapes, entities,
//!            hard breaks (two spaces or a backslash), inline HTML (literal)
//!
//! Raw HTML is never interpreted: the viewer shows it as text, as the
//! Electron client does (files-widget.js renderMarkdown). Not covered:
//! footnotes, definition lists, math, emoji shortcodes, front matter,
//! heading ids, multi-line link reference definitions, list items that
//! start with a blank line followed by more than one blank line, and the
//! finer points of CommonMark's container precedence (e.g. a block quote
//! interrupted by a lazily continued list).
//!
//! `parse` returns a tree allocated in its own arena.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Align = enum { none, left, center, right };

pub const Block = union(enum) {
    heading: struct { level: u8, content: []Inline },
    paragraph: []Inline,
    code: struct { info: []const u8, text: []const u8 },
    quote: []Block,
    list: List,
    table: Table,
    hr,
    /// A raw HTML block, to be shown literally as a paragraph.
    html: []const u8,
};

pub const List = struct {
    ordered: bool,
    start: u32,
    tight: bool,
    items: []Item,
};

pub const Item = struct {
    /// null: not a task item; else whether its box is checked.
    task: ?bool,
    blocks: []Block,
};

pub const Cell = []Inline;

pub const Table = struct {
    aligns: []Align,
    head: []Cell,
    rows: [][]Cell,
};

pub const Inline = union(enum) {
    text: []const u8,
    code: []const u8,
    emph: []Inline,
    strong: []Inline,
    strike: []Inline,
    link: struct { href: []const u8, title: []const u8, content: []Inline },
    image: struct { src: []const u8, title: []const u8, alt: []const u8 },
    /// Raw inline HTML, shown literally.
    html: []const u8,
    soft_break,
    hard_break,
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []Block,

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }
};

pub fn parse(gpa: Allocator, src: []const u8) Allocator.Error!Doc {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var p: Parser = .{ .a = arena.allocator() };
    const lines = try splitLines(p.a, src);
    // Pass 1: block structure (link definitions are collected on the way),
    // pass 2: inline content of every leaf.
    const raw = try p.blocks(lines);
    const out = try p.resolve(raw);
    return .{ .arena = arena, .blocks = out };
}

// --- lines ---------------------------------------------------------------

/// Split into lines (\n, \r\n, \r), leading tabs expanded to the next
/// multiple of 4 columns, NUL replaced by U+FFFD.
fn splitLines(a: Allocator, src: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i <= src.len) {
        var end = i;
        while (end < src.len and src[end] != '\n' and src[end] != '\r') end += 1;
        const line = src[i..end];
        try out.append(a, try normalizeLine(a, line));
        if (end >= src.len) break;
        i = end + 1;
        if (src[end] == '\r' and i < src.len and src[i] == '\n') i += 1;
        if (i == src.len) break;
    }
    return out.toOwnedSlice(a);
}

fn normalizeLine(a: Allocator, line: []const u8) Allocator.Error![]const u8 {
    var needs = std.mem.indexOfScalar(u8, line, 0) != null;
    var k: usize = 0;
    while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {
        if (line[k] == '\t') needs = true;
    }
    if (!needs) return line;
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    for (line[0..k]) |c| {
        if (c == '\t') {
            const n = 4 - col % 4;
            try out.appendNTimes(a, ' ', n);
            col += n;
        } else {
            try out.append(a, ' ');
            col += 1;
        }
    }
    for (line[k..]) |c| {
        if (c == 0) try out.appendSlice(a, "\u{FFFD}") else try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Remove up to `n` leading spaces.
fn dedent(line: []const u8, n: usize) []const u8 {
    var k: usize = 0;
    while (k < n and k < line.len and line[k] == ' ') k += 1;
    return line[k..];
}

// --- block pass ------------------------------------------------------------

/// Blocks before inline parsing: leaf text is still raw.
const RawBlock = union(enum) {
    heading: struct { level: u8, text: []const u8 },
    paragraph: []const u8,
    code: struct { info: []const u8, text: []const u8 },
    quote: []RawBlock,
    list: struct { ordered: bool, start: u32, tight: bool, items: []RawItem },
    table: struct { aligns: []Align, head: [][]const u8, rows: [][][]const u8 },
    hr,
    html: []const u8,
};

const RawItem = struct { task: ?bool, blocks: []RawBlock };

const ListMarker = struct {
    ordered: bool,
    /// '-', '+', '*' or the ordered delimiter '.' / ')'.
    ch: u8,
    start: u32,
    /// Column where the item's content starts (relative to the line).
    content: usize,
    /// The rest of the first line is empty.
    empty: bool,
};

const Parser = struct {
    a: Allocator,
    defs: std.StringHashMapUnmanaged(Def) = .empty,

    const Def = struct { href: []const u8, title: []const u8 };

    fn blocks(p: *Parser, lines: []const []const u8) Allocator.Error![]RawBlock {
        var out: std.ArrayList(RawBlock) = .empty;
        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];
            if (isBlank(line)) {
                i += 1;
                continue;
            }
            const ind = indentOf(line);
            if (ind >= 4) {
                i = try p.indentedCode(lines, i, &out);
                continue;
            }
            const s = line[ind..];
            if (fenceOpen(s)) |f| {
                i = try p.fenced(lines, i, ind, f, &out);
                continue;
            }
            if (atxHeading(s)) |h| {
                try out.append(p.a, .{ .heading = .{ .level = h.level, .text = h.text } });
                i += 1;
                continue;
            }
            if (isThematicBreak(s)) {
                try out.append(p.a, .hr);
                i += 1;
                continue;
            }
            if (s[0] == '>') {
                i = try p.blockquote(lines, i, &out);
                continue;
            }
            if (listMarker(line)) |m| {
                i = try p.list(lines, i, m, &out);
                continue;
            }
            if (htmlBlockStart(s)) {
                var j = i;
                while (j < lines.len and !isBlank(lines[j])) j += 1;
                try out.append(p.a, .{ .html = try std.mem.join(p.a, "\n", lines[i..j]) });
                i = j;
                continue;
            }
            if (i + 1 < lines.len) {
                if (try p.table(lines, i, &out)) |next| {
                    i = next;
                    continue;
                }
            }
            i = try p.paragraph(lines, i, &out);
        }
        return out.toOwnedSlice(p.a);
    }

    fn indentedCode(p: *Parser, lines: []const []const u8, start: usize, out: *std.ArrayList(RawBlock)) Allocator.Error!usize {
        var j = start;
        var last = start;
        while (j < lines.len) : (j += 1) {
            if (isBlank(lines[j])) continue;
            if (indentOf(lines[j]) < 4) break;
            last = j;
        }
        var text: std.ArrayList(u8) = .empty;
        for (lines[start .. last + 1], 0..) |l, k| {
            if (k > 0) try text.append(p.a, '\n');
            try text.appendSlice(p.a, dedent(l, 4));
        }
        try out.append(p.a, .{ .code = .{ .info = "", .text = try text.toOwnedSlice(p.a) } });
        return last + 1;
    }

    const Fence = struct { ch: u8, len: usize, info: []const u8 };

    fn fenced(p: *Parser, lines: []const []const u8, start: usize, ind: usize, f: Fence, out: *std.ArrayList(RawBlock)) Allocator.Error!usize {
        var text: std.ArrayList(u8) = .empty;
        var j = start + 1;
        var first = true;
        while (j < lines.len) : (j += 1) {
            const l = lines[j];
            const li = indentOf(l);
            if (li < 4 and fenceClose(l[li..], f)) {
                j += 1;
                break;
            }
            if (!first) try text.append(p.a, '\n');
            first = false;
            try text.appendSlice(p.a, dedent(l, ind));
        }
        try out.append(p.a, .{ .code = .{ .info = f.info, .text = try text.toOwnedSlice(p.a) } });
        return j;
    }

    fn blockquote(p: *Parser, lines: []const []const u8, start: usize, out: *std.ArrayList(RawBlock)) Allocator.Error!usize {
        var inner: std.ArrayList([]const u8) = .empty;
        var j = start;
        var lazy_ok = false;
        while (j < lines.len) : (j += 1) {
            const l = lines[j];
            const ind = indentOf(l);
            if (ind < 4 and ind < l.len and l[ind] == '>') {
                var rest = l[ind + 1 ..];
                if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                try inner.append(p.a, rest);
                const ri = indentOf(rest);
                lazy_ok = !isBlank(rest) and ri < 4 and !startsBlock(rest[ri..], rest);
                continue;
            }
            // Lazy continuation of a paragraph inside the quote.
            if (lazy_ok and !isBlank(l) and !startsBlock(l[@min(ind, l.len)..], l) and ind < 4) {
                try inner.append(p.a, l);
                continue;
            }
            break;
        }
        try out.append(p.a, .{ .quote = try p.blocks(inner.items) });
        return j;
    }

    fn list(p: *Parser, lines: []const []const u8, start: usize, first: ListMarker, out: *std.ArrayList(RawBlock)) Allocator.Error!usize {
        var items: std.ArrayList(RawItem) = .empty;
        var tight = true;
        var j = start;
        var m = first;
        while (true) {
            // Gather this item's lines, de-indented to its content column.
            var item_lines: std.ArrayList([]const u8) = .empty;
            const first_line = lines[j];
            try item_lines.append(p.a, if (m.empty) "" else first_line[@min(m.content, first_line.len)..]);
            var k = j + 1;
            var lazy_ok = !m.empty;
            var blank_inside = false;
            var pending_blank: usize = 0;
            while (k < lines.len) : (k += 1) {
                const l = lines[k];
                if (isBlank(l)) {
                    // An item that starts empty ends at its first blank line
                    // if nothing followed the marker yet.
                    if (m.empty and item_lines.items.len == 1) break;
                    pending_blank += 1;
                    lazy_ok = false;
                    continue;
                }
                const ind = indentOf(l);
                if (ind >= m.content) {
                    if (pending_blank > 0 and item_lines.items.len > 0) blank_inside = true;
                    for (0..pending_blank) |_| try item_lines.append(p.a, "");
                    pending_blank = 0;
                    const rest = l[m.content..];
                    try item_lines.append(p.a, rest);
                    const ri = indentOf(rest);
                    lazy_ok = ri < 4 and !startsBlock(rest[ri..], rest);
                    continue;
                }
                if (pending_blank == 0 and lazy_ok and !startsBlock(l[ind..], l) and ind < 4 and listMarker(l) == null) {
                    try item_lines.append(p.a, l[ind..]);
                    continue;
                }
                break;
            }
            const item_blocks = try p.blocks(item_lines.items);
            if (blank_inside and countTopBlocks(item_lines.items) > 1) tight = false;
            var task: ?bool = null;
            if (item_blocks.len > 0 and item_blocks[0] == .paragraph) {
                if (taskPrefix(item_blocks[0].paragraph)) |tp| {
                    task = tp.checked;
                    item_blocks[0].paragraph = tp.rest;
                }
            }
            try items.append(p.a, .{ .task = task, .blocks = item_blocks });

            // A sibling item of the same kind?
            if (k >= lines.len) {
                j = k;
                break;
            }
            const next = listMarker(lines[k]) orelse {
                j = k;
                break;
            };
            if (next.ordered != m.ordered or next.ch != m.ch or indentOf(lines[k]) >= m.content) {
                j = k;
                break;
            }
            if (pending_blank > 0) tight = false;
            m = next;
            j = k;
        }
        try out.append(p.a, .{ .list = .{
            .ordered = first.ordered,
            .start = first.start,
            .tight = tight,
            .items = try items.toOwnedSlice(p.a),
        } });
        return j;
    }

    fn table(p: *Parser, lines: []const []const u8, start: usize, out: *std.ArrayList(RawBlock)) Allocator.Error!?usize {
        const head_line = lines[start];
        if (std.mem.indexOfScalar(u8, head_line, '|') == null) return null;
        const delim_line = lines[start + 1];
        if (indentOf(delim_line) >= 4) return null;
        const aligns = (try delimiterRow(p.a, delim_line)) orelse return null;
        const head = try splitRow(p.a, head_line);
        if (head.len != aligns.len) return null;
        var rows: std.ArrayList([][]const u8) = .empty;
        var j = start + 2;
        while (j < lines.len) : (j += 1) {
            const l = lines[j];
            if (isBlank(l)) break;
            const ind = indentOf(l);
            if (ind < 4 and startsBlock(l[ind..], l)) break;
            const cells = try splitRow(p.a, l);
            const fixed = try p.a.alloc([]const u8, head.len);
            for (fixed, 0..) |*c, ci| c.* = if (ci < cells.len) cells[ci] else "";
            try rows.append(p.a, fixed);
        }
        try out.append(p.a, .{ .table = .{ .aligns = aligns, .head = head, .rows = try rows.toOwnedSlice(p.a) } });
        return j;
    }

    fn paragraph(p: *Parser, lines: []const []const u8, start: usize, out: *std.ArrayList(RawBlock)) Allocator.Error!usize {
        var j = start;
        // Link reference definitions at the start of a paragraph.
        while (j < lines.len and !isBlank(lines[j])) {
            if (try p.linkDef(lines[j])) j += 1 else break;
        }
        if (j >= lines.len or isBlank(lines[j])) return j;
        const first = j;
        j += 1;
        while (j < lines.len) : (j += 1) {
            const l = lines[j];
            if (isBlank(l)) break;
            const ind = indentOf(l);
            if (ind < 4) {
                const s = l[ind..];
                if (setextLevel(s)) |level| {
                    try out.append(p.a, .{ .heading = .{ .level = level, .text = try p.joinPara(lines[first..j]) } });
                    return j + 1;
                }
                if (interruptsParagraph(s, l)) break;
            }
        }
        try out.append(p.a, .{ .paragraph = try p.joinPara(lines[first..j]) });
        return j;
    }

    fn joinPara(p: *Parser, lines: []const []const u8) Allocator.Error![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        for (lines, 0..) |l, k| {
            if (k > 0) try text.append(p.a, '\n');
            const trimmed = std.mem.trimStart(u8, l, " \t");
            try text.appendSlice(p.a, if (k == lines.len - 1) std.mem.trimEnd(u8, trimmed, " \t") else trimmed);
        }
        return text.toOwnedSlice(p.a);
    }

    /// `[label]: destination "optional title"` on one line.
    fn linkDef(p: *Parser, line: []const u8) Allocator.Error!bool {
        const ind = indentOf(line);
        if (ind >= 4) return false;
        const s = line[ind..];
        if (s.len < 4 or s[0] != '[') return false;
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return false;
        if (close < 2 or close + 1 >= s.len or s[close + 1] != ':') return false;
        const label = s[1..close];
        var rest = std.mem.trimStart(u8, s[close + 2 ..], " \t");
        if (rest.len == 0) return false;
        var href: []const u8 = undefined;
        if (rest[0] == '<') {
            const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return false;
            href = rest[1..gt];
            rest = rest[gt + 1 ..];
        } else {
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            href = rest[0..end];
            rest = rest[end..];
        }
        rest = std.mem.trim(u8, rest, " \t");
        var title: []const u8 = "";
        if (rest.len > 0) {
            const q = rest[0];
            const closing: u8 = switch (q) {
                '"' => '"',
                '\'' => '\'',
                '(' => ')',
                else => return false,
            };
            if (rest.len < 2 or rest[rest.len - 1] != closing) return false;
            title = rest[1 .. rest.len - 1];
        }
        const key = try normalizeLabel(p.a, label);
        if (key.len == 0) return false;
        const gop = try p.defs.getOrPut(p.a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .href = try unescape(p.a, href),
            .title = try unescape(p.a, title),
        };
        return true;
    }

    // --- pass 2 ------------------------------------------------------------

    fn resolve(p: *Parser, raw: []RawBlock) Allocator.Error![]Block {
        const out = try p.a.alloc(Block, raw.len);
        for (raw, out) |r, *o| o.* = switch (r) {
            .heading => |h| .{ .heading = .{ .level = h.level, .content = try p.inlines(h.text) } },
            .paragraph => |t| .{ .paragraph = try p.inlines(t) },
            .code => |c| .{ .code = .{ .info = c.info, .text = c.text } },
            .quote => |q| .{ .quote = try p.resolve(q) },
            .list => |l| blk: {
                const items = try p.a.alloc(Item, l.items.len);
                for (l.items, items) |ri, *it| it.* = .{ .task = ri.task, .blocks = try p.resolve(ri.blocks) };
                break :blk .{ .list = .{ .ordered = l.ordered, .start = l.start, .tight = l.tight, .items = items } };
            },
            .table => |tb| blk: {
                const head = try p.a.alloc(Cell, tb.head.len);
                for (tb.head, head) |c, *h| h.* = try p.inlines(c);
                const rows = try p.a.alloc([]Cell, tb.rows.len);
                for (tb.rows, rows) |rr, *row| {
                    row.* = try p.a.alloc(Cell, rr.len);
                    for (rr, row.*) |c, *cell| cell.* = try p.inlines(c);
                }
                break :blk .{ .table = .{ .aligns = tb.aligns, .head = head, .rows = rows } };
            },
            .hr => .hr,
            .html => |h| .{ .html = h },
        };
        return out;
    }

    fn inlines(p: *Parser, text: []const u8) Allocator.Error![]Inline {
        var ip: InlineParser = .{ .p = p, .src = text };
        return ip.run();
    }
};

fn countTopBlocks(lines: []const []const u8) usize {
    // Blank-separated chunks at the item's own indentation level.
    var n: usize = 0;
    var in_chunk = false;
    for (lines) |l| {
        if (isBlank(l)) {
            in_chunk = false;
        } else if (!in_chunk) {
            in_chunk = true;
            n += 1;
        }
    }
    return n;
}

/// Raw paragraph text "[ ] rest" / "[x] rest"; resolved later. Works on
/// the raw block before inline parsing, so `rest` is still text.
fn taskPrefix(text: []const u8) ?struct { checked: bool, rest: []const u8 } {
    if (text.len < 3 or text[0] != '[' or text[2] != ']') return null;
    const checked = switch (text[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    if (text.len == 3) return .{ .checked = checked, .rest = "" };
    if (text[3] != ' ' and text[3] != '\t') return null;
    return .{ .checked = checked, .rest = std.mem.trimStart(u8, text[4..], " \t") };
}

fn fenceOpen(s: []const u8) ?Parser.Fence {
    if (s.len < 3 or (s[0] != '`' and s[0] != '~')) return null;
    const ch = s[0];
    var n: usize = 0;
    while (n < s.len and s[n] == ch) n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, s[n..], " \t");
    if (ch == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .ch = ch, .len = n, .info = info };
}

fn fenceClose(s: []const u8, f: Parser.Fence) bool {
    var n: usize = 0;
    while (n < s.len and s[n] == f.ch) n += 1;
    return n >= f.len and isBlank(s[n..]);
}

fn atxHeading(s: []const u8) ?struct { level: u8, text: []const u8 } {
    var n: usize = 0;
    while (n < s.len and s[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < s.len and s[n] != ' ' and s[n] != '\t') return null;
    var text = std.mem.trim(u8, s[n..], " \t");
    // Optional closing sequence: spaces then #s.
    var e = text.len;
    while (e > 0 and text[e - 1] == '#') e -= 1;
    if (e == 0) {
        text = "";
    } else if (e < text.len and (text[e - 1] == ' ' or text[e - 1] == '\t')) {
        text = std.mem.trimEnd(u8, text[0..e], " \t");
    }
    return .{ .level = @intCast(n), .text = text };
}

fn isThematicBreak(s: []const u8) bool {
    if (s.len == 0) return false;
    const ch = s[0];
    if (ch != '*' and ch != '-' and ch != '_') return false;
    var n: usize = 0;
    for (s) |c| {
        if (c == ch) {
            n += 1;
        } else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

fn setextLevel(s: []const u8) ?u8 {
    const t = std.mem.trimEnd(u8, s, " \t");
    if (t.len == 0) return null;
    const ch = t[0];
    if (ch != '=' and ch != '-') return null;
    for (t) |c| if (c != ch) return null;
    return if (ch == '=') 1 else 2;
}

/// A list item marker at the start of `line` (after ≤ 3 spaces).
fn listMarker(line: []const u8) ?ListMarker {
    const ind = indentOf(line);
    if (ind >= 4 or ind >= line.len) return null;
    const s = line[ind..];
    var m: ListMarker = undefined;
    var w: usize = 0; // marker width
    if (s[0] == '-' or s[0] == '+' or s[0] == '*') {
        m = .{ .ordered = false, .ch = s[0], .start = 0, .content = 0, .empty = false };
        w = 1;
    } else {
        var d: usize = 0;
        while (d < s.len and d < 9 and std.ascii.isDigit(s[d])) d += 1;
        if (d == 0 or d >= s.len or (s[d] != '.' and s[d] != ')')) return null;
        const start = std.fmt.parseInt(u32, s[0..d], 10) catch return null;
        m = .{ .ordered = true, .ch = s[d], .start = start, .content = 0, .empty = false };
        w = d + 1;
    }
    const after = s[w..];
    if (after.len > 0 and after[0] != ' ' and after[0] != '\t') return null;
    if (isBlank(after)) {
        m.empty = true;
        m.content = ind + w + 1;
        return m;
    }
    const sp = indentOf(after);
    m.content = ind + w + (if (sp >= 5) 1 else sp);
    return m;
}

fn htmlBlockStart(s: []const u8) bool {
    if (s.len < 2 or s[0] != '<') return false;
    if (std.mem.startsWith(u8, s, "<!--") or s[1] == '?' or s[1] == '!') return true;
    var i: usize = 1;
    if (s[i] == '/') i += 1;
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return false;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    return i == s.len or s[i] == ' ' or s[i] == '>' or s[i] == '\t' or
        (s[i] == '/' and i + 1 < s.len and s[i + 1] == '>');
}

/// Whether `s` (a line minus its ≤3-space indent) starts a block that can
/// interrupt a paragraph, or that ends a lazy continuation.
fn startsBlock(s: []const u8, line: []const u8) bool {
    if (s.len == 0) return false;
    if (fenceOpen(s) != null or atxHeading(s) != null or isThematicBreak(s)) return true;
    if (s[0] == '>') return true;
    if (htmlBlockStart(s)) return true;
    if (listMarker(line)) |m| {
        if (m.empty) return false;
        if (m.ordered and m.start != 1) return false;
        return true;
    }
    return false;
}

fn interruptsParagraph(s: []const u8, line: []const u8) bool {
    return startsBlock(s, line);
}

fn splitRow(a: Allocator, line: []const u8) Allocator.Error![][]const u8 {
    var s = std.mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|' and !(s.len > 1 and s[s.len - 2] == '\\')) s = s[0 .. s.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '|') {
            try cur.append(a, '|');
            i += 1;
        } else if (s[i] == '|') {
            try cells.append(a, std.mem.trim(u8, try cur.toOwnedSlice(a), " \t"));
        } else try cur.append(a, s[i]);
    }
    try cells.append(a, std.mem.trim(u8, try cur.toOwnedSlice(a), " \t"));
    return cells.toOwnedSlice(a);
}

fn delimiterRow(a: Allocator, line: []const u8) Allocator.Error!?[]Align {
    if (std.mem.indexOfAny(u8, line, "-") == null) return null;
    const cells = try splitRow(a, line);
    const out = try a.alloc(Align, cells.len);
    for (cells, out) |c, *al| {
        if (c.len == 0) return null;
        const left = c[0] == ':';
        const right = c[c.len - 1] == ':';
        const mid = c[@intFromBool(left) .. c.len - @intFromBool(right and c.len > 1)];
        if (mid.len == 0) return null;
        for (mid) |ch| if (ch != '-') return null;
        al.* = if (left and right) .center else if (left) .left else if (right) .right else .none;
    }
    return out;
}

fn normalizeLabel(a: Allocator, label: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, label, " \t\n")) |c| {
        if (c == ' ' or c == '\t' or c == '\n') {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) try out.append(a, ' ');
        space = false;
        try out.append(a, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(a);
}

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// Backslash escapes and entities in a destination or title.
fn unescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\\&") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            try out.append(a, s[i + 1]);
            i += 2;
        } else if (s[i] == '&') {
            if (entity(s[i..])) |e| {
                try out.appendSlice(a, e.text);
                i += e.len;
            } else {
                try out.append(a, '&');
                i += 1;
            }
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

const Entity = struct { text: []const u8, len: usize };

const named_entities = [_]struct { []const u8, []const u8 }{
    .{ "amp", "&" },        .{ "lt", "<" },          .{ "gt", ">" },
    .{ "quot", "\"" },      .{ "apos", "'" },        .{ "nbsp", "\u{a0}" },
    .{ "copy", "©" },       .{ "reg", "®" },         .{ "trade", "™" },
    .{ "mdash", "—" },      .{ "ndash", "–" },       .{ "hellip", "…" },
    .{ "laquo", "«" },      .{ "raquo", "»" },       .{ "lsquo", "‘" },
    .{ "rsquo", "’" },      .{ "ldquo", "“" },       .{ "rdquo", "”" },
    .{ "middot", "·" },     .{ "bull", "•" },        .{ "times", "×" },
    .{ "divide", "÷" },     .{ "deg", "°" },         .{ "plusmn", "±" },
    .{ "larr", "←" },       .{ "rarr", "→" },        .{ "uarr", "↑" },
    .{ "darr", "↓" },       .{ "harr", "↔" },        .{ "check", "✓" },
    .{ "sect", "§" },       .{ "para", "¶" },        .{ "euro", "€" },
    .{ "pound", "£" },      .{ "yen", "¥" },         .{ "cent", "¢" },
    .{ "ensp", "\u{2002}" }, .{ "emsp", "\u{2003}" }, .{ "thinsp", "\u{2009}" },
    .{ "zwj", "\u{200d}" }, .{ "zwnj", "\u{200c}" }, .{ "shy", "\u{ad}" },
};

/// `&name;`, `&#123;` or `&#x1F600;` at the start of `s`.
fn entity(s: []const u8) ?Entity {
    const semi = std.mem.indexOfScalar(u8, s[0..@min(s.len, 34)], ';') orelse return null;
    const body = s[1..semi];
    if (body.len == 0) return null;
    if (body[0] == '#') {
        const cp: u21 = blk: {
            if (body.len > 1 and (body[1] == 'x' or body[1] == 'X')) {
                if (body.len < 3 or body.len > 8) return null;
                break :blk std.fmt.parseInt(u21, body[2..], 16) catch return null;
            }
            if (body.len < 2 or body.len > 8) return null;
            break :blk std.fmt.parseInt(u21, body[1..], 10) catch return null;
        };
        const c: u21 = if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) 0xFFFD else cp;
        const S = struct {
            threadlocal var buf: [4]u8 = undefined;
        };
        const n = std.unicode.utf8Encode(c, &S.buf) catch return null;
        return .{ .text = S.buf[0..n], .len = semi + 1 };
    }
    for (named_entities) |e| {
        if (std.mem.eql(u8, e[0], body)) return .{ .text = e[1], .len = semi + 1 };
    }
    return null;
}

// --- inline pass ---------------------------------------------------------

const Tmp = union(enum) {
    node: Inline,
    delim: Delim,
    bracket: Bracket,
};

const Delim = struct {
    ch: u8,
    count: usize,
    orig: usize,
    can_open: bool,
    can_close: bool,
};

const Bracket = struct {
    image: bool,
    active: bool,
    /// Byte offset in the source just after '[' (for reference labels).
    text_start: usize,
};

const InlineParser = struct {
    p: *Parser,
    src: []const u8,
    pos: usize = 0,
    items: std.ArrayList(Tmp) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn a(ip: *InlineParser) Allocator {
        return ip.p.a;
    }

    fn flush(ip: *InlineParser) Allocator.Error!void {
        if (ip.text.items.len == 0) return;
        try ip.items.append(ip.a(), .{ .node = .{ .text = try ip.text.toOwnedSlice(ip.a()) } });
    }

    fn push(ip: *InlineParser, t: Tmp) Allocator.Error!void {
        try ip.flush();
        try ip.items.append(ip.a(), t);
    }

    fn run(ip: *InlineParser) Allocator.Error![]Inline {
        const s = ip.src;
        while (ip.pos < s.len) {
            const c = s[ip.pos];
            switch (c) {
                '\\' => {
                    if (ip.pos + 1 < s.len and s[ip.pos + 1] == '\n') {
                        try ip.push(.{ .node = .hard_break });
                        ip.pos += 2;
                        ip.skipLeadingSpaces();
                    } else if (ip.pos + 1 < s.len and isAsciiPunct(s[ip.pos + 1])) {
                        try ip.text.append(ip.a(), s[ip.pos + 1]);
                        ip.pos += 2;
                    } else {
                        try ip.text.append(ip.a(), '\\');
                        ip.pos += 1;
                    }
                },
                '`' => try ip.codeSpan(),
                '*', '_', '~' => try ip.delimRun(),
                '[' => {
                    try ip.push(.{ .bracket = .{ .image = false, .active = true, .text_start = ip.pos + 1 } });
                    try ip.items.append(ip.a(), .{ .node = .{ .text = "[" } });
                    ip.pos += 1;
                },
                '!' => {
                    if (ip.pos + 1 < s.len and s[ip.pos + 1] == '[') {
                        try ip.push(.{ .bracket = .{ .image = true, .active = true, .text_start = ip.pos + 2 } });
                        try ip.items.append(ip.a(), .{ .node = .{ .text = "![" } });
                        ip.pos += 2;
                    } else {
                        try ip.text.append(ip.a(), '!');
                        ip.pos += 1;
                    }
                },
                ']' => try ip.closeBracket(),
                '<' => try ip.angle(),
                '&' => {
                    if (entity(s[ip.pos..])) |e| {
                        try ip.text.appendSlice(ip.a(), e.text);
                        ip.pos += e.len;
                    } else {
                        try ip.text.append(ip.a(), '&');
                        ip.pos += 1;
                    }
                },
                '\n' => {
                    // Two or more trailing spaces make a hard break.
                    var n: usize = 0;
                    while (n < ip.text.items.len and ip.text.items[ip.text.items.len - 1 - n] == ' ') n += 1;
                    ip.text.shrinkRetainingCapacity(ip.text.items.len - n);
                    try ip.push(.{ .node = if (n >= 2) .hard_break else .soft_break });
                    ip.pos += 1;
                    ip.skipLeadingSpaces();
                },
                else => {
                    if (try ip.bareLink()) continue;
                    try ip.text.append(ip.a(), c);
                    ip.pos += 1;
                },
            }
        }
        try ip.flush();
        try ip.processEmphasis(0);
        return ip.finish(ip.items.items);
    }

    fn skipLeadingSpaces(ip: *InlineParser) void {
        while (ip.pos < ip.src.len and ip.src[ip.pos] == ' ') ip.pos += 1;
    }

    fn codeSpan(ip: *InlineParser) Allocator.Error!void {
        const s = ip.src;
        const start = ip.pos;
        var n: usize = 0;
        while (start + n < s.len and s[start + n] == '`') n += 1;
        var i = start + n;
        while (i < s.len) {
            if (s[i] != '`') {
                i += 1;
                continue;
            }
            var m: usize = 0;
            while (i + m < s.len and s[i + m] == '`') m += 1;
            if (m == n) {
                var body = try ip.a().dupe(u8, s[start + n .. i]);
                for (body) |*ch| {
                    if (ch.* == '\n') ch.* = ' ';
                }
                if (body.len >= 2 and body[0] == ' ' and body[body.len - 1] == ' ' and !isBlank(body)) {
                    body = body[1 .. body.len - 1];
                }
                try ip.push(.{ .node = .{ .code = body } });
                ip.pos = i + m;
                return;
            }
            i += m;
        }
        try ip.text.appendSlice(ip.a(), s[start .. start + n]);
        ip.pos = start + n;
    }

    fn delimRun(ip: *InlineParser) Allocator.Error!void {
        const s = ip.src;
        const ch = s[ip.pos];
        const start = ip.pos;
        var n: usize = 0;
        while (start + n < s.len and s[start + n] == ch) n += 1;
        ip.pos = start + n;
        if (ch == '~' and n > 2) {
            try ip.text.appendSlice(ip.a(), s[start..ip.pos]);
            return;
        }
        const before: u8 = if (start == 0) '\n' else s[start - 1];
        const after: u8 = if (ip.pos >= s.len) '\n' else s[ip.pos];
        const ws_before = isWs(before);
        const ws_after = isWs(after);
        const p_before = isAsciiPunct(before);
        const p_after = isAsciiPunct(after);
        const left = !ws_after and (!p_after or ws_before or p_before);
        const right = !ws_before and (!p_before or ws_after or p_after);
        var can_open = left;
        var can_close = right;
        if (ch == '_') {
            can_open = left and (!right or p_before);
            can_close = right and (!left or p_after);
        }
        try ip.push(.{ .delim = .{ .ch = ch, .count = n, .orig = n, .can_open = can_open, .can_close = can_close } });
    }

    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
    }

    /// CommonMark "process emphasis" over items[bottom..].
    fn processEmphasis(ip: *InlineParser, bottom: usize) Allocator.Error!void {
        var c = bottom;
        while (c < ip.items.items.len) {
            const closer = switch (ip.items.items[c]) {
                .delim => |d| d,
                else => {
                    c += 1;
                    continue;
                },
            };
            if (!closer.can_close) {
                c += 1;
                continue;
            }
            // Find the nearest matching opener.
            var o = c;
            var found = false;
            while (o > bottom) {
                o -= 1;
                const op = switch (ip.items.items[o]) {
                    .delim => |d| d,
                    else => continue,
                };
                if (op.ch != closer.ch or !op.can_open) continue;
                if (closer.ch == '~') {
                    if (op.count != closer.count) continue;
                } else if ((op.can_close or closer.can_open) and (op.orig + closer.orig) % 3 == 0 and
                    !(op.orig % 3 == 0 and closer.orig % 3 == 0)) continue;
                found = true;
                break;
            }
            if (!found) {
                c += 1;
                continue;
            }
            const op = &ip.items.items[o].delim;
            const use: usize = if (closer.ch == '~') closer.count else if (op.count >= 2 and closer.count >= 2) 2 else 1;
            const children = try ip.finish(ip.items.items[o + 1 .. c]);
            const node: Inline = if (closer.ch == '~')
                .{ .strike = children }
            else if (use == 2)
                .{ .strong = children }
            else
                .{ .emph = children };
            op.count -= use;
            ip.items.items[c].delim.count -= use;
            try ip.items.replaceRange(ip.a(), o + 1, c - (o + 1), &.{.{ .node = node }});
            c = o + 2;
            if (ip.items.items[o].delim.count == 0) {
                _ = ip.items.orderedRemove(o);
                c -= 1;
            }
            if (ip.items.items[c].delim.count == 0) {
                _ = ip.items.orderedRemove(c);
            }
        }
    }

    /// Turn temporaries into nodes: unmatched delimiters and brackets
    /// become text; adjacent text merges.
    fn finish(ip: *InlineParser, items: []const Tmp) Allocator.Error![]Inline {
        var out: std.ArrayList(Inline) = .empty;
        for (items) |it| {
            const node: Inline = switch (it) {
                .node => |n| n,
                .delim => |d| .{ .text = try repeat(ip.a(), d.ch, d.count) },
                .bracket => continue, // its literal "[" / "![" follows as text
            };
            if (node == .text and out.items.len > 0 and out.items[out.items.len - 1] == .text) {
                const prev = out.items[out.items.len - 1].text;
                out.items[out.items.len - 1].text = try std.mem.concat(ip.a(), u8, &.{ prev, node.text });
                continue;
            }
            if (node == .text and node.text.len == 0) continue;
            try out.append(ip.a(), node);
        }
        return out.toOwnedSlice(ip.a());
    }

    fn closeBracket(ip: *InlineParser) Allocator.Error!void {
        try ip.flush();
        // Find the nearest bracket opener.
        var o = ip.items.items.len;
        while (o > 0) {
            o -= 1;
            if (ip.items.items[o] == .bracket) break;
        } else {
            try ip.text.append(ip.a(), ']');
            ip.pos += 1;
            return;
        }
        if (ip.items.items[o] != .bracket) {
            try ip.text.append(ip.a(), ']');
            ip.pos += 1;
            return;
        }
        const br = ip.items.items[o].bracket;
        if (!br.active) {
            _ = ip.items.orderedRemove(o); // literal "[" stays
            try ip.text.append(ip.a(), ']');
            ip.pos += 1;
            return;
        }
        const label_raw = ip.src[br.text_start..ip.pos];
        const after = ip.pos + 1;
        var dest: ?struct { href: []const u8, title: []const u8, end: usize } = null;
        if (try ip.inlineDest(after)) |d| {
            dest = .{ .href = d.href, .title = d.title, .end = d.end };
        } else {
            // Reference forms: [text][label], [text][], [text].
            var label = label_raw;
            var end = after;
            if (after < ip.src.len and ip.src[after] == '[') {
                if (std.mem.indexOfScalarPos(u8, ip.src, after + 1, ']')) |close| {
                    if (close > after + 1) label = ip.src[after + 1 .. close];
                    end = close + 1;
                }
            }
            const key = try normalizeLabel(ip.a(), label);
            if (ip.p.defs.get(key)) |def| dest = .{ .href = def.href, .title = def.title, .end = end };
        }
        const d = dest orelse {
            _ = ip.items.orderedRemove(o);
            try ip.text.append(ip.a(), ']');
            ip.pos += 1;
            return;
        };
        // items[o] is the bracket, items[o+1] its literal text; content follows.
        try ip.processEmphasis(o + 2);
        const content = try ip.finish(ip.items.items[o + 2 ..]);
        const node: Inline = if (br.image)
            .{ .image = .{ .src = d.href, .title = d.title, .alt = try plainText(ip.a(), content) } }
        else
            .{ .link = .{ .href = d.href, .title = d.title, .content = try unlink(ip.a(), content) } };
        ip.items.shrinkRetainingCapacity(o);
        try ip.items.append(ip.a(), .{ .node = node });
        if (!br.image) {
            // No links inside links: deactivate earlier link openers.
            for (ip.items.items[0..o]) |*it| {
                if (it.* == .bracket and !it.bracket.image) it.bracket.active = false;
            }
        }
        ip.pos = d.end;
    }

    const Dest = struct { href: []const u8, title: []const u8, end: usize };

    /// `(dest "title")` starting at `start` (which must be '(').
    fn inlineDest(ip: *InlineParser, start: usize) Allocator.Error!?Dest {
        const s = ip.src;
        if (start >= s.len or s[start] != '(') return null;
        var i = start + 1;
        i = skipWs(s, i);
        var href: []const u8 = "";
        if (i < s.len and s[i] == '<') {
            const end = std.mem.indexOfAnyPos(u8, s, i + 1, ">\n") orelse return null;
            if (s[end] != '>') return null;
            href = s[i + 1 .. end];
            i = end + 1;
        } else {
            const b = i;
            var depth: usize = 0;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                if (c == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
                    i += 1;
                    continue;
                }
                if (c == ' ' or c == '\t' or c == '\n' or c < 0x20) break;
                if (c == '(') depth += 1;
                if (c == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            href = s[b..i];
        }
        const before_title = i;
        i = skipWs(s, i);
        var title: []const u8 = "";
        if (i < s.len and i > before_title and (s[i] == '"' or s[i] == '\'' or s[i] == '(')) {
            const close: u8 = if (s[i] == '(') ')' else s[i];
            var j = i + 1;
            while (j < s.len and s[j] != close) : (j += 1) {
                if (s[j] == '\\') j += 1;
            }
            if (j >= s.len) return null;
            title = s[i + 1 .. j];
            i = skipWs(s, j + 1);
        }
        if (i >= s.len or s[i] != ')') return null;
        return .{ .href = try unescape(ip.a(), href), .title = try unescape(ip.a(), title), .end = i + 1 };
    }

    fn skipWs(s: []const u8, from: usize) usize {
        var i = from;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) i += 1;
        return i;
    }

    /// `<scheme:…>`, `<a@b.c>`, or an inline HTML tag / comment.
    fn angle(ip: *InlineParser) Allocator.Error!void {
        const s = ip.src;
        const rest = s[ip.pos..];
        if (std.mem.indexOfAny(u8, rest[1..], "<> \n")) |k| {
            const end = k + 1;
            if (rest[end] == '>') {
                const inner = rest[1..end];
                if (isUriAutolink(inner)) {
                    try ip.push(.{ .node = .{ .link = .{ .href = inner, .title = "", .content = try one(ip.a(), .{ .text = inner }) } } });
                    ip.pos += end + 1;
                    return;
                }
                if (isEmailAutolink(inner)) {
                    try ip.push(.{ .node = .{ .link = .{
                        .href = try std.fmt.allocPrint(ip.a(), "mailto:{s}", .{inner}),
                        .title = "",
                        .content = try one(ip.a(), .{ .text = inner }),
                    } } });
                    ip.pos += end + 1;
                    return;
                }
            }
        }
        if (htmlTagLen(rest)) |n| {
            try ip.push(.{ .node = .{ .html = rest[0..n] } });
            ip.pos += n;
            return;
        }
        try ip.text.append(ip.a(), '<');
        ip.pos += 1;
    }

    /// GFM extended autolinks: http://, https://, www. at a word start.
    fn bareLink(ip: *InlineParser) Allocator.Error!bool {
        const s = ip.src;
        const i = ip.pos;
        if (i > 0) {
            const prev = s[i - 1];
            if (!(isWs(prev) or prev == '(' or prev == '*' or prev == '_' or prev == '~' or prev == '"')) return false;
        }
        const rest = s[i..];
        const www = std.ascii.startsWithIgnoreCase(rest, "www.");
        if (!(www or std.ascii.startsWithIgnoreCase(rest, "http://") or std.ascii.startsWithIgnoreCase(rest, "https://")))
            return false;
        var end: usize = 0;
        while (end < rest.len and !isWs(rest[end]) and rest[end] != '<') end += 1;
        // Trailing punctuation is not part of the link; nor is an
        // unbalanced closing parenthesis.
        while (end > 0) {
            const c = rest[end - 1];
            if (std.mem.indexOfScalar(u8, "?!.,:*_~'\";", c) != null) {
                end -= 1;
                continue;
            }
            if (c == ')') {
                const opens = std.mem.count(u8, rest[0..end], "(");
                const closes = std.mem.count(u8, rest[0..end], ")");
                if (closes > opens) {
                    end -= 1;
                    continue;
                }
            }
            break;
        }
        const scheme_len: usize = if (www) 4 else if (rest[4] == 's' or rest[4] == 'S') 8 else 7;
        if (end <= scheme_len) return false;
        const text = rest[0..end];
        const href = if (www) try std.fmt.allocPrint(ip.a(), "http://{s}", .{text}) else text;
        try ip.push(.{ .node = .{ .link = .{ .href = href, .title = "", .content = try one(ip.a(), .{ .text = text }) } } });
        ip.pos += end;
        return true;
    }
};

fn one(a: Allocator, node: Inline) Allocator.Error![]Inline {
    const out = try a.alloc(Inline, 1);
    out[0] = node;
    return out;
}

fn repeat(a: Allocator, ch: u8, n: usize) Allocator.Error![]const u8 {
    const out = try a.alloc(u8, n);
    @memset(out, ch);
    return out;
}

fn isUriAutolink(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon < 2 or colon > 32 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-')) return false;
    }
    for (s) |c| if (c <= ' ' or c == '<' or c == '>') return false;
    return true;
}

fn isEmailAutolink(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at + 1 >= s.len) return false;
    for (s[0..at]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", c) != null)) return false;
    }
    for (s[at + 1 ..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.')) return false;
    }
    return std.mem.indexOfScalar(u8, s[at + 1 ..], '.') != null;
}

/// Length of an inline HTML construct at the start of `s` (open tag,
/// closing tag, comment, processing instruction, declaration, CDATA).
fn htmlTagLen(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != '<') return null;
    if (std.mem.startsWith(u8, s, "<!--")) {
        const e = std.mem.indexOfPos(u8, s, 4, "-->") orelse return null;
        return e + 3;
    }
    if (s[1] == '?') {
        const e = std.mem.indexOfPos(u8, s, 2, "?>") orelse return null;
        return e + 2;
    }
    if (s[1] == '!') {
        const e = std.mem.indexOfScalarPos(u8, s, 2, '>') orelse return null;
        return e + 1;
    }
    var i: usize = 1;
    const closing = s[i] == '/';
    if (closing) i += 1;
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    if (closing) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) i += 1;
        return if (i < s.len and s[i] == '>') i + 1 else null;
    }
    // Attributes: anything up to '>' outside quotes.
    var quote: u8 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return i + 1;
        } else if (c == '<') return null;
    }
    return null;
}

/// The text of inlines with markup removed (image alt text).
pub fn plainText(a: Allocator, nodes: []const Inline) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendPlain(a, &out, nodes);
    return out.toOwnedSlice(a);
}

fn appendPlain(a: Allocator, out: *std.ArrayList(u8), nodes: []const Inline) Allocator.Error!void {
    for (nodes) |n| switch (n) {
        .text, .code, .html => |t| try out.appendSlice(a, t),
        .emph, .strong, .strike => |c| try appendPlain(a, out, c),
        .link => |l| try appendPlain(a, out, l.content),
        .image => |im| try out.appendSlice(a, im.alt),
        .soft_break, .hard_break => try out.append(a, ' '),
    };
}

/// Links nested in a link's text (bare URLs, autolinks) lose their link.
fn unlink(a: Allocator, nodes: []Inline) Allocator.Error![]Inline {
    for (nodes) |*n| switch (n.*) {
        .link => |l| n.* = .{ .text = try plainText(a, l.content) },
        .emph, .strong, .strike => |*c| c.* = try unlink(a, c.*),
        else => {},
    };
    return nodes;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// A compact rendering of the tree for tests.
fn dump(a: Allocator, blocks_: []const Block) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try dumpBlocks(&aw.writer, blocks_, 0);
    return aw.written();
}

fn dumpBlocks(w: *std.Io.Writer, bs: []const Block, depth: usize) !void {
    for (bs) |b| {
        try w.splatByteAll(' ', depth * 2);
        switch (b) {
            .heading => |h| {
                try w.print("h{d} ", .{h.level});
                try dumpInlines(w, h.content);
            },
            .paragraph => |p| {
                try w.writeAll("p ");
                try dumpInlines(w, p);
            },
            .code => |c| try w.print("code[{s}] {s}", .{ c.info, c.text }),
            .quote => |q| {
                try w.writeAll("quote\n");
                try dumpBlocks(w, q, depth + 1);
                continue;
            },
            .list => |l| {
                try w.print("{s}{d}{s}\n", .{ if (l.ordered) "ol" else "ul", l.start, if (l.tight) "" else " loose" });
                for (l.items) |it| {
                    try w.splatByteAll(' ', depth * 2 + 2);
                    if (it.task) |c| try w.print("li[{s}]\n", .{if (c) "x" else " "}) else try w.writeAll("li\n");
                    try dumpBlocks(w, it.blocks, depth + 2);
                }
                continue;
            },
            .table => |tb| {
                try w.writeAll("table");
                for (tb.aligns) |al| try w.print(" {t}", .{al});
                try w.writeAll("\n");
                try w.splatByteAll(' ', depth * 2 + 2);
                for (tb.head) |c| {
                    try w.writeAll("|");
                    try dumpInlines(w, c);
                }
                for (tb.rows) |r| {
                    try w.writeAll("\n");
                    try w.splatByteAll(' ', depth * 2 + 2);
                    for (r) |c| {
                        try w.writeAll("|");
                        try dumpInlines(w, c);
                    }
                }
            },
            .hr => try w.writeAll("hr"),
            .html => |h| try w.print("html {s}", .{h}),
        }
        try w.writeAll("\n");
    }
}

fn dumpInlines(w: *std.Io.Writer, ns: []const Inline) !void {
    for (ns) |n| switch (n) {
        .text => |t| try w.writeAll(t),
        .code => |t| try w.print("`{s}`", .{t}),
        .html => |t| try w.print("{{html {s}}}", .{t}),
        .emph => |c| {
            try w.writeAll("<em>");
            try dumpInlines(w, c);
            try w.writeAll("</em>");
        },
        .strong => |c| {
            try w.writeAll("<b>");
            try dumpInlines(w, c);
            try w.writeAll("</b>");
        },
        .strike => |c| {
            try w.writeAll("<s>");
            try dumpInlines(w, c);
            try w.writeAll("</s>");
        },
        .link => |l| {
            try w.print("<a {s}", .{l.href});
            if (l.title.len > 0) try w.print(" \"{s}\"", .{l.title});
            try w.writeAll(">");
            try dumpInlines(w, l.content);
            try w.writeAll("</a>");
        },
        .image => |im| try w.print("<img {s} alt={s}>", .{ im.src, im.alt }),
        .soft_break => try w.writeAll("␤"),
        .hard_break => try w.writeAll("<br>"),
    };
}

fn expectMd(src: []const u8, want: []const u8) !void {
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    const got = try dump(doc.arena.allocator(), doc.blocks);
    try testing.expectEqualStrings(want, got);
}

test "headings: ATX, closing hashes, setext" {
    try expectMd(
        \\# One
        \\## Two ##
        \\###### Six
        \\####### seven
        \\#nospace
        \\
        \\Setext
        \\======
        \\Second
        \\---
    ,
        \\h1 One
        \\h2 Two
        \\h6 Six
        \\p ####### seven␤#nospace
        \\h1 Setext
        \\h2 Second
        \\
    );
}

test "paragraphs, soft and hard breaks, escapes, entities" {
    try expectMd("a\nb  \nc\\\nd \\*x\\* &amp; &copy; &#65;&#x42; &bogus;", "p a␤b<br>c<br>d *x* & © AB &bogus;\n");
}

test "emphasis, strong, strike, intraword underscore" {
    try expectMd(
        "*a* **b** ***c*** _d_ __e__ snake_case_name 2*3*4 ~~gone~~ ~one~ **nested *em* here**",
        "p <em>a</em> <b>b</b> <em><b>c</b></em> <em>d</em> <b>e</b> snake_case_name 2<em>3</em>4 <s>gone</s> <s>one</s> <b>nested <em>em</em> here</b>\n",
    );
    try expectMd("**unclosed and *half", "p **unclosed and *half\n");
    try expectMd("* not a list item?*", "ul0\n  li\n    p not a list item?*\n");
}

test "code spans" {
    try expectMd("use `zig build` and `` a`b `` and ` x ` and `unclosed", "p use `zig build` and `a`b` and `x` and `unclosed\n");
    try expectMd("`*no* [link](x)`", "p `*no* [link](x)`\n");
}

test "fenced and indented code" {
    try expectMd(
        \\```zig
        \\const x = 1;
        \\
        \\  indented
        \\```
        \\~~~~
        \\~~~
        \\~~~~
        \\
        \\    four spaces
        \\    more
        \\
        \\    after blank
        \\text
    ,
        \\code[zig] const x = 1;
        \\
        \\  indented
        \\code[] ~~~
        \\code[] four spaces
        \\more
        \\
        \\after blank
        \\p text
        \\
    );
    // An unclosed fence runs to the end.
    try expectMd("```\nopen", "code[] open\n");
}

test "block quotes: nested, lazy continuation, containing other blocks" {
    try expectMd(
        \\> quoted
        \\lazy
        \\> > inner
        \\>
        \\> - item
        \\
        \\after
    ,
        \\quote
        \\  p quoted␤lazy
        \\  quote
        \\    p inner
        \\  ul0
        \\    li
        \\      p item
        \\p after
        \\
    );
}

test "lists: bullets, ordered start, nesting, tight and loose, tasks" {
    try expectMd(
        \\- one
        \\- two
        \\  - nested a
        \\  - nested b
        \\    continued
        \\- three
        \\
        \\3. three
        \\4. four
        \\
        \\* loose
        \\
        \\* items
        \\
        \\- [ ] todo
        \\- [x] done
        \\- [y] not a task
    ,
        \\ul0
        \\  li
        \\    p one
        \\  li
        \\    p two
        \\    ul0
        \\      li
        \\        p nested a
        \\      li
        \\        p nested b␤continued
        \\  li
        \\    p three
        \\ol3
        \\  li
        \\    p three
        \\  li
        \\    p four
        \\ul0 loose
        \\  li
        \\    p loose
        \\  li
        \\    p items
        \\ul0
        \\  li[ ]
        \\    p todo
        \\  li[x]
        \\    p done
        \\  li
        \\    p [y] not a task
        \\
    );
}

test "lists: paragraphs and code inside items; a list interrupting a paragraph" {
    try expectMd(
        \\1. first
        \\
        \\   second para
        \\
        \\       code in item
        \\2) other delimiter starts a new list
        \\text
        \\- interrupts
    ,
        \\ol1 loose
        \\  li
        \\    p first
        \\    p second para
        \\    code[] code in item
        \\ol2
        \\  li
        \\    p other delimiter starts a new list␤text
        \\ul0
        \\  li
        \\    p interrupts
        \\
    );
    // An ordered list not starting at 1 does not interrupt a paragraph.
    try expectMd("para\n2. no", "p para␤2. no\n");
}

test "links: inline, titles, references, autolinks, bare URLs, images" {
    try expectMd(
        \\[a](http://x.y "T") [b](<sp ace.md>) [c](rel/p.md#frag) [d][ref] [Ref][] [ref]
        \\![alt *text*](img/a.png) [![badge](b.svg)](https://ci) <https://auto.link> <me@mail.org>
        \\see https://example.com/path(x). and www.site.org, not midhttps://x
        \\[not a link] [x](unclosed
        \\
        \\[ref]: https://ref.example "Ref Title"
    ,
        \\p <a http://x.y "T">a</a> <a sp ace.md>b</a> <a rel/p.md#frag>c</a> <a https://ref.example "Ref Title">d</a> <a https://ref.example "Ref Title">Ref</a> <a https://ref.example "Ref Title">ref</a>␤<img img/a.png alt=alt text> <a https://ci><img b.svg alt=badge></a> <a https://auto.link>https://auto.link</a> <a mailto:me@mail.org>me@mail.org</a>␤see <a https://example.com/path(x)>https://example.com/path(x)</a>. and <a http://www.site.org>www.site.org</a>, not midhttps://x␤[not a link] [x](unclosed
        \\
    );
    try expectMd("[outer [inner](a)](b)", "p [outer <a a>inner</a>](b)\n");
    try expectMd("[a](b(c)d) [e](f\\)g)", "p <a b(c)d>a</a> <a f)g>e</a>\n");
}

test "raw HTML stays literal" {
    try expectMd(
        \\<div align="center">
        \\  <img src="x.png">
        \\</div>
        \\
        \\Inline <b>bold</b> and <a href="x_y_z">a</a> <!-- c --> 1 < 2
    ,
        \\html <div align="center">
        \\  <img src="x.png">
        \\</div>
        \\p Inline {html <b>}bold{html </b>} and {html <a href="x_y_z">}a{html </a>} {html <!-- c -->} 1 < 2
        \\
    );
}

test "tables: alignment, escaped pipes, short and long rows" {
    try expectMd(
        \\| Name | Value | Note |
        \\|:-----|------:|:----:|
        \\| a | `1` | x \| y |
        \\| b |
        \\c | d | e | extra
        \\
        \\not | a table
    ,
        \\table left right center
        \\  |Name|Value|Note
        \\  |a|`1`|x | y
        \\  |b||
        \\  |c|d|e
        \\p not | a table
        \\
    );
}

test "thematic breaks and their precedence over lists" {
    try expectMd("***\n- - -\n___\n--", "hr\nhr\nhr\np --\n");
}

test "CRLF, tabs, NUL" {
    try expectMd("# a\r\n\tcode\r\n- x\r\n", "h1 a\ncode[] code\nul0\n  li\n    p x\n");
    try expectMd("a\x00b", "p a\u{FFFD}b\n");
}

test "empty input and blank lines" {
    try expectMd("", "");
    try expectMd("\n\n  \n", "");
}

test "parse never fails on odd input" {
    const inputs = [_][]const u8{
        "[", "]", "![", "*", "_", "~~", "`", "<", "&", "&#;", "&#xZZ;", "[]()", "[a]: ", "- ", "1.", "> ",
        "|", "|-|", "```", "    ", "**_*_**", "[a](<b)", "<a href='", "*a **b* c**", "\\", "a\\",
    };
    for (inputs) |s| {
        var doc = try parse(testing.allocator, s);
        doc.deinit();
    }
}
