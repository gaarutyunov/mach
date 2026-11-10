//! mach.Core provides the ability to open windows, get input events, and ultimately render.
//!
//! # Units
//!
//! Firstly, Core does not expose the concept of monitors (because many platforms, such as mobile
//! phones, consoles, VR devices, browsers, etc. do not have meaningful information about these
//! available.) - instead we only expose the concept of a 'window' - a virtual surface which can be
//! rendered to.
//!
//! Secondly, a window's framebuffer is always allocated at the native display resolution. We do not
//! expose the ability to create a window framebuffer at a lesser resolution and allow the OS
//! compositor to upscale the contents to the native resolution (because while on macOS/iOS this is
//! available with your choice of nearest/bilinear/trilinear upscaling, on Windows only bilinear is
//! available, and on Wayland this depends on the compositor and what extensions are available, and
//! on Android this is usually bilinear but not guaranteed.) Instead, applications are responsible
//! for scaling their render output appropriately. As a result, GPU scissor rectangles, viewports,
//! etc. all operate in framebuffer coordinates.
//!
//! Each window exposes two notable scaling factors that you should be aware of when rendering:
//!
//! 1. `pixel_density`: this is the number of framebuffer texels per window pixel unit. For
//!    example, on a high DPI monitor, creating an 800x600px window may result in a framebuffer
//!    which is twice that size in native (physical) pixels. In this case, `width` and `height`
//!    would be 800x600, `framebuffer_width` and `framebuffer_height` would be 1600x1200, and
//!    `pixel_density` would be `2.0`. Fractional scaling is possible on some platforms.
//! 2. `display_scale`: this is how much bigger the user wants their UI to be, specifically text and
//!    UI elements which are sized relative to the size of text. This corresponds to e.g.
//!    'Display Scale: 150%' in the Microsoft Windows settings.
//!
//! Both scaling factors may change dynamically at runtime, e.g. as a window is dragged from one
//! display or another - or when a user updates their system preferences. Use the Resize and
//! DisplayScaleChanged events to get notified of changes to pixel density and display scale.
//!
//! For example, suppose we wanted to render a green square on the framebuffer, taking up the same
//! visual size as a single character of a 12pt font in other apps on their system. That square
//! would take up `12pt * display_scale * pixel_density` texels in the framebuffer.
//!
//! If we then wanted to stretch a texture of an actual glyph over that square when we render, a
//! glyph texture of `12pt * display_scale` would visually appear to be the right character, but on
//! high DPI (e.g. Retina) displays it would appear blurry, while a glyph texture of
//! `12pt * display_scale * pixel_density` would appear crisp on all displays.
//!
//! You can multiply window units by pixel_density to get framebuffer units, or divide framebuffer
//! units by it to get window units.
const std = @import("std");
const builtin = @import("builtin");

const mach = @import("main.zig");
const dvx_metrics = @import("dvx/metrics.zig");
const gpu = mach.gpu;
const log = std.log.scoped(.mach);

const Core = @This();

pub const mach_module = .mach_core;

pub const mach_systems = .{
    .main,
    .init,
    .tick,
    .snapshotStart,
    .snapshotEnd,
    .deinit,
};

