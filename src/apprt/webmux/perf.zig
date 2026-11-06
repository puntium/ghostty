//! Frame metrics: what every frame of the window cost and when it reached
//! the screen, so a rough animation can be told apart as main-thread bound
//! (a long `update`, `layout` or `paint`), GPU bound (short phases, late
//! presentation, high `gpu_pct`) or a timing fault (uneven frame clock
//! steps at a steady rate).
//!
//! How it measures:
//!
//!   - `attach` connects to the window's `GdkFrameClock`. Every cycle is
//!     one `Frame`: the clock's frame time (what animations sample), the
//!     wall time spent in each phase (`update`: tick callbacks; `layout`:
//!     size allocation, which is where a terminal resize lands; `paint`:
//!     snapshot plus GSK's submission, CPU side only), and later the
//!     compositor's presentation time for it (wp_presentation, through
//!     `GdkFrameTimings`). GPU work is asynchronous, so a frame the GPU
//!     could not finish in time shows as a late presentation, not as a
//!     long `paint`.
//!   - The workspace brackets each layout animation and each scroll chase
//!     with `spanBegin` / `spanEnd`. A span's `Stats` are computed from
//!     its frames a moment after it ends (presentation times arrive a few
//!     frames late).
//!   - `gpu_pct` is this process's share of the render engine over the
//!     span, from the DRM fdinfo counters of its own file descriptors
//!     (`drm-cycles-rcs` over `drm-total-cycles-rcs` on xe,
//!     `drm-engine-render` over wall time on i915). It covers GSK and the
//!     terminal renderers, not the compositor.
//!
//! How to read it: the control socket's `perf` command (WEBMUX.md ›
//! Performance), `webmux-dev/perf` for a repeatable run, or
//! `WEBMUX_GTK_PERF=1` in the environment for one line per span on
//! stderr. Everything here runs on the GTK main thread.
const std = @import("std");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

pub const env_var = "WEBMUX_GTK_PERF";

pub const Frame = struct {
    counter: i64 = 0,
    /// The frame clock's time for this frame, µs.
    frame_time: i64 = 0,
    /// Monotonic time the cycle began, µs.
    begin: i64 = 0,
    update_us: i32 = 0,
    layout_us: i32 = 0,
    paint_us: i32 = 0,
    total_us: i32 = 0,
    /// The cycle drew (a cycle can also be ticks only).
    painted: bool = false,
    /// When the compositor showed it: 0 not known yet, -1 never shown.
    presented: i64 = 0,
    refresh_us: i32 = 0,
    /// Pane textures built during the snapshot, and the time that took.
    textures: u16 = 0,
    texture_us: i32 = 0,
};

pub const Kind = enum { layout, scroll };

pub const Stats = struct {
    /// Frame clock cycles that began inside the span.
    frames: u32 = 0,
    duration_ms: f64 = 0,
    /// From the span's start to the end of its first cycle.
    first_frame_ms: f64 = 0,
    /// Steps of the frame clock's time: what the animation saw.
    step_avg_ms: f64 = 0,
    step_max_ms: f64 = 0,
    /// Frames the compositor reported as shown, the longest gap between
    /// two of them, and how many refreshes went by without a new frame.
    presented: u32 = 0,
    presented_max_ms: f64 = 0,
    missed: u32 = 0,
    refresh_ms: f64 = 0,
    /// Main-thread time per cycle, and the phases of the worst one.
    cpu_avg_ms: f64 = 0,
    cpu_max_ms: f64 = 0,
    worst_update_ms: f64 = 0,
    worst_layout_ms: f64 = 0,
    worst_paint_ms: f64 = 0,
    textures: u32 = 0,
    texture_ms: f64 = 0,
    /// This process's share of the GPU's render engine; null if the
    /// driver exposes no counters.
    gpu_pct: ?f64 = null,
};

pub const SpanReport = struct {
    id: u32,
    kind: []const u8,
    label: []const u8,
    open: bool,
    stats: Stats,
};

