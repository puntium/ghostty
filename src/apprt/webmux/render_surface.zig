//! Copied from src/apprt/gtk/class/render_surface.zig (Ghostty f54340ad).
//! Changes: type name, import paths, presentation-path counters (`stats`),
//! and what the strip needs to draw a pane in as few passes as possible:
//!   - an opaque terminal's DMABUF is imported under the alpha-less twin
//!     of its format (`setBackground`), so GSK and the compositor know
//!     nothing shows through it (needed for an offloaded pane that sits
//!     below the window's surface, and it lets GSK skip what is under it);
//!   - the unfocused fade is a colour matrix on the texture (`setFade`):
//!     the same pixels as a quad over the pane, without a second pass;
//!   - where the texture does not cover the widget (before the first
//!     frame, or for a moment after the pane grew) the terminal's
//!     background is drawn, so nothing has to be painted under the pane;
//!   - a texture larger than the widget is clipped to it;
//!   - texture builds are timed for `perf.zig`.
const std = @import("std");

const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");

const Application = @import("application.zig").Application;
const Common = @import("class.zig").Common;
const scale_util = @import("scale.zig");
const CoreSurface = @import("../../Surface.zig");
const rendererpkg = @import("../../renderer.zig");
const ExportedFrame = rendererpkg.Renderer.ExportedFrame;
const Dmabuf = @import("../../renderer/Dmabuf.zig");
const Planes = Dmabuf.Planes;
const graphene = @import("graphene");
const perf = @import("perf.zig");

/// `WEBMUX_GTK_OFFLOAD=1`: each terminal's frames go to the compositor on
/// a subsurface of their own (GtkGraphicsOffload) instead of being copied
/// into the window by GSK. Off by default; see WEBMUX.md › Performance.
pub fn offloadWanted() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |c| return c;
    const on = if (std.c.getenv("WEBMUX_GTK_OFFLOAD")) |v| v[0] != 0 and v[0] != '0' else false;
    S.cached = on;
    return on;
}

/// The alpha-less DRM format with the same layout, if there is one.
fn opaqueFourcc(fourcc: u32) ?u32 {
    const f = struct {
        fn cc(comptime s: *const [4]u8) u32 {
            return @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (@as(u32, s[3]) << 24);
        }
    };
    return switch (fourcc) {
        f.cc("AR24") => f.cc("XR24"),
        f.cc("AB24") => f.cc("XB24"),
        f.cc("RA24") => f.cc("RX24"),
        f.cc("BA24") => f.cc("BX24"),
        else => null,
    };
}

const log = std.log.scoped(.webmux_render_surface);