/// Window objects managed by the platform.
windows: mach.Objects(
    // Set track_fields to true so that when these field values change, we know about it
    // and can update the platform windows.
    .{ .track_fields = true },
    struct {
        /// Window title string. May be a static string literal, or owned memory managed via
        /// `core.fmtTitle(window_id, fmt, args)` (which sets `title_owned` to track ownership).
        title: [:0]const u8 = "Mach Window",

        /// If non-null, a heap allocation backing `title` that Core owns and frees when a new
        /// title is set via `fmtTitle` or when the window is destroyed. Set/managed exclusively
        /// by `core.fmtTitle`; do not set this field directly.
        title_owned: ?[:0]u8 = null,

        /// Hash of the previous `fmtTitle` arguments. `fmtTitle` uses this to skip allocation
        /// and `setTitle` work when the inputs haven't changed since the last call, so that calling
        /// `fmtTitle` frequently is less expensive.
        title_hash: u64 = 0,

        /// Render callback
        on_render: ?mach.FunctionID = null,

        /// Texture format of the framebuffer (read-only)
        framebuffer_format: gpu.Texture.Format = .bgra8_unorm,

        /// Width of the window in virtual pixels
        width: u32 = 1920 / 2,

        /// Height of the window in virtual pixels
        height: u32 = 1080 / 2,

        /// Width of the framebuffer in texels (read-only)
        /// Will be updated to reflect the actual framebuffer dimensions after window creation.
        framebuffer_width: u32 = 1920 / 2,

        /// Height of the framebuffer in texels (read-only)
        /// Will be updated to reflect the actual framebuffer dimensions after window creation.
        framebuffer_height: u32 = 1080 / 2,

        /// Number of framebuffer texels per window pixel unit (read-only). See top-level Core docs.
        ///
        /// Updated whenever the window is moved to a display with a different DPI. See also the
        /// `.resize` event.
        pixel_density: f32 = 1.0,

        /// User-preferred UI scale factor (read-only). See top-level Core docs.
        ///
        /// Updated whenever the user changes their system display scale preferences. See also the
        /// `.display_scale_changed` event.
        ///
        /// * on Windows/Linux, this corresponds to the e.g. "Display Scale: 150%" in system
        ///   settings menus.
        /// * on macOS, this value is always 1.0 because macOS handles display scaling at the
        ///   compositor level (no app-side render scaling needed beyond consideration for
        ///   pixel_density)
        ///
        display_scale: f32 = 1.0,

        /// Vertical sync mode, prevents screen tearing.
        vsync_mode: VSyncMode = .triple,

        /// Window display mode: fullscreen, windowed or borderless fullscreen
        display_mode: DisplayMode = .windowed,

        /// Whether or not the cursor should be visible when it is inside the window.
        ///
        /// When the mouse is captured, the cursor is always invisible irrespective of this field.
        cursor_visible: bool = true,

        /// The shape the cursor should use when it is inside the window.
        cursor_shape: CursorShape = .arrow,

        /// Whether or not the mouse cursor should be captured by the window.
        ///
        /// Once set to true, the app requests to capture the mouse cursor - some platforms grant
        /// this request instantly, while others (e.g. browsers) prompt the user to allow it. If the
        /// request is denied, `mouse_capture` is set to `false` and a `.mouse_capture_lost` event
        /// is sent with `.denied = true`. If the request is approved, `mouse_capture` remains
        /// `true` and a `.mouse_capture_gained` event is sent.
        ///
        /// If the request was approved and your application sets `mouse_capture = false`, mouse
        /// capture is released and setting it to true again would be a different request.
        mouse_capture: bool = false,

        /// Target frames per second
        refresh_rate: u32 = 0,

        /// Whether window decorations (titlebar, borders, etc.) should be shown.
        ///
        /// Has no effect on windows who DisplayMode is .fullscreen or .fullscreen_borderless
        decorated: bool = true,

        /// Color of the window decorations, e.g. titlebar.
        ///
        /// if null, system chooses its defaults
        decoration_color: ?gpu.Color = null,

        /// Whether the window should be completely transparent or not.
        ///
        /// on macOS, you must also set decoration_color to a transparent color if you wish to have
        /// a fully transparent window as it controls the 'background color' of the window.
        transparent: bool = false,

        // GPU
        // When `native` is not null, the rest of the fields have been
        // initialized.
        device: *gpu.Device = undefined,
        instance: *gpu.Instance = undefined,
        adapter: *gpu.Adapter = undefined,
        queue: *gpu.Queue = undefined,
        swap_chain: *gpu.SwapChain = undefined,
        swap_chain_descriptor: gpu.SwapChain.Descriptor = undefined,
        surface: *gpu.Surface = undefined,
        surface_descriptor: gpu.Surface.Descriptor = undefined,

        // After window initialization, (when device is not null)
        // changing these will have no effect
        power_preference: gpu.PowerPreference = .undefined,
        required_features: ?[]const gpu.FeatureName = null,
        required_limits: ?gpu.Limits = null,
        swap_chain_usage: gpu.Texture.UsageFlags = .{
            .render_attachment = true,
        },

        /// Container for native platform-specific information
        native: ?Platform.Native = null,
    },
),

/// The current window being rendered. Only valid during an on_render() callback.
window: mach.ObjectID = undefined,

/// Callback system invoked when application is exiting (called on render thread).
on_exit: ?mach.FunctionID = null,

/// Current state of the application.
state: std.atomic.Value(State) = .init(.running),

frame: mach.time.Frequency,
input: mach.time.Frequency,

/// Engine metrics, readable from any thread.
metrics: Metrics = .{},
/// Measures `metrics.frame_time_ns`, used only on the render thread.
frame_timer: mach.time.Timer = undefined,

/// Mutex protecting the render snapshot itself (e.g. render_graph or snapshotted objects.)
/// The app thread holds this between snapshotStart and snapshotEnd, and the render thread
/// holds this during the whole render to prevent the app thread from getting ahead duplicate
/// frames.
render_mu: std.Io.Mutex = .init,

/// Signaled by the app thread after snapshotEnd to indicate a new frame is ready
/// for the render thread to consume.
frame_ready: std.Io.Event = .unset,

// Internal module state
allocator: std.mem.Allocator,
io: std.Io,
/// Core's context, for logging from functions which aren't systems (e.g. `initWindow`, called by
/// the platform backends).
ctx: mach.Context,

backend_events_mu: std.Io.Mutex = .init,
backend_events: std.ArrayList(Event) = .empty,

events_ready: std.Io.Event = .unset,
iter_events: std.ArrayList(Event) = .empty,
input_state: InputState,
oom: std.atomic.Value(bool) = .init(false),
render_graph: mach.Graph,

const ms: u64 = 1_000_000;

/// Time between presented frames in nanoseconds.
pub const FrameTimeHistogram = dvx_metrics.Histogram(&.{
    1 * ms, 2 * ms, 4 * ms, 7 * ms, 9 * ms, 12 * ms, 17 * ms, 21 * ms, 26 * ms, 34 * ms, 50 * ms, 100 * ms, 250 * ms,
});

pub const Metrics = struct {
    frame_time_ns: FrameTimeHistogram = .{},
};

pub const State = enum(u8) {
    running,
    exiting,
    exited,
};

pub fn init(core: *Core, ctx: mach.Context) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    // TODO: fix all leaks
    // TODO(leak)
    try mach.sysgpu.Impl.init(allocator, .{});

    core.* = .{
        // Note: since core.windows is initialized for us already, we just copy the pointer.
        .windows = core.windows,

        .allocator = allocator,
        .io = io,
        .ctx = ctx,
        .input_state = .{},
        .render_graph = undefined,

        .input = .{ .target = 0 },
        .frame = .{ .target = 1 },
    };

    // TODO(leak)
    try core.backend_events.ensureTotalCapacity(allocator, 8192);
    try core.iter_events.ensureTotalCapacity(allocator, 8192);

    // TODO(leak)
    try mach.initGraph(&core.render_graph, allocator, io, .render);

    core.frame.start(io);
    core.frame_timer = .start(io);
    core.input.start(io);
}