const Span = struct {
    id: u32 = 0,
    kind: Kind = .layout,
    label_buf: [32]u8 = undefined,
    label_len: u8 = 0,
    begin: i64 = 0,
    /// 0 while it runs.
    end: i64 = 0,
    gpu0: ?Gpu = null,
    gpu1: ?Gpu = null,
    stats: ?Stats = null,

    fn label(self: *const Span) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

const ring_len = 1024;
const span_len = 48;
/// A span's stats are computed this long after it ends.
const finalize_ms: c_uint = 250;

var frames: [ring_len]Frame = @splat(.{});
/// Total frames recorded; the newest is `frames[(count - 1) % ring_len]`.
var count: usize = 0;
var spans: [span_len]Span = @splat(.{});
var span_count: usize = 0;
var next_id: u32 = 1;

var clock: ?*gdk.FrameClock = null;
var handlers: [5]c_ulong = @splat(0);
var cur: Frame = .{};
var cur_last: i64 = 0;
var in_frame = false;
var finalize_source: c_uint = 0;
var log_spans: ?bool = null;

fn logging() bool {
    if (log_spans) |l| return l;
    const on = if (std.c.getenv(env_var)) |v| v[0] != 0 and v[0] != '0' else false;
    log_spans = on;
    return on;
}

/// Measure the frame clock `widget` is drawn by (its window's). Call when
/// the widget is realized; a second call for the same clock does nothing.
pub fn attach(widget: *gtk.Widget) void {
    const fc = widget.getFrameClock() orelse return;
    if (clock == fc) return;
    detach();
    fc.ref();
    clock = fc;
    handlers[0] = gdk.FrameClock.signals.before_paint.connect(fc, ?*anyopaque, onBeforePaint, null, .{});
    handlers[1] = gdk.FrameClock.signals.update.connect(fc, ?*anyopaque, onUpdate, null, .{ .after = true });
    handlers[2] = gdk.FrameClock.signals.layout.connect(fc, ?*anyopaque, onLayout, null, .{ .after = true });
    handlers[3] = gdk.FrameClock.signals.paint.connect(fc, ?*anyopaque, onPaint, null, .{ .after = true });
    handlers[4] = gdk.FrameClock.signals.after_paint.connect(fc, ?*anyopaque, onAfterPaint, null, .{ .after = true });
}

pub fn detach() void {
    const fc = clock orelse return;
    for (&handlers) |*h| {
        if (h.* != 0) gobject.signalHandlerDisconnect(fc.as(gobject.Object), h.*);
        h.* = 0;
    }
    fc.unref();
    clock = null;
    in_frame = false;
}

fn onBeforePaint(fc: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
    const now = glib.getMonotonicTime();
    cur = .{ .counter = fc.getFrameCounter(), .frame_time = fc.getFrameTime(), .begin = now };
    cur_last = now;
    in_frame = true;
}

fn lap() i32 {
    const now = glib.getMonotonicTime();
    const d = now - cur_last;
    cur_last = now;
    return @intCast(@min(d, std.math.maxInt(i32)));
}

fn onUpdate(_: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
    if (in_frame) cur.update_us = lap();
}

fn onLayout(_: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
    // The layout phase can run more than once in a cycle.
    if (in_frame) cur.layout_us +|= lap();
}

fn onPaint(_: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
    if (!in_frame) return;
    cur.paint_us = lap();
    cur.painted = true;
}

fn onAfterPaint(_: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) void {
    if (!in_frame) return;
    in_frame = false;
    const now = glib.getMonotonicTime();
    cur.total_us = @intCast(@min(now - cur.begin, std.math.maxInt(i32)));
    if (!cur.painted) cur.presented = -1;
    frames[count % ring_len] = cur;
    count += 1;
    resolvePresented();
}

/// A pane built a texture from a renderer frame during this cycle.
pub fn noteTexture(us: i64) void {
    if (!in_frame) return;
    cur.textures +|= 1;
    cur.texture_us +|= @intCast(@min(us, std.math.maxInt(i32)));
}

/// Fill in the presentation times the compositor has reported since.
fn resolvePresented() void {
    const fc = clock orelse return;
    const n = @min(count, 64);
    for (0..n) |back| {
        const f = &frames[(count - 1 - back) % ring_len];
        if (f.presented != 0) continue;
        const t = fc.getTimings(f.counter) orelse {
            f.presented = -1;
            continue;
        };
        if (t.getComplete() == 0) continue;
        const p = t.getPresentationTime();
        f.presented = if (p != 0) p else -1;
        f.refresh_us = @intCast(@min(t.getRefreshInterval(), std.math.maxInt(i32)));
    }
}

// ---------------------------------------------------------------------------
// Spans

/// A layout animation or a scroll chase starts. Returns its id.
pub fn spanBegin(kind: Kind, label: []const u8) u32 {
    const s = &spans[span_count % span_len];
    span_count += 1;
    s.* = .{ .id = next_id, .kind = kind, .begin = glib.getMonotonicTime(), .gpu0 = gpuSample() };
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    const n = @min(label.len, s.label_buf.len);
    @memcpy(s.label_buf[0..n], label[0..n]);
    s.label_len = @intCast(n);
    return s.id;
}

pub fn spanEnd(id: u32) void {
    if (id == 0) return;
    const s = findSpan(id) orelse return;
    if (s.end != 0) return;
    s.end = glib.getMonotonicTime();
    s.gpu1 = gpuSample();
    if (finalize_source == 0) finalize_source = glib.timeoutAdd(finalize_ms, finalizeTimeout, null);
}

fn findSpan(id: u32) ?*Span {
    const n = @min(span_count, span_len);
    for (0..n) |back| {
        const s = &spans[(span_count - 1 - back) % span_len];
        if (s.id == id) return s;
    }
    return null;
}

fn finalizeTimeout(_: ?*anyopaque) callconv(.c) c_int {
    finalize_source = 0;
    resolvePresented();
    const n = @min(span_count, span_len);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const s = &spans[(span_count - 1 - i) % span_len];
        if (s.end == 0 or s.stats != null) continue;
        s.stats = compute(s);
        if (logging()) logSpan(s);
    }
    return 0;
}