/// A widget that displays the rendered output of the Ghostty renderer.
///
/// In the past, Ghostty relied on GTK's builtin `GLArea` to display the
/// rendered output within the GTK-based UI, but this had numerous
/// debilitating limitations.
///
/// Its most significant limitation is that GTK's render lifecycle lives
/// **exclusively on the main UI thread**, from initialization to drawing the
/// rendered framebuffers. This is not only inefficient but also error-prone,
/// as we offload our render work to a dedicated render thread which has
/// to be careful not to access the renderer at the same time as the main
/// thread. Initialization is also far more complex as we had to wait for
/// GTK's OpenGL context to initialize, then we can proceed with initializing
/// the renderer and then the core surface. (The GTK surface widget could not
/// assume it always has a valid core surface, which is obviously absurd!)
/// It was a messy, chicken-and-egg relationship that held us back a lot.
///
/// With our custom `RenderSurface`, the renderer instead renders frames,
/// exports them into DMABUFs, then pushes them into a queue that this widget
/// can consume at its own pace on the main thread, whenever GTK calls for it
/// to be snapshotted. This also allowed us to do triple-buffering and should
/// greatly reduce tearing. Initialization is done on the render thread and
/// always completes before the core surface is created. Furthermore, this
/// surface is actually OpenGL-agnostic, since it operates exclusively on
/// DMABUFs which can also be produced by other graphics APIs like Vulkan.
pub const RenderSurface = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxRenderSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const C = Common(Self, Private);

    pub const Private = struct {
        /// The core surface, used to pull presents from the renderer.
        /// Set by the apprt Surface when it realizes the render surface.
        core_surface: ?*CoreSurface = null,

        /// The GDK Texture currently being displayed.
        texture: ?*gdk.Texture = null,

        /// `notify::scale` handler id on `scale_surface`.
        scale_notify_id: c_ulong = 0,

        /// GdkSurface we connected; ref'd so a replacement cannot dangle the handler.
        scale_surface: ?*gdk.Surface = null,

        /// One-shot so we log the first real allocation, not every size-allocate.
        scale_logged_size: bool = false,

        /// webmux: how many frames arrived on each presentation path, so
        /// the control socket's `dump` can say which one is really used.
        frames_dmabuf: u64 = 0,
        frames_memory: u64 = 0,
        dmabuf_import_failures: u64 = 0,
        /// webmux: DMABUF frames imported under an alpha-less format.
        frames_opaque: u64 = 0,

        /// webmux: the terminal's background colour, drawn where the
        /// texture does not reach.
        background: gdk.RGBA = .{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = 1 },
        /// webmux: the terminal draws no transparent pixel, so its frames
        /// can be imported as opaque.
        opaque_frames: bool = false,
        /// webmux: the display refused the alpha-less format once; frames
        /// keep their own format from then on.
        opaque_refused: bool = false,
        /// webmux: the unfocused fade, as `out = fade_scale * in +
        /// fade_add` per colour channel. Scale 1 is no fade.
        fade_scale: f32 = 1,
        fade_add: [3]f32 = .{ 0, 0, 0 },

        pub var offset: c_int = 0;
    };

    const private = C.private;
    pub const as = C.as;

    pub const signals = struct {
        /// Device-pixel size changed (also emitted on scale changes).
        pub const resize = struct {
            pub const name = "resize";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ c_int, c_int },
                void,
            );
        };
    };

    //---------------------------------------------------------------
    // Virtual methods

    fn realize(self: *Self) callconv(.c) void {
        // Call the parent realize.
        gtk.Widget.virtual_methods.realize.call(
            Class.parent,
            self.as(gtk.Widget),
        );

        // Request a draw in case frames were produced before we
        // realized. The snapshot will pull from the renderer's queue.
        self.connectScaleNotify();
        self.as(gtk.Widget).queueDraw();
    }

    fn unrealize(self: *Self) callconv(.c) void {
        const priv = self.private();

        self.disconnectScaleNotify();

        if (priv.texture) |tex| {
            tex.as(gobject.Object).unref();
            priv.texture = null;
        }

        gtk.Widget.virtual_methods.unrealize.call(
            Class.parent,
            self.as(gtk.Widget),
        );
    }

    fn sizeAllocate(
        self: *Self,
        width: c_int,
        height: c_int,
        baseline: c_int,
    ) callconv(.c) void {
        self.connectScaleNotify();
        self.emitDeviceResize(width, height);

        gtk.Widget.virtual_methods.size_allocate.call(
            Class.parent,
            self.as(gtk.Widget),
            width,
            height,
            baseline,
        );

        const priv = self.private();
        if (!priv.scale_logged_size and width > 0 and height > 0) {
            self.logScale("allocated", width, height);
            priv.scale_logged_size = true;
        }
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const priv = self.private();

        // Take the latest present from the renderer's queue, if any, and
        // build a texture from it. `take` closes any present that was
        // still unconsumed in the queue, but not the texture we're
        // currently displaying.
        if (priv.core_surface) |core| {
            if (core.renderer.takeFrame()) |frame| {
                const t0 = glib.getMonotonicTime();
                self.rebuildTexture(frame) catch |err| switch (err) {
                    // GTK can't import our DMABUFs, e.g. due to an
                    // incompatible format modifier on multi-GPU setups.
                    // Report unhealthy presentation health so the
                    // renderer presents via CPU readback instead.
                    error.DmabufBuildFailed => {
                        priv.dmabuf_import_failures += 1;
                        log.warn(
                            "failed to import dmabuf, asking renderer for CPU presentation",
                            .{},
                        );
                        core.reportPresentationHealth(.unhealthy);
                    },

                    else => log.warn("error building texture from frame err={}", .{err}),
                };
                perf.noteTexture(glib.getMonotonicTime() - t0);
            }
        }

        const widget = self.as(gtk.Widget);
        const width: f32 = @floatFromInt(widget.getWidth());
        const height: f32 = @floatFromInt(widget.getHeight());
        if (width <= 0 or height <= 0) return;

        // webmux: nothing is painted under this widget, so whatever the
        // texture does not cover gets the terminal's background here.
        const bg = self.fadedBackground();
        const texture = priv.texture orelse {
            snap.appendColor(&bg, &.{
                .f_origin = .{ .f_x = 0, .f_y = 0 },
                .f_size = .{ .f_width = width, .f_height = height },
            });
            return;
        };

        // Map one texture texel to one device pixel. Widget CSS size would
        // stretch a fractionally scaled buffer. Snap the surface-relative
        // origin so parent chrome cannot place the texture between pixels.
        const layout = scale_util.widgetLayout(widget);
        const origin = layout.snapOrigin();
        const scale: f32 = @floatCast(layout.scale);
        const css_w: f32 = @as(f32, @floatFromInt(texture.getWidth())) / scale;
        const css_h: f32 = @as(f32, @floatFromInt(texture.getHeight())) / scale;
        const ox: f32 = @floatCast(origin.x);
        const oy: f32 = @floatCast(origin.y);

        // The strips right of and below a texture smaller than the widget
        // (the renderer has not caught up with a resize yet). Less than
        // a device pixel is rounding, not a strip.
        const slack = 1 / scale;
        const right = @min(width, ox + css_w);
        const bottom = @min(height, oy + css_h);
        if (width - right >= slack) snap.appendColor(&bg, &.{
            .f_origin = .{ .f_x = right, .f_y = 0 },
            .f_size = .{ .f_width = width - right, .f_height = height },
        });
        if (height - bottom >= slack) snap.appendColor(&bg, &.{
            .f_origin = .{ .f_x = 0, .f_y = bottom },
            .f_size = .{ .f_width = right, .f_height = height - bottom },
        });

        // webmux: a texture larger than the widget (the pane shrank and
        // the renderer has not caught up, or is told to wait until the
        // move ends) stops at the widget's edge: nothing around the pane
        // clips it any more.
        const over = ox + css_w - width >= slack or oy + css_h - height >= slack;
        if (over) snap.pushClip(&.{
            .f_origin = .{ .f_x = 0, .f_y = 0 },
            .f_size = .{ .f_width = width, .f_height = height },
        });
        defer if (over) snap.pop();

        // GTK, Metal, Vulkan, etc. all have their origin points in the
        // top left, but not OpenGL!
        const flip = !rendererpkg.Renderer.custom_shader_y_is_down;
        if (flip) snap.save();
        defer if (flip) snap.restore();
        if (flip) {
            snap.translate(&.{ .f_x = 0, .f_y = css_h });
            snap.scale(1, -1);
        }

        // webmux: the fade wraps the texture node itself (inside the
        // flip), which GSK draws in the texture's own pass; around the
        // flip it would be rendered to an offscreen first.
        const faded = priv.fade_scale < 1;
        if (faded) {
            // Filled in by hand: the binary links no graphene function
            // (only its types), and graphene's own are 16-byte aligned.
            const k = priv.fade_scale;
            const m: graphene.Matrix align(16) = .{ .f_value = .{
                .f_x = .{ .f_x = k, .f_y = 0, .f_z = 0, .f_w = 0 },
                .f_y = .{ .f_x = 0, .f_y = k, .f_z = 0, .f_w = 0 },
                .f_z = .{ .f_x = 0, .f_y = 0, .f_z = k, .f_w = 0 },
                .f_w = .{ .f_x = 0, .f_y = 0, .f_z = 0, .f_w = 1 },
            } };
            const add: graphene.Vec4 align(16) = .{ .f_value = .{
                .f_x = priv.fade_add[0],
                .f_y = priv.fade_add[1],
                .f_z = priv.fade_add[2],
                .f_w = 0,
            } };
            snap.pushColorMatrix(&m, &add);
        }
        defer if (faded) snap.pop();

        snap.appendTexture(texture, &.{
            .f_origin = .{ .f_x = ox, .f_y = oy },
            .f_size = .{ .f_width = css_w, .f_height = css_h },
        });
    }

    /// webmux: the terminal's background as the fade leaves it.
    fn fadedBackground(self: *Self) gdk.RGBA {
        const priv = self.private();
        const b = priv.background;
        return .{
            .f_red = priv.fade_scale * b.f_red + priv.fade_add[0],
            .f_green = priv.fade_scale * b.f_green + priv.fade_add[1],
            .f_blue = priv.fade_scale * b.f_blue + priv.fade_add[2],
            .f_alpha = 1,
        };
    }

    /// webmux: the terminal's background colour, and whether everything
    /// the renderer draws is opaque (background-opacity 1).
    pub fn setBackground(self: *Self, color: gdk.RGBA, opaque_frames: bool) void {
        const priv = self.private();
        priv.background = color;
        priv.background.f_alpha = 1;
        priv.opaque_frames = opaque_frames;
        self.as(gtk.Widget).queueDraw();
    }

    /// webmux: draw every pixel as `scale * pixel + add` (the unfocused
    /// fade; scale 1 and add 0 for none).
    pub fn setFade(self: *Self, scale: f32, add: [3]f32) void {
        const priv = self.private();
        if (priv.fade_scale == scale and std.mem.eql(f32, &priv.fade_add, &add)) return;
        priv.fade_scale = scale;
        priv.fade_add = add;
        self.as(gtk.Widget).queueDraw();
    }

    //---------------------------------------------------------------
    // Presenting

    /// Return the size of this surface in device pixels. Used by the
    /// apprt surface to report the size to the renderer.
    pub fn deviceSize(self: *Self) struct { width: u32, height: u32 } {
        const size = scale_util.widgetLayout(self.as(gtk.Widget)).size;
        return .{ .width = size.width, .height = size.height };
    }

    fn emitDeviceResize(self: *Self, css_w: c_int, css_h: c_int) void {
        const size = scale_util.widgetLayoutForSize(self.as(gtk.Widget), css_w, css_h).size;
        if (size.width == 0 or size.height == 0) return;
        signals.resize.impl.emit(
            self,
            null,
            .{ @intCast(size.width), @intCast(size.height) },
            null,
        );
    }

    fn connectScaleNotify(self: *Self) void {
        const native = self.as(gtk.Widget).getNative() orelse return;
        const surface = native.getSurface() orelse return;

        const priv = self.private();
        if (priv.scale_notify_id != 0) {
            if (priv.scale_surface == surface) return;
            self.disconnectScaleNotify();
        }

        _ = surface.as(gobject.Object).ref();
        priv.scale_surface = surface;
        priv.scale_logged_size = false;
        priv.scale_notify_id = gobject.Object.signals.notify.connect(
            surface,
            *Self,
            onScaleNotify,
            self,
            .{ .detail = "scale" },
        );
        const widget = self.as(gtk.Widget);
        self.logScale("connected", widget.getWidth(), widget.getHeight());
    }

    fn disconnectScaleNotify(self: *Self) void {
        const priv = self.private();
        if (priv.scale_notify_id == 0) return;
        if (priv.scale_surface) |surface| {
            gobject.signalHandlerDisconnect(
                surface.as(gobject.Object),
                priv.scale_notify_id,
            );
            surface.as(gobject.Object).unref();
        }
        priv.scale_notify_id = 0;
        priv.scale_surface = null;
    }

    fn onScaleNotify(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const widget = self.as(gtk.Widget);
        self.logScale("changed", widget.getWidth(), widget.getHeight());
        self.emitDeviceResize(widget.getWidth(), widget.getHeight());
        widget.queueDraw();
    }

    fn logScale(self: *Self, event: []const u8, css_width: c_int, css_height: c_int) void {
        const widget = self.as(gtk.Widget);
        const native = widget.getNative() orelse return;
        const surface = native.getSurface() orelse return;
        const layout = scale_util.widgetLayoutForSize(widget, css_width, css_height);

        log.debug(
            "surface scale {s}: css={}x{} device={}x{} surface={d} effective={d} surface_factor={} widget_factor={}",
            .{
                event,
                css_width,
                css_height,
                layout.size.width,
                layout.size.height,
                surface.getScale(),
                layout.scale,
                surface.getScaleFactor(),
                widget.getScaleFactor(),
            },
        );
    }

    pub const Stats = struct {
        frames_dmabuf: u64,
        frames_memory: u64,
        dmabuf_import_failures: u64,
        frames_opaque: u64,
        faded: bool,
    };

    /// webmux: presentation counters (see `Private.frames_dmabuf`).
    pub fn stats(self: *Self) Stats {
        const priv = self.private();
        return .{
            .frames_dmabuf = priv.frames_dmabuf,
            .frames_memory = priv.frames_memory,
            .dmabuf_import_failures = priv.dmabuf_import_failures,
            .frames_opaque = priv.frames_opaque,
            .faded = priv.fade_scale < 1,
        };
    }

    /// Set the core surface to pull presents from. Nothing will
    /// render when this is unset.
    pub fn setCoreSurface(self: *Self, core: ?*CoreSurface) void {
        self.private().core_surface = core;
    }

    /// Build a `GdkTexture` from the present and set it as our current
    /// texture, unrefing any previous texture.
    fn rebuildTexture(self: *Self, frame: ExportedFrame) !void {
        const priv = self.private();
        switch (frame) {
            .dmabuf => |dmabuf| {
                try self.rebuildDmabufTexture(dmabuf);
                priv.frames_dmabuf += 1;
            },
            .memory => |memory| {
                try self.rebuildMemoryTexture(memory);
                priv.frames_memory += 1;
            },
        }
    }

    /// Build a `GdkDmabufTexture` from the present and set it as our
    /// current texture, unrefing any previous texture.
    fn rebuildDmabufTexture(self: *Self, frame: Dmabuf) !void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const display = widget.getDisplay();

        const builder = gdk.DmabufTextureBuilder.new();
        defer builder.unref();

        // webmux: an opaque terminal's frame goes in under the alpha-less
        // twin of its format, unless the display has refused that before.
        const opaque_fourcc: ?u32 = if (priv.opaque_frames and !priv.opaque_refused) opaqueFourcc(frame.fourcc) else null;

        builder.setDisplay(display);
        builder.setWidth(frame.width);
        builder.setHeight(frame.height);
        builder.setFourcc(opaque_fourcc orelse frame.fourcc);
        builder.setModifier(frame.modifier);
        builder.setPremultiplied(@intFromBool(frame.premultiplied));
        builder.setNPlanes(@intCast(frame.planes.count));

        for (0..frame.planes.count) |i| {
            builder.setFd(@intCast(i), frame.planes.fds[i]);
            builder.setOffset(@intCast(i), @intCast(frame.planes.offsets[i]));
            builder.setStride(@intCast(i), @intCast(frame.planes.strides[i]));
        }

        // Build the texture. We retain ownership over the DMABUF FDs
        // until the asynchronous texture building process is complete,
        // so we have to make a heap copy of them, send them to GTK,
        // and then destroy them once successful.
        const app = Application.default();
        const alloc = app.allocator();

        const planes = try alloc.create(Planes);
        errdefer alloc.destroy(planes);

        planes.* = frame.planes;
        errdefer planes.deinit();

        var err_: ?*glib.Error = null;
        const texture = builder.build(
            dmabufDestroy,
            planes,
            &err_,
        ) orelse retry: {
            // webmux: the alpha-less format was not accepted; the frame's
            // own format is what worked before this was tried.
            if (opaque_fourcc != null) {
                if (err_) |err| {
                    log.info("opaque dmabuf import refused ({s}); keeping the frame's own format", .{err.f_message orelse "(unknown)"});
                    err.free();
                    err_ = null;
                }
                priv.opaque_refused = true;
                builder.setFourcc(frame.fourcc);
                if (builder.build(dmabufDestroy, planes, &err_)) |t| break :retry t;
            }
            if (err_) |err|
                log.warn("failed to build dmabuf err={s}", .{err.f_message orelse "(unknown)"});
            return error.DmabufBuildFailed;
        };
        if (opaque_fourcc != null and !priv.opaque_refused) priv.frames_opaque += 1;

        // Swap out the old texture.
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture;
    }

    /// Destroy callback for `GdkDmabufTexture`. GDK calls this when the
    /// texture is released; we close the FDs and free the holder.
    fn dmabufDestroy(data: ?*anyopaque) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();

        const planes: *Planes = @ptrCast(@alignCast(data orelse return));
        planes.deinit();
        alloc.destroy(planes);
    }

    /// Holder for the pixel data backing a `GdkMemoryTexture`. GTK
    /// ref-counts the `GBytes` we hand it and calls `memoryDestroy`
    /// when it no longer needs the data, at which point we can return
    /// the pixels to the allocator.
    const MemoryHolder = struct {
        alloc: std.mem.Allocator,
        pixels: []u8,
    };

    /// Build a `GdkMemoryTexture` from a CPU memory frame and set it as
    /// our current texture, unrefing any previous texture. This is the
    /// fallback path for drivers that can't export DMA-BUFs.
    fn rebuildMemoryTexture(self: *Self, frame: ExportedFrame.Memory) !void {
        const priv = self.private();

        const app = Application.default();
        const alloc = app.allocator();

        const holder = alloc.create(MemoryHolder) catch |err| {
            // We own the pixels; make sure they don't leak.
            frame.deinit();
            return err;
        };
        errdefer alloc.destroy(holder);
        holder.* = .{ .alloc = alloc, .pixels = frame.pixels };

        // `GdkMemoryTexture` keeps a reference to the `GBytes` for as
        // long as it needs the pixel data, so we hand it our holder and
        // get the pixels freed via the destroy notify below.
        const bytes = glib.Bytes.newWithFreeFunc(
            holder.pixels.ptr,
            holder.pixels.len,
            &memoryDestroy,
            holder,
        );
        errdefer bytes.unref();

        const texture = gdk.MemoryTexture.new(
            @intCast(frame.width),
            @intCast(frame.height),
            .r8g8b8a8_premultiplied,
            bytes,
            frame.width * 4, // stride
        );

        // The texture holds its own reference to the bytes now.
        bytes.unref();

        // Swap out the old texture.
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture.as(gdk.Texture);
    }

    /// Destroy callback for the `GBytes` backing a `GdkMemoryTexture`.
    fn memoryDestroy(data: ?*anyopaque) callconv(.c) void {
        const holder: *MemoryHolder = @ptrCast(@alignCast(data orelse return));
        holder.alloc.free(holder.pixels);
        holder.alloc.destroy(holder);
    }

    //---------------------------------------------------------------
    // Class

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            // Virtual methods
            gtk.Widget.virtual_methods.realize.implement(class, &realize);
            gtk.Widget.virtual_methods.unrealize.implement(class, &unrealize);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);

            // Signals
            signals.resize.impl.register(.{});
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