/// Caller must hold core.windows.lock
pub fn initWindow(core: *Core, window_id: mach.ObjectID) !void {
    var ctx = core.ctx;
    ctx.system_name = "initWindow";
    ctx.schedule = .{};
    var core_window = core.windows.getValue(window_id);
    defer core.windows.setValueRaw(window_id, core_window);

    // All windows share the same GPU device; only the surface and swap chain are per-window.
    const existing_gpu = blk: {
        var windows = core.windows.slice();
        while (windows.next()) |wid| {
            if (wid == window_id) continue;
            const w = core.windows.getValue(wid);
            if (w.native != null) break :blk w;
        }
        break :blk null;
    };

    // Reuse the device/instance/adapter/queue from an existing window if available.
    if (existing_gpu) |existing| {
        core_window.instance = existing.instance;
        core_window.adapter = existing.adapter;
        core_window.device = existing.device;
        core_window.queue = existing.queue;
    } else {
        core_window.instance = gpu.createInstance(null) orelse {
            ctx.err("failed to create GPU instance", .{});
            std.process.exit(1);
        };

        var response: RequestAdapterResponse = undefined;
        core_window.instance.requestAdapter(&gpu.RequestAdapterOptions{
            .compatible_surface = null,
            .power_preference = core_window.power_preference,
            .force_fallback_adapter = .false,
        }, &response, requestAdapterCallback);
        if (response.status != .success) {
            ctx.err("failed to create GPU adapter: {?s}", .{response.message});
            if (builtin.target.os.tag == .linux) {
                ctx.info("-> maybe try MACH_FORCE_GPU_BACKEND=opengl ?", .{});
            }
            std.process.exit(1);
        }

        var props = std.mem.zeroes(gpu.Adapter.Properties);
        response.adapter.?.getProperties(&props);
        if (props.backend_type == .null) {
            ctx.err("no backend found for {s} adapter", .{props.adapter_type.name()});
            std.process.exit(1);
        }
        ctx.info("found {s} backend on {s} adapter: {s}, {s}", .{
            props.backend_type.name(),
            props.adapter_type.name(),
            props.name,
            props.driver_description,
        });

        core_window.adapter = response.adapter.?;
        core_window.device = response.adapter.?.createDevice(&.{
            .required_features_count = if (core_window.required_features) |v| @as(u32, @intCast(v.len)) else 0,
            .required_features = if (core_window.required_features) |v| @as(?[*]const gpu.FeatureName, v.ptr) else null,
            .required_limits = if (core_window.required_limits) |limits| @as(?*const gpu.RequiredLimits, &gpu.RequiredLimits{
                .limits = limits,
            }) else null,
            .device_lost_callback = &deviceLostCallback,
            .device_lost_userdata = null,
        }) orelse {
            ctx.err("failed to create GPU device", .{});
            std.process.exit(1);
        };
        core_window.device.setUncapturedErrorCallback({}, printUnhandledErrorCallback);
        core_window.queue = core_window.device.getQueue();
    }

    // Create window surface
    core_window.surface = core_window.instance.createSurface(&core_window.surface_descriptor);

    // Create swap chain
    core_window.swap_chain_descriptor = gpu.SwapChain.Descriptor{
        .label = "main swap chain",
        .usage = core_window.swap_chain_usage,
        .format = .bgra8_unorm,
        .width = core_window.framebuffer_width,
        .height = core_window.framebuffer_height,
        .present_mode = switch (core_window.vsync_mode) {
            .none_low_latency, .none_max_throughput => .immediate,
            .double, .adaptive => .fifo,
            .triple => .fifo,
            .low_latency => .mailbox,
        },
        .max_buffered_frames = switch (core_window.vsync_mode) {
            .double, .adaptive => 2,
            .triple, .low_latency, .none_max_throughput => 3,
            .none_low_latency => 2,
        },
    };
    core_window.swap_chain = core_window.device.createSwapChain(core_window.surface, &core_window.swap_chain_descriptor);

    // Emit open event
    core.pushEvent(.{ .open = .{ .window_id = window_id } });
}

/// Render all windows, must be called on the render thread.
pub fn renderFrame(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    // Hold render_mu only during GPU command recording (on_render) so the app thread can start its
    // next snapshot while we present.
    {
        core.render_mu.lockUncancelable(io);
        defer core.render_mu.unlock(io);
        mach.module_threads.renderLock(true);
        defer mach.module_threads.renderLock(false);

        core.windows.lockShared();
        defer core.windows.unlockShared();
        var windows = core.windows.slice();
        while (windows.next()) |window_id| {
            const core_window = core.windows.getValue(window_id);
            if (core_window.native == null) continue;
            const on_render = core_window.on_render orelse continue;

            // Allow on_render to read the current window being rendered.
            core.window = window_id;

            // Run on_render for the window with the windows lock released so user code may take it.
            core.windows.unlockShared();
            core_mod.run(on_render);
            core.windows.lockShared();

            // Ensure nobody reads the window outside on_render.
            core.window = undefined;
        }
    }

    // Present all windows and tick the shared device outside render_mu so the app thread can
    // prepare the next frame during GPU submission.
    var shared_device: ?*gpu.Device = null;
    {
        core.windows.lockShared();
        defer core.windows.unlockShared();
        var windows = core.windows.slice();
        while (windows.next()) |window_id| {
            const core_window = core.windows.getValue(window_id);
            if (core_window.native == null) continue;

            shared_device = core_window.device;
            core_window.swap_chain.present();
        }
    }

    // Device tick.
    if (shared_device) |device| mach.sysgpu.Impl.deviceTick(device);

    // Frame rate counter.
    core.frame.tick();
    if (dvx_metrics.enabled) core.metrics.frame_time_ns.observe(core.frame_timer.lapPrecise());
    mach.tracy.frameMark();
}