fn ms(us: anytype) f64 {
    return @as(f64, @floatFromInt(us)) / 1000;
}

fn compute(s: *const Span) Stats {
    var st: Stats = .{};
    const end = if (s.end != 0) s.end else glib.getMonotonicTime();
    st.duration_ms = ms(end - s.begin);
    const n = @min(count, ring_len);
    var prev_time: i64 = 0;
    var prev_presented: i64 = 0;
    var step_sum: i64 = 0;
    var steps: u32 = 0;
    var step_max: i64 = 0;
    var cpu_sum: i64 = 0;
    var cpu_max: i32 = -1;
    var presented_max: i64 = 0;
    var refresh: i64 = 0;
    var texture_us: i64 = 0;
    // Oldest first.
    for (0..n) |k| {
        const f = &frames[(count - n + k) % ring_len];
        if (f.begin < s.begin or f.begin > end) continue;
        if (st.frames == 0) st.first_frame_ms = ms(f.begin + f.total_us - s.begin);
        st.frames += 1;
        if (prev_time != 0) {
            const d = f.frame_time - prev_time;
            step_sum += d;
            steps += 1;
            step_max = @max(step_max, d);
        }
        prev_time = f.frame_time;
        cpu_sum += f.total_us;
        if (f.total_us > cpu_max) {
            cpu_max = f.total_us;
            st.worst_update_ms = ms(f.update_us);
            st.worst_layout_ms = ms(f.layout_us);
            st.worst_paint_ms = ms(f.paint_us);
        }
        st.textures += f.textures;
        texture_us += f.texture_us;
        if (f.presented > 0) {
            st.presented += 1;
            if (f.refresh_us > 0) refresh = f.refresh_us;
            if (prev_presented != 0) {
                const d = f.presented - prev_presented;
                presented_max = @max(presented_max, d);
                if (refresh > 0) {
                    const periods = @divFloor(d + @divFloor(refresh, 2), refresh);
                    if (periods > 1) st.missed += @intCast(periods - 1);
                }
            }
            prev_presented = f.presented;
        }
    }
    if (steps > 0) st.step_avg_ms = ms(step_sum) / @as(f64, @floatFromInt(steps));
    st.step_max_ms = ms(step_max);
    if (st.frames > 0) st.cpu_avg_ms = ms(cpu_sum) / @as(f64, @floatFromInt(st.frames));
    st.cpu_max_ms = if (cpu_max >= 0) ms(cpu_max) else 0;
    st.presented_max_ms = ms(presented_max);
    st.refresh_ms = ms(refresh);
    st.texture_ms = ms(texture_us);
    if (s.gpu0) |a| if (s.gpu1 orelse gpuSample()) |b| {
        st.gpu_pct = gpuShare(a, b);
    };
    return st;
}

fn logSpan(s: *const Span) void {
    const st = s.stats orelse return;
    var gpu_buf: [32]u8 = undefined;
    const gpu: []const u8 = if (st.gpu_pct) |g| std.fmt.bufPrint(&gpu_buf, ", gpu {d:.0}%", .{g}) catch "" else "";
    std.debug.print(
        "perf: {s} {s}: {d} frames in {d:.0} ms; shown {d}, longest gap {d:.1} ms, {d} missed (refresh {d:.1} ms); " ++
            "clock step avg {d:.1} max {d:.1} ms; cpu avg {d:.1} max {d:.1} ms (update {d:.1} layout {d:.1} paint {d:.1}); " ++
            "first frame +{d:.0} ms; {d} textures {d:.1} ms{s}\n",
        .{
            @tagName(s.kind),     s.label(),           st.frames,          st.duration_ms,
            st.presented,         st.presented_max_ms, st.missed,          st.refresh_ms,
            st.step_avg_ms,       st.step_max_ms,      st.cpu_avg_ms,      st.cpu_max_ms,
            st.worst_update_ms,   st.worst_layout_ms,  st.worst_paint_ms,  st.first_frame_ms,
            st.textures,          st.texture_ms,       gpu,
        },
    );
}

// ---------------------------------------------------------------------------
// Reports (control socket)

pub const Report = struct {
    attached: bool,
    frames_recorded: usize,
    /// Every cycle of the last `window_ms`.
    window_ms: f64,
    window: Stats,
    spans: []SpanReport,
    frames: []Frame,
    gpu: ?Gpu,
};

/// `window_us`: how far back the `window` stats reach. `raw`: how many of
/// the newest frames to return as they were recorded.
pub fn report(a: std.mem.Allocator, window_us: i64, raw: usize) !Report {
    resolvePresented();
    const now = glib.getMonotonicTime();
    const win: Span = .{ .begin = now - window_us, .end = now };
    const n = @min(span_count, span_len);
    const out = try a.alloc(SpanReport, n);
    for (0..n) |k| {
        const s = &spans[(span_count - n + k) % span_len];
        out[k] = .{
            .id = s.id,
            .kind = @tagName(s.kind),
            .label = try a.dupe(u8, s.label()),
            .open = s.end == 0,
            .stats = s.stats orelse compute(s),
        };
    }
    const r = @min(raw, @min(count, ring_len));
    const fr = try a.alloc(Frame, r);
    for (0..r) |k| fr[k] = frames[(count - r + k) % ring_len];
    return .{
        .attached = clock != null,
        .frames_recorded = count,
        .window_ms = ms(window_us),
        .window = compute(&win),
        .spans = out,
        .frames = fr,
        .gpu = gpuSample(),
    };
}

/// Forget every frame and span recorded so far.
pub fn reset() void {
    count = 0;
    span_count = 0;
}

// ---------------------------------------------------------------------------
// GPU share, from DRM fdinfo

pub const Gpu = struct {
    /// Render-engine time this process used: cycles (xe) or ns (i915).
    busy: u64,
    /// What `busy` is measured against: the engine's total cycles (xe),
    /// or monotonic ns (i915).
    total: u64,
};

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
const O_CLOEXEC: c_int = 0o2000000;

var drm_fds: [16]c_int = undefined;
var drm_fd_count: usize = 0;
var drm_scanned_us: i64 = 0;
/// DRM file descriptors come and go with panes; look again this often.
const drm_rescan_us: i64 = 2_000_000;

fn readFdinfo(fd: c_int, buf: []u8) ?[]const u8 {
    var path_buf: [48]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/self/fdinfo/{d}", .{fd}, 0) catch return null;
    const f = open(path.ptr, O_CLOEXEC);
    if (f < 0) return null;
    defer _ = close(f);
    var len: usize = 0;
    while (len < buf.len) {
        const r = read(f, buf.ptr + len, buf.len - len);
        if (r <= 0) break;
        len += @intCast(r);
    }
    return buf[0..len];
}

fn field(text: []const u8, key: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = std.mem.trim(u8, line[key.len..], " \t");
        if (std.mem.indexOfAny(u8, rest, " \t")) |sp| rest = rest[0..sp];
        return std.fmt.parseInt(u64, rest, 10) catch null;
    }
    return null;
}

fn scanDrmFds() void {
    drm_fd_count = 0;
    var buf: [4096]u8 = undefined;
    var fd: c_int = 0;
    while (fd < 1024 and drm_fd_count < drm_fds.len) : (fd += 1) {
        const text = readFdinfo(fd, &buf) orelse continue;
        if (std.mem.indexOf(u8, text, "drm-client-id:") == null) continue;
        drm_fds[drm_fd_count] = fd;
        drm_fd_count += 1;
    }
}