pub fn tick(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    try Platform.tick(core, core_mod, io);
    try core.handleExit(core_mod);
}

/// Begin submitting a snapshot for rendering the next frame.
pub fn snapshotStart(core: *Core, io: std.Io) !void {
    // Free windows whose native resources have been torn down already by the platform backend. This
    // happens here on the app thread before the snapshot so that the render thread never sees a
    // freed window.
    {
        core.windows.lock();
        defer core.windows.unlock();
        var deleted_windows = core.windows.sliceDeleted();
        while (deleted_windows.next()) |window_id| {
            if (core.windows.get(window_id, .native) != null) continue;
            core.windows.free(window_id);
        }
    }

    core.render_mu.lockUncancelable(io);
    mach.module_threads.renderLock(true);
    Platform.wakeMainThread(core);
    try core.render_graph.copyFrom(core.windows.internal.graph, core.allocator);
}

/// End submission of a snapshot for rendering the next frame.
pub fn snapshotEnd(core: *Core, io: std.Io) void {
    mach.module_threads.renderLock(false);
    core.render_mu.unlock(io);
    core.frame_ready.set(io);
}

/// Sets the window title using a format string. Core owns the resulting allocation and frees it
/// on the next `fmtTitle` call (or when the window is destroyed), so callers do not need to manage
/// the buffer's lifetime.
///
/// The hashed inputs are compared against the previous call's inputs and the work is skipped when
/// they are unchanged, so it is safe and cheap to call this every frame.
///
/// Example:
/// ```
/// core.windows.lock();
/// defer core.windows.unlock();
/// try core.fmtTitle(window_id, "myapp [ {d}fps ] [ Input {d}hz ]", .{
///     core.frame.rate, core.input.rate,
/// });
/// ```
pub fn fmtTitle(
    core: *Core,
    window_id: mach.ObjectID,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    // If the hashed inputs wouldn't actually change the title, nothing to do.
    const hash = hashTitleArgs(fmt, args);
    if (core.windows.get(window_id, .title_hash) == hash) return;

    const new_title = try std.fmt.allocPrintSentinel(core.allocator, fmt, args, 0);
    if (core.windows.get(window_id, .title_owned)) |prev| core.allocator.free(prev);
    core.windows.set(window_id, .title_owned, new_title);
    core.windows.set(window_id, .title, new_title);
    core.windows.set(window_id, .title_hash, hash);
}

fn hashTitleArgs(comptime fmt: []const u8, args: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(fmt);
    inline for (args) |arg| hashValue(&hasher, arg);
    return hasher.final();
}

fn hashValue(hasher: anytype, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                hasher.update(std.mem.sliceAsBytes(value));
            } else {
                std.hash.autoHash(hasher, value);
            }
        },
        else => std.hash.autoHash(hasher, value),
    }
}

/// Core.main enters the platform's main loop, which drives rendering on the main thread.
///
/// The app is responsible for running its own tick logic, either:
/// * In `on_render` for single-threaded apps, or
/// * On a separate app thread via `mach.AppThread`.
pub fn main(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    if (core.on_exit == null) @panic("core.on_exit callback must be set");
    mach.module_threads.setName("main");

    try Platform.tick(core, core_mod, io);

    // Platform drives the main loop (render thread).
    Platform.run(platform_update_callback, .{ core, core_mod, io });

    // Platform.run is marked noreturn on some platforms, but not all, so this is here for the
    // platforms that do return
    std.process.exit(0);
}