/// This process's render-engine counters now, or null without any.
pub fn gpuSample() ?Gpu {
    const now = glib.getMonotonicTime();
    if (drm_scanned_us == 0 or now - drm_scanned_us > drm_rescan_us) {
        scanDrmFds();
        drm_scanned_us = now;
    }
    var buf: [4096]u8 = undefined;
    var seen: [16]u64 = undefined;
    var seen_n: usize = 0;
    var busy: u64 = 0;
    var total: u64 = 0;
    var any = false;
    for (drm_fds[0..drm_fd_count]) |fd| {
        const text = readFdinfo(fd, &buf) orelse continue;
        const client = field(text, "drm-client-id:") orelse continue;
        // Several descriptors can be one client; count it once.
        if (std.mem.indexOfScalar(u64, seen[0..seen_n], client) != null) continue;
        if (seen_n < seen.len) {
            seen[seen_n] = client;
            seen_n += 1;
        }
        if (field(text, "drm-cycles-rcs:")) |c| {
            busy += c;
            if (field(text, "drm-total-cycles-rcs:")) |t| total = @max(total, t);
            any = true;
        } else if (field(text, "drm-engine-render:")) |ns| {
            busy += ns;
            total = @intCast(@max(0, now) * 1000);
            any = true;
        }
    }
    return if (any) .{ .busy = busy, .total = total } else null;
}

/// Percent of the render engine this process used between two samples.
pub fn gpuShare(a: Gpu, b: Gpu) ?f64 {
    if (b.total <= a.total or b.busy < a.busy) return null;
    return 100 * @as(f64, @floatFromInt(b.busy - a.busy)) / @as(f64, @floatFromInt(b.total - a.total));
}

test "fdinfo field" {
    const t = std.testing;
    const text = "pos:\t0\ndrm-driver:\txe\ndrm-client-id:\t84\ndrm-cycles-rcs:\t21962074524\ndrm-total-cycles-rcs:\t3189601029990\ndrm-engine-render:\t123 ns\n";
    try t.expectEqual(@as(?u64, 84), field(text, "drm-client-id:"));
    try t.expectEqual(@as(?u64, 21962074524), field(text, "drm-cycles-rcs:"));
    try t.expectEqual(@as(?u64, 123), field(text, "drm-engine-render:"));
    try t.expectEqual(@as(?u64, null), field(text, "drm-cycles-vcs:"));
}

test "gpu share" {
    const t = std.testing;
    try t.expectEqual(@as(?f64, 25), gpuShare(.{ .busy = 100, .total = 1000 }, .{ .busy = 350, .total = 2000 }));
    try t.expectEqual(@as(?f64, null), gpuShare(.{ .busy = 100, .total = 1000 }, .{ .busy = 350, .total = 1000 }));
}

test "span stats: steps, gaps and missed refreshes" {
    const t = std.testing;
    reset();
    defer reset();
    // Four frames 16.667 ms apart, then one two refreshes late.
    const times = [_]i64{ 1000, 17667, 34334, 51001, 84335 };
    for (times, 0..) |tm, i| {
        frames[count % ring_len] = .{
            .counter = @intCast(i),
            .frame_time = tm,
            .begin = tm,
            .update_us = 100,
            .layout_us = if (i == 0) 9000 else 200,
            .paint_us = 1000,
            .total_us = if (i == 0) 10100 else 1300,
            .painted = true,
            .presented = tm + 20000,
            .refresh_us = 16667,
        };
        count += 1;
    }
    const s: Span = .{ .begin = 500, .end = 90000 };
    const st = compute(&s);
    try t.expectEqual(@as(u32, 5), st.frames);
    try t.expectEqual(@as(u32, 5), st.presented);
    try t.expectEqual(@as(u32, 1), st.missed);
    try t.expectApproxEqAbs(@as(f64, 33.334), st.presented_max_ms, 0.001);
    try t.expectApproxEqAbs(@as(f64, 33.334), st.step_max_ms, 0.001);
    try t.expectApproxEqAbs(@as(f64, 10.1), st.cpu_max_ms, 0.001);
    try t.expectApproxEqAbs(@as(f64, 9.0), st.worst_layout_ms, 0.001);
    try t.expectApproxEqAbs(@as(f64, 10.6), st.first_frame_ms, 0.001);
}