fn platform_update_callback(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !bool {
    try Platform.tick(core, core_mod, io);
    try core.handleExit(core_mod);
    return core.state.load(.acquire) != .exited;
}

fn handleExit(core: *Core, core_mod: mach.Mod(Core)) !void {
    if (core.state.load(.acquire) == .exiting) {
        if (core.on_exit) |on_exit| core_mod.run(on_exit);
        core_mod.call(.deinit);
    }
}

/// Signal that the application should exit. Thread-safe.
pub fn exit(core: *Core) void {
    core.state.store(.exiting, .release);
    core.events_ready.set(core.io);
    Platform.wakeMainThread(core);
}

pub fn deinit(core: *Core) !void {
    core.state.store(.exited, .release);

    // Release per-window resources first, then shared GPU objects once.
    var shared_device: ?*gpu.Device = null;
    var shared_queue: ?*gpu.Queue = null;
    var shared_adapter: ?*gpu.Adapter = null;
    var shared_instance: ?*gpu.Instance = null;

    var windows = core.windows.slice();
    while (windows.next()) |window_id| {
        var core_window = core.windows.getValue(window_id);

        // Free any heap-allocated title owned by Core via fmtTitle().
        if (core_window.title_owned) |owned| core.allocator.free(owned);

        if (core_window.native == null) continue;

        core_window.swap_chain.release();
        core_window.surface.release();

        // Track shared objects for single release.
        shared_device = core_window.device;
        shared_queue = core_window.queue;
        shared_adapter = core_window.adapter;
        shared_instance = core_window.instance;
    }

    if (shared_queue) |q| q.release();
    if (shared_device) |d| d.release();
    if (shared_adapter) |a| a.release();
    if (shared_instance) |i| i.release();

    core.render_graph.deinit(core.allocator);
    core.backend_events.deinit(core.allocator);
    core.iter_events.deinit(core.allocator);
}

pub const EventMode = union(enum) {
    /// Picks either `.poll` (if any window has vsync disabled) or `.adaptive` otherwise.
    default,
    /// Never blocks.
    poll,
    /// Blocks until there is at least one event.
    wait,
    /// Alias for .adaptive_frequency = .{ .min = 120 }
    adaptive,
    /// Blocks as needed to run at the target minimum frequency, but immediately unblocks if at
    /// an event is available.
    ///
    /// Use this to e.g. run your event handling loop at 120hz, but allow the loop to run faster
    /// (e.g. at 1000hz) if the user has a very fast gaming mouse producing events quickly.
    adaptive_frequency: struct {
        min: u32,
    },
    /// Blocks as needed to run at the target frequency.
    ///
    /// Use this to e.g. run your event handling loop at 120hz, and generally not allow it to run
    /// faster even if the user has a very fast input device producing events quickly.
    fixed_frequency: struct {
        target: u32,
    },
};

pub const EventIterator = struct {
    events: []const Event,
    index: usize = 0,

    pub fn next(self: *EventIterator) ?Event {
        if (self.index >= self.events.len) return null;
        const event = self.events[self.index];
        self.index += 1;
        return event;
    }
};

/// Returns an iterator over events using the specified mode for pacing/blocking.
///
/// Events are always buffered between calls to events() so none are lost, the mode strictly
/// controls pacing of your event handling loop itself.
pub fn events(core: *@This(), mode_arg: EventMode) EventIterator {
    Platform.wakeMainThread(core);

    // Resolve .default and .adaptive aliases to a concrete mode.
    const mode: EventMode = switch (mode_arg) {
        .default => blk: {
            core.windows.lockShared();
            defer core.windows.unlockShared();
            var windows = core.windows.slice();
            while (windows.next()) |wid| {
                if (core.windows.get(wid, .vsync_mode).isNone()) break :blk .poll;
            }
            break :blk .{ .adaptive_frequency = .{ .min = 120 } };
        },
        .adaptive => .{ .adaptive_frequency = .{ .min = 120 } },
        else => mode_arg,
    };

    // Set target before tick so delay_ns is computed correctly.
    switch (mode) {
        .adaptive_frequency => |f| core.input.target = f.min,
        .fixed_frequency => |f| core.input.target = f.target,
        else => {},
    }
    core.input.tick();

    // Handle pacing, and ensure we have core.backend_events_mu locked.
    switch (mode) {
        .poll => {
            core.backend_events_mu.lockUncancelable(core.io);
        },
        .wait => {
            core.backend_events_mu.lockUncancelable(core.io);
            if (core.backend_events.items.len == 0) {
                // No events yet — release the mutex and block until an event is pushed.
                core.backend_events_mu.unlock(core.io);
                core.events_ready.waitUncancelable(core.io);
                core.backend_events_mu.lockUncancelable(core.io);
            }
        },
        .adaptive_frequency => {
            // Wait until an event arrives OR we've waited for delay_ns, whichever comes first.
            if (core.input.delay_ns > 0) {
                core.events_ready.waitTimeout(core.io, .{
                    .duration = .{
                        .raw = .{ .nanoseconds = @intCast(core.input.delay_ns) },
                        .clock = .awake,
                    },
                }) catch {};
            }
            core.backend_events_mu.lockUncancelable(core.io);
        },
        .fixed_frequency => {
            if (core.input.delay_ns > 0) {
                core.io.sleep(.{ .nanoseconds = @intCast(core.input.delay_ns) }, .awake) catch {};
            }
            core.backend_events_mu.lockUncancelable(core.io);
        },
        .adaptive, .default => unreachable,
    }

    // Reset the event now that we hold the mutex and are about to drain all events.
    // Any events pushed after this point will re-set it via pushEvent.
    core.events_ready.reset();

    // With the mutex held from above, swap the backend_events (new events) and iter_events (handled events) buffers.
    std.mem.swap(std.ArrayList(Event), &core.backend_events, &core.iter_events);
    core.backend_events.clearRetainingCapacity();
    core.backend_events_mu.unlock(core.io);

    // Update input_state from swapped events.
    for (core.iter_events.items) |event| {
        switch (event) {
            .key_press => |ev| core.input_state.keys.setValue(@backingInt(ev.key), true),
            .key_release => |ev| core.input_state.keys.setValue(@backingInt(ev.key), false),
            .mouse_press => |ev| core.input_state.mouse_buttons.setValue(@backingInt(ev.button), true),
            .mouse_release => |ev| core.input_state.mouse_buttons.setValue(@backingInt(ev.button), false),
            .mouse_motion => |ev| core.input_state.mouse_position = ev.pos,
            .focus_lost => {
                // Clear input state that may be 'stuck' when focus is regained.
                core.input_state.keys = InputState.KeyButtonBitSet.empty;
                core.input_state.mouse_buttons = InputState.MouseButtonSet.empty;
            },
            else => {},
        }
    }

    return .{ .events = core.iter_events.items };
}

/// Push an event onto the event queue. Thread-safe.
pub inline fn pushEvent(core: *@This(), event: Event) void {
    core.backend_events_mu.lockUncancelable(core.io);
    core.backend_events.append(core.allocator, event) catch {
        core.backend_events_mu.unlock(core.io);
        core.oom.store(true, .release);
        return;
    };
    core.backend_events_mu.unlock(core.io);
    core.events_ready.set(core.io);
}

/// Reports whether mach.Core ran out of memory, indicating events may have been dropped.
///
/// Once called, the OOM flag is reset and mach.Core will continue operating normally.
pub fn outOfMemory(core: *@This()) bool {
    if (!core.oom.load(.acquire)) return false;
    core.oom.store(false, .release);
    return true;
}

/// Whether or not the given key button ID is currently pressed down or not.
pub fn keyPressed(core: *@This(), key: KeyButtonID) bool {
    return core.input_state.keyPressed(key);
}

/// Whether or not the given key button ID is currently released (not pressed down).
pub fn keyReleased(core: *@This(), key: KeyButtonID) bool {
    return core.input_state.keyReleased(key);
}

/// Whether or not the given mouse button ID is currently pressed down or not.
pub fn mousePressed(core: *@This(), button: MouseButtonID) bool {
    return core.input_state.mousePressed(button);
}

/// Whether or not the given mouse button ID is currently released (not pressed down).
pub fn mouseReleased(core: *@This(), button: MouseButtonID) bool {
    return core.input_state.mouseReleased(button);
}

/// The current mouse position.
pub fn mousePosition(core: *@This()) Position {
    return core.input_state.mouse_position;
}

inline fn requestAdapterCallback(
    context: *RequestAdapterResponse,
    status: gpu.RequestAdapterStatus,
    adapter: ?*gpu.Adapter,
    message: ?[*:0]const u8,
) void {
    context.* = RequestAdapterResponse{
        .status = status,
        .adapter = adapter,
        .message = message,
    };
}

// TODO(important): expose device loss to users, this can happen especially in the web and on mobile
// devices. Users will need to re-upload all assets to the GPU in this event.
fn deviceLostCallback(reason: gpu.Device.LostReason, msg: [*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    if (reason == .destroyed) return;
    log.err("mach: device lost: {s}", .{msg});
    @panic("mach: device lost");
}

pub inline fn printUnhandledErrorCallback(_: void, ty: gpu.ErrorType, message: [*:0]const u8) void {
    switch (ty) {
        .validation => std.log.err("gpu: validation error: {s}\n", .{message}),
        .out_of_memory => std.log.err("gpu: out of memory: {s}\n", .{message}),
        .device_lost => std.log.err("gpu: device lost: {s}\n", .{message}),
        .unknown => std.log.err("gpu: unknown error: {s}\n", .{message}),
        else => unreachable,
    }
    std.process.exit(1);
}

pub fn detectBackendType(allocator: std.mem.Allocator) !gpu.BackendType {
    _ = allocator;
    // TODO(env): upgrade to https://codeberg.org/ziglang/zig/pulls/30644 by properly passing
    // env around
    const backend_ptr = std.c.getenv("MACH_FORCE_GPU_BACKEND") orelse {
        return if (builtin.target.os.tag.isDarwin()) .metal else if (builtin.target.os.tag == .windows) .d3d12 else .vulkan;
    };
    const backend = std.mem.sliceTo(backend_ptr, 0);

    if (std.ascii.eqlIgnoreCase(backend, "null")) return .null;
    if (std.ascii.eqlIgnoreCase(backend, "d3d11")) return .d3d11;
    if (std.ascii.eqlIgnoreCase(backend, "d3d12")) return .d3d12;
    if (std.ascii.eqlIgnoreCase(backend, "metal")) return .metal;
    if (std.ascii.eqlIgnoreCase(backend, "vulkan")) return .vulkan;
    if (std.ascii.eqlIgnoreCase(backend, "opengl")) return .opengl;
    if (std.ascii.eqlIgnoreCase(backend, "opengles")) return .opengles;

    @panic("unknown MACH_FORCE_GPU_BACKEND type");
}

const Platform = switch (builtin.target.os.tag) {
    .wasi => @panic("TODO: support mach.Core WASM platform"),
    .ios => @panic("TODO: support mach.Core IOS platform"),
    .windows => @import("core/Windows.zig"),
    .linux => blk: {
        if (builtin.target.abi.isAndroid())
            @panic("TODO: support mach.Core Android platform");
        break :blk @import("core/Linux.zig");
    },
    .macos => @import("core/Darwin.zig"),
    else => {},
};

pub const InputState = struct {
    const KeyButtonBitSet = std.StaticBitSet(@as(u8, @backingInt(KeyButtonID.max)) + 1);
    const MouseButtonSet = std.StaticBitSet(@as(u4, @backingInt(MouseButtonID.max)) + 1);

    keys: KeyButtonBitSet = KeyButtonBitSet.empty,
    mouse_buttons: MouseButtonSet = MouseButtonSet.empty,
    mouse_position: Position = .{ .x = 0, .y = 0 },

    pub inline fn keyPressed(input: InputState, key: KeyButtonID) bool {
        return input.keys.isSet(@backingInt(key));
    }

    pub inline fn keyReleased(input: InputState, key: KeyButtonID) bool {
        return !input.keyPressed(key);
    }

    pub inline fn mousePressed(input: InputState, button: MouseButtonID) bool {
        return input.mouse_buttons.isSet(@backingInt(button));
    }

    pub inline fn mouseReleased(input: InputState, button: MouseButtonID) bool {
        return !input.mousePressed(button);
    }
};

pub const Event = union(enum) {
    /// Sent when a window opens.
    open: Open,

    /// Sent when a window is closed.
    close: Close,

    /// Sent when the window's display_scale changes (e.g. when the user changes their system
    /// display scale preferences.)
    display_scale_changed: DisplayScaleChanged,

    /// Sent when a window or its framebuffer is resized, including when the pixel_density
    /// changes (e.g. when the window is moved to a display with a different DPI.)
    resize: Resize,

    /// Sent when a window gains focus.
    focus_gained: FocusGained,

    /// Sent when a window loses focus.
    focus_lost: FocusLost,

    /// Sent once when a key button is pressed down.
    ///
    /// Do not use this event for text input, use the `.char_input` event instead.
    key_press: Key,

    /// Sent at the platform-specified rate when a key button is held down, and continues to be held
    /// down.
    ///
    /// Do not use this event for text input, use the `.char_input` event instead.
    key_repeat: Key,

    /// Sent once when a key button is released.
    ///
    /// Do not use this event for text input, use the `.char_input` event instead.
    key_release: Key,

    /// Sent when the user is trying to input text.
    char_input: CharInput,

    /// Sent when the mouse cursor moves.
    ///
    /// Not sent if the mouse is captured (i.e. after `.mouse_capture_gained` has been sent).
    mouse_motion: MouseMotion,

    /// Sent when the mouse moves while the window has the mouse captured, providing raw mouse
    /// motion deltas.
    mouse_motion_relative: MouseMotionRelative,

    /// Sent when a request to capture the mouse pointer succeeded.
    ///
    /// See the Window `.mouse_capture` field for more information.
    mouse_capture_gained: MouseCaptureGained,

    /// Sent when the mouse capture is lost:
    /// * The platform declined the capture request (`.denied = true`), or
    /// * The window lost focus, or
    /// * The application set `Window.mouse_capture = false`, or
    /// * The platform revoked the capture for any other reason.
    mouse_capture_lost: MouseCaptureLost,

    /// Sent once when a mouse button is pressed down.
    mouse_press: MouseButton,

    /// Sent once when a mouse button is released.
    mouse_release: MouseButton,

    /// Sent when the mouse wheel is scrolled.
    mouse_scroll: MouseScroll,

    /// Sent when a user performs a zoom gesture.
    ///
    /// Only supported on macOS currently.
    zoom_gesture: ZoomGesture,

    pub const Key = struct {
        window_id: mach.ObjectID,
        key: KeyButtonID,
        mods: KeyMods,
    };

    pub const CharInput = struct {
        window_id: mach.ObjectID,
        codepoint: u21,
    };

    pub const MouseMotion = struct {
        window_id: mach.ObjectID,

        /// Mouse position, in window units, with sub-pixel precision when possible.
        pos: Position,
    };

    pub const MouseMotionRelative = struct {
        window_id: mach.ObjectID,

        /// Horizontal mouse delta in window units since the last motion event.
        dx: f64,

        /// Vertical mouse delta in window units since the last motion event.
        dy: f64,
    };

    pub const MouseCaptureGained = struct {
        window_id: mach.ObjectID,
    };

    pub const MouseCaptureLost = struct {
        window_id: mach.ObjectID,

        /// Whether or not the mouse capture request was denied. If it was granted but subsequently
        /// lost, this will be false (e.g. focus loss, application set `.mouse_capture = false`,
        /// etc.)
        denied: bool,
    };

    pub const MouseButton = struct {
        window_id: mach.ObjectID,
        button: MouseButtonID,
        mods: KeyMods,

        /// Mouse position, in window units, with sub-pixel precision when possible.
        pos: Position,
    };

    pub const MouseScroll = struct {
        window_id: mach.ObjectID,
        xoffset: f32,
        yoffset: f32,
    };

    pub const Resize = struct {
        window_id: mach.ObjectID,

        /// New window size, in window units.
        window_size: Size,

        /// New framebuffer size, in framebuffer units.
        framebuffer_size: Size,

        /// New number of framebuffer texels per window unit. See top-level Core docs for what this
        /// represents.
        pixel_density: f32,
    };

    pub const DisplayScaleChanged = struct {
        window_id: mach.ObjectID,

        /// New display scale factor. See top-level Core docs for what this represents.
        display_scale: f32,
    };

    pub const Open = struct {
        window_id: mach.ObjectID,
    };

    pub const ZoomGesture = struct {
        window_id: mach.ObjectID,
        phase: GesturePhase,
        zoom: f32,
    };

    pub const FocusGained = struct {
        window_id: mach.ObjectID,
    };

    pub const FocusLost = struct {
        window_id: mach.ObjectID,
    };

    pub const Close = struct {
        window_id: mach.ObjectID,
    };
};

pub const MouseButtonID = enum {
    left,
    right,
    middle,
    four,
    five,
    six,
    seven,
    eight,

    pub const max = MouseButtonID.eight;
};

pub const KeyMods = packed struct(u16) {
    shift: bool,
    control: bool,
    alt: bool,
    super: bool,
    caps_lock: bool,
    num_lock: bool,
    help: bool,
    function: bool,
    _padding: u8 = 0,
};

pub const GesturePhase = enum {
    none,
    may_begin,
    began,
    changed,
    stationary,
    ended,
    cancelled,
};

/// A keyboard button ID, a virtual 'scancode' (not mapping to actual USB or PS/2 scancodes).
///
/// This is a physical button identifier, irrespective of keyboard layout. For example, `.w` is used
/// to identify the key in the QWERTY keyboard layout "W" location, even if the keyboard is actually
/// AZERTY layout or any other non-QWERTY layout.
///
/// This lets you e.g. map WASD keyboard movement to the same physical location on all keyboards,
/// irrespective of layout.
pub const KeyButtonID = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,

    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_comma,
    kp_equal,
    kp_enter,

    enter,
    escape,
    tab,
    left_shift,
    right_shift,
    left_control,
    right_control,
    left_alt,
    right_alt,
    left_super,
    right_super,
    menu,
    num_lock,
    caps_lock,
    print,
    scroll_lock,
    pause,
    delete,
    home,
    end,
    page_up,
    page_down,
    insert,
    left,
    right,
    up,
    down,
    backspace,
    space,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    grave,

    iso_backslash,
    international1,
    international2,
    international3,
    international4,
    international5,
    lang1,
    lang2,

    unknown,

    pub const max = KeyButtonID.unknown;
};

pub const DisplayMode = enum {
    /// Windowed mode.
    windowed,

    /// Fullscreen mode, using this option may change the display's video mode.
    fullscreen,

    /// Borderless fullscreen window.
    ///
    /// Beware that true .fullscreen is also a hint to the OS that is used in various contexts, e.g.
    ///
    /// * macOS: Moving to a virtual space dedicated to fullscreen windows as the user expects
    /// * macOS: .fullscreen_borderless windows cannot prevent the system menu bar from being
    ///          displayed, which makes it appear 'not fullscreen' to users who are familiar with
    ///          macOS.
    ///
    /// Always allow users to choose their preferred display mode.
    fullscreen_borderless,
};

/// Controls how frames are buffered, synchronized, and presented with the display/compositor.
///
/// | VSyncMode              | Present Mode | Metal (macOS)                      | Metal (iOS)                 | D3D12                                          | Vulkan          | WebAssembly           |
/// |------------------------|--------------|------------------------------------|-----------------------------|------------------------------------------------|-----------------|-----------------------|
/// | `.double`              | fifo         | displaySync=on, 2 drawables        | displaySync=on, 2 drawables | 2 buffers, flip-sequential                     | minImageCount=2 | requestAnimationFrame |
/// | `.triple`              | fifo         | displaySync=on, 3 drawables        | displaySync=on, 3 drawables | 3 buffers, flip-discard                        | minImageCount=3 | same as `.double`     |
/// | `.low_latency`         | mailbox      | same as `.double`                  | same as `.double`           | 3 buffers, flip-discard, SetMaxFrameLatency(1) | minImageCount=3 | same as `.double`     |
/// | `.adaptive`            | fifo_relaxed | same as `.double`                  | same as `.double`           | `DXGI_PRESENT_ALLOW_TEARING` per-present       | minImageCount=2 | same as `.double`     |
/// | `.none_low_latency`    | immediate    | displaySync=off, 3 drawables[1][2] | same as `.double`[2]        | 2 buffers, `SetMaxFrameLatency(1)`, waitable   | minImageCount=2 | same as `.double`     |
/// | `.none_max_throughput` | immediate    | displaySync=off, 3 drawables[2]    | same as `.double`[2]        | 3 buffers, `SetMaxFrameLatency(2)`             | minImageCount=3 | same as `.double`     |
///
/// 1. Metal clamps to 3 drawables when displaySync is off, so `.none_low_latency` is the same as
///    `.none_max_throughput`.
/// 2. Metal APIs generally do not allow outpacing the compositors' frame rate, so .none vsync
///    typically run about 3x the usual refresh rate, although sometimes higher in fullscreen.
/// 3. iOS: displaySyncEnabled is always true; disabling vsync is not supported.
///
pub const VSyncMode = enum {
    /// May cause tearing, may stall GPU. Aims for lowest latency, not highest FPS.
    none_low_latency,

    /// Traditional "vsync off"
    ///
    /// May cause tearing. Aims for highest frame rate, not lowest latency.
    none_max_throughput,

    /// Traditional "double bufferring"
    ///
    /// No tearing. Double buffered. Framerate halves on missed deadlines.
    double,

    /// No tearing. Triple-buffered. No GPU stalls, all frames shown in order.
    triple,

    /// No tearing. Lowest latency. Discards stale frames, wastes GPU work.
    low_latency,

    /// No tearing, but Vtears on missed deadlines instead of halving framerate.
    adaptive,

    pub fn isNone(mode: VSyncMode) bool {
        return mode == .none_low_latency or mode == .none_max_throughput;
    }
};

pub const Size = struct {
    width: u32,
    height: u32,

    pub inline fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }
};

pub const CursorShape = enum {
    arrow,
    ibeam,
    crosshair,
    pointing_hand,
    resize_ew,
    resize_ns,
    resize_nwse,
    resize_nesw,
    resize_all,
    not_allowed,
};

pub const Position = struct {
    x: f64,
    y: f64,
};

const RequestAdapterResponse = struct {
    status: gpu.RequestAdapterStatus,
    adapter: ?*gpu.Adapter,
    message: ?[*:0]const u8,
};

fn assertHasDecl(comptime T: anytype, comptime decl_name: []const u8) void {
    if (!@hasDecl(T, decl_name)) @compileError(@typeName(T) ++ " missing declaration: " ++ decl_name);
}

fn assertHasField(comptime T: anytype, comptime field_name: []const u8) void {
    if (!@hasField(T, field_name)) @compileError(@typeName(T) ++ " missing field: " ++ field_name);
}

test {
    _ = Platform;
    @import("std").testing.refAllDecls(VSyncMode);
    @import("std").testing.refAllDecls(Size);
    @import("std").testing.refAllDecls(Position);
    @import("std").testing.refAllDecls(Event);
    @import("std").testing.refAllDecls(MouseButtonID);
    @import("std").testing.refAllDecls(KeyButtonID);
    @import("std").testing.refAllDecls(KeyMods);
    @import("std").testing.refAllDecls(DisplayMode);
    @import("std").testing.refAllDecls(CursorShape);
}
