//! Developer overlay: a semi-transparent panel showing frame timing, object counts and
//! per-module memory (pool usage, peak, budget, allocation rate and a suggested budget), to help
//! tune `mach.Modules.InitOptions.budgets`.
//!
//! Toggle with Ctrl+Alt+Shift+D (the same chord as YouTube's "Stats for nerds"), or set
//! `MACH_DEV_OVERLAY=1` to show it from startup.
//!
//! Usage from the app (register `mach.dvx.DevOverlay` in your `mach.Modules`):
//! * schedule `.{ dvx.DevOverlay, .init }` before the app's init, then call `attach()` with the
//!   window
//! * forward key presses to `handleKey()`, ignoring those it consumed
//! * schedule `.{ dvx.DevOverlay, .update }` each tick and `.{ dvx.DevOverlay, .snapshot }` in the
//!   render snapshot (between `Core.snapshotStart` and `Core.snapshotEnd`)
//! * optionally, show app-specific info (scene, entity counts, ...) with `setAppInfo()`
//! * call `render()` from the render callback, after the frame has been drawn
const std = @import("std");
const mach = @import("../main.zig");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;
const time = mach.time;
const metrics = @import("metrics.zig");

const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const DevOverlay = @This();

pub const mach_module = .mach_dvx_dev_overlay;

pub const mach_systems = .{ .init, .update, .snapshot };

const max_lines = 20;
const max_line_len = 160;
const max_modules = 12;

/// Sizes are in window units.
const font_size = 15.0;
/// gfx.Text divides glyph sizes and line height by a fixed pixel density of 2 (see its TODO), so
/// styles ask for twice the size.
const style_font_size = font_size * 2;
const padding = 10.0;
const margin = 12.0;
/// Rough average glyph advance relative to font size, for sizing the panel.
const glyph_advance = 0.4;

const refresh_seconds = 0.25;
const bg_color = [4]u8{ 8, 8, 12, 185 };

const label = @tagName(mach_module);

allocator: std.mem.Allocator,
io: std.Io,
window_id: mach.ObjectID = undefined,

/// Whether the overlay is shown (toggled by `handleKey`).
visible: bool = false,

/// Whether pipelines and objects have been created (app thread), see `setup`.
ready: bool = false,
bg_pipeline_id: mach.ObjectID = undefined,
text_pipeline_id: mach.ObjectID = undefined,
bg_sprite_id: mach.ObjectID = undefined,
text_id: mach.ObjectID = undefined,
style_normal: mach.ObjectID = undefined,
style_dim: mach.ObjectID = undefined,
style_warn: mach.ObjectID = undefined,

/// The 1x1 background texture, created by the render thread. Readable by the app thread once
/// `gpu_ready` is set.
bg_texture: *gpu.Texture = undefined,
gpu_ready: std.atomic.Value(bool) = .init(false),

refresh_timer: time.Timer,
refresh_now: bool = true,
/// Whether the `prev_` fields hold values from the previous refresh, so windows and rates are valid.
rates_valid: bool = false,
prev_allocs: [max_modules]u64 = @splat(0),
prev_frame_time: mach.Core.FrameTimeHistogram.Snapshot = .{},

/// A line of app-specific info, see `setAppInfo`.
app_info_buf: [max_line_len]u8 = undefined,
app_info: []const u8 = "",

lines: [max_lines][max_line_len]u8 = undefined,
line_lens: [max_lines]usize = @splat(0),
line_styles: [max_lines]mach.ObjectID = undefined,
num_lines: usize = 0,

/// State read by the render thread, written only in `snapshot`.
render_state: RenderState = .{},

const RenderState = struct {
    visible: bool = false,
    bg_pipeline_id: mach.ObjectID = undefined,
    text_pipeline_id: mach.ObjectID = undefined,
};

pub fn init(overlay: *DevOverlay, ctx: mach.Context) void {
    overlay.* = .{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .refresh_timer = time.Timer.start(ctx.io),
        .visible = if (std.c.getenv("MACH_DEV_OVERLAY")) |v| std.mem.eql(u8, std.mem.span(v), "1") else false,
    };
}

/// Sets the window the overlay is drawn on. Call before the first `update`.
pub fn attach(overlay: *DevOverlay, window_id: mach.ObjectID) void {
    overlay.window_id = window_id;
}

/// Handles the toggle chord. Returns true if `ev` was it, in which case the app should ignore it.
pub fn handleKey(overlay: *DevOverlay, ev: mach.Core.Event.Key) bool {
    if (ev.key != .d or !ev.mods.control or !ev.mods.alt or !ev.mods.shift) return false;
    overlay.visible = !overlay.visible;
    overlay.refresh_now = true;
    overlay.rates_valid = false;
    return true;
}

/// Sets a line of app-specific info shown in the overlay, e.g. the current scene.
pub fn setAppInfo(overlay: *DevOverlay, comptime fmt: []const u8, args: anytype) void {
    var w: std.Io.Writer = .fixed(&overlay.app_info_buf);
    w.print(fmt, args) catch {};
    overlay.app_info = w.buffered();
}

pub fn update(
    overlay: *DevOverlay,
    core: *mach.Core,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    ctx: mach.Context,
) !void {
    if (!overlay.ready) {
        if (!overlay.gpu_ready.load(.acquire)) return;
        try overlay.setup(sprite, text);
    }
    if (!overlay.visible) return;
    if (!overlay.refresh_now and overlay.refresh_timer.read() < refresh_seconds) return;
    const elapsed = overlay.refresh_timer.lap();
    overlay.refresh_now = false;

    overlay.num_lines = 0;
    overlay.addLine(overlay.style_dim, "dev overlay (ctrl+alt+shift+d)   tracy: {s}", .{
        if (!mach.tracy_enabled) "off (build with -Dtracy)" else if (mach.tracy.isConnected()) "connected" else "waiting for profiler",
    });
    if (metrics.enabled) {
        const frame_time = core.metrics.frame_time_ns.snapshot();
        const frames = if (overlay.rates_valid) frame_time.since(overlay.prev_frame_time) else frame_time;
        overlay.prev_frame_time = frame_time;
        overlay.addLine(overlay.style_normal, "frame {d:.0} fps   p50 <={d:.1} ms   p99 <={d:.1} ms   input {d} hz", .{
            if (frames.sum == 0) 0 else @as(f64, @floatFromInt(frames.count())) * time.ns_per_s / @as(f64, @floatFromInt(frames.sum)),
            nsToMs(frames.quantile(0.5) orelse 0),
            nsToMs(frames.quantile(0.99) orelse 0),
            core.input.rate,
        });
    } else {
        overlay.addLine(overlay.style_normal, "frame {d} fps   input {d} hz", .{ core.frame.rate, core.input.rate });
    }
    overlay.addLine(overlay.style_normal, "objects: {d} sprites, {d} texts", .{
        // Excluding the overlay's own.
        count(&sprite.objects) - 1, count(&text.objects) - 1,
    });
    if (overlay.app_info.len > 0) overlay.addLine(overlay.style_normal, "{s}", .{overlay.app_info});

    overlay.addLine(overlay.style_dim, "", .{});
    if (!metrics.enabled) {
        overlay.addLine(overlay.style_dim, "memory: off (build with -Dmetrics)", .{});
        try overlay.applyLines(core, sprite, text);
        return;
    }
    overlay.addLine(overlay.style_dim, "memory: used / peak / budget, touched, allocs/s -> suggested budget", .{});
    var stats_buf: [max_modules]mach.ModuleMemory = undefined;
    for (ctx.memoryStats(&stats_buf), 0..) |m, i| {
        const usage = m.usage;
        const allocs = usage.allocs_total.load();
        const allocs_per_sec: f64 = if (overlay.rates_valid and elapsed > 0)
            @as(f64, @floatFromInt(allocs -% overlay.prev_allocs[i])) / elapsed
        else
            0;
        overlay.prev_allocs[i] = allocs;

        const pool = m.pool orelse {
            overlay.addLine(overlay.style_normal, "{s}: {Bi:.1} / {Bi:.1} / no budget, {d:.0}/s", .{
                m.name,
                usage.used_bytes.loadUsize(),
                usage.peak_bytes.loadUsize(),
                allocs_per_sec,
            });
            continue;
        };

        // Warn when the peak gets close to the budget, or allocations have failed.
        const budget = pool.buffer.len;
        const peak = usage.peak_bytes.loadUsize();
        const failed = usage.failed_allocs_total.load();
        const peak_pct = if (budget == 0) 0 else peak * 100 / budget;
        const style = if (failed > 0 or peak_pct >= 90) overlay.style_warn else overlay.style_normal;
        overlay.addLine(style, "{s}: {Bi:.1} / {Bi:.1} / {Bi:.1} ({d}%), {Bi:.1}, {d:.0}/s -> {Bi:.0}{s}", .{
            m.name,
            usage.used_bytes.loadUsize(),
            peak,
            budget,
            peak_pct,
            pool.touched_bytes.loadUsize(),
            allocs_per_sec,
            suggestedBudget(peak),
            if (failed > 0) "  OUT OF MEMORY" else "",
        });
    }
    overlay.rates_valid = true;

    try overlay.applyLines(core, sprite, text);
}

/// Copies the state the render thread needs. Runs while the app thread holds the render snapshot
/// lock.
pub fn snapshot(overlay: *DevOverlay) void {
    overlay.render_state = .{
        .visible = overlay.visible and overlay.ready,
        .bg_pipeline_id = overlay.bg_pipeline_id,
        .text_pipeline_id = overlay.text_pipeline_id,
    };
}

/// Draws the overlay on top of `view`. Call from the window's render callback (on the render
/// thread) once the frame has been drawn, with no other gfx pipeline's `render_pass` set. Does
/// nothing for windows other than the attached one.
pub fn render(
    overlay: *DevOverlay,
    core: *mach.Core,
    encoder: *gpu.CommandEncoder,
    view: *gpu.TextureView,
    sprite: *gfx.Sprite,
    sprite_mod: mach.Mod(gfx.Sprite),
    text: *gfx.Text,
    text_mod: mach.Mod(gfx.Text),
) void {
    if (core.window != overlay.window_id) return;
    if (!overlay.gpu_ready.load(.acquire)) {
        overlay.createGpu(core.windows.getValue(core.window));
        return;
    }
    const rs = overlay.render_state;
    if (!rs.visible) return;

    const zone = mach.tracy.initZone(@src(), .{ .name = label ++ ".render" });
    defer zone.deinit();

    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = view,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .load,
        .store_op = .store,
    }};
    const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));
    defer pass.release();

    sprite.pipelines.setRaw(rs.bg_pipeline_id, .render_pass, pass);
    sprite_mod.call(.render);
    sprite.pipelines.setRaw(rs.bg_pipeline_id, .render_pass, null);

    text.pipelines.setRaw(rs.text_pipeline_id, .render_pass, pass);
    text_mod.call(.render);
    text.pipelines.setRaw(rs.text_pipeline_id, .render_pass, null);

    pass.end();
}

/// Creates the background texture. Called once on the render thread, where all GPU work happens.
fn createGpu(overlay: *DevOverlay, window: anytype) void {
    const device: *gpu.Device = window.device;
    const size = gpu.Extent3D{ .width = 1, .height = 1 };
    const texture = device.createTexture(&.{
        .label = label ++ " background",
        .size = size,
        .format = .rgba8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    const data_layout = gpu.Texture.DataLayout{ .bytes_per_row = 4, .rows_per_image = 1 };
    window.queue.writeTexture(&.{ .texture = texture }, &data_layout, &size, &bg_color);
    overlay.bg_texture = texture;
    overlay.gpu_ready.store(true, .release);
}

/// Creates the overlay's pipelines and objects, on the app thread once `gpu_ready` is set.
/// Created after the app's pipelines, so they draw on top within a pass.
fn setup(overlay: *DevOverlay, sprite: *gfx.Sprite, text: *gfx.Text) !void {
    overlay.bg_pipeline_id = try sprite.pipelines.new(.{
        .window = overlay.window_id,
        .texture = overlay.bg_texture,
    });
    overlay.text_pipeline_id = try text.pipelines.new(.{ .window = overlay.window_id });

    // The 1x1 texture is clamp-sampled, so the sprite is a solid translucent panel at any size.
    overlay.bg_sprite_id = try sprite.objects.new(.{
        .transform = Mat4x4.ident,
        .uv_transform = Mat3x3.ident,
        .size = vec2(1, 1),
    });
    try addToRenderList(sprite, overlay.allocator, overlay.bg_pipeline_id, overlay.bg_sprite_id);

    overlay.style_normal = try text.styles.new(.{ .font_size = style_font_size, .color = vec4(0.92, 0.92, 0.92, 1) });
    overlay.style_dim = try text.styles.new(.{ .font_size = style_font_size, .color = vec4(0.6, 0.62, 0.66, 1) });
    overlay.style_warn = try text.styles.new(.{ .font_size = style_font_size, .color = vec4(1, 0.45, 0.3, 1) });
    overlay.text_id = try text.createFmt(Mat4x4.ident, .{.{ overlay.style_normal, "", .{} }});
    try addToRenderList(text, overlay.allocator, overlay.text_pipeline_id, overlay.text_id);

    overlay.ready = true;
}

fn addLine(overlay: *DevOverlay, style: mach.ObjectID, comptime fmt: []const u8, args: anytype) void {
    if (overlay.num_lines == max_lines) return;
    const i = overlay.num_lines;
    var w: std.Io.Writer = .fixed(&overlay.lines[i]);
    w.print(fmt, args) catch {}; // truncated
    overlay.line_lens[i] = w.end;
    overlay.line_styles[i] = style;
    overlay.num_lines += 1;
}

/// A `Text.setFmt` spec printing one line, with `fmt` comptime as setFmt requires.
const LineSpec = struct { mach.ObjectID, comptime []const u8 = "{s}{s}", struct { []const u8, []const u8 } };

/// Updates the text, panel size and projection from `lines`.
fn applyLines(overlay: *DevOverlay, core: *mach.Core, sprite: *gfx.Sprite, text: *gfx.Text) !void {
    var specs: [max_lines]LineSpec = undefined;
    var max_len: usize = 0;
    for (&specs, 0..) |*spec, i| {
        const used = i < overlay.num_lines;
        const line = if (used) overlay.lines[i][0..overlay.line_lens[i]] else "";
        const newline = if (used and i + 1 < overlay.num_lines) "\n" else "";
        spec.* = .{ if (used) overlay.line_styles[i] else overlay.style_dim, "{s}{s}", .{ line, newline } };
        max_len = @max(max_len, line.len);
    }
    try text.setFmt(overlay.text_id, specs);

    const window_width: f32, const window_height: f32 = blk: {
        core.windows.lockShared();
        defer core.windows.unlockShared();
        break :blk .{
            @floatFromInt(core.windows.get(overlay.window_id, .width)),
            @floatFromInt(core.windows.get(overlay.window_id, .height)),
        };
    };
    // Window units, origin at the top-left, y up (so on-screen y is negative).
    const projection = Mat4x4.projection2D(.{
        .left = 0,
        .right = window_width,
        .bottom = -window_height,
        .top = 0,
        .near = -0.1,
        .far = 100,
    });
    sprite.pipelines.set(overlay.bg_pipeline_id, .view_projection, projection);
    text.pipelines.set(overlay.text_pipeline_id, .view_projection, projection);

    const num_lines: f32 = @floatFromInt(overlay.num_lines);
    const panel = vec2(
        @as(f32, @floatFromInt(max_len)) * font_size * glyph_advance + 2 * padding,
        num_lines * font_size + 2 * padding,
    );
    sprite.objects.set(overlay.bg_sprite_id, .size, panel);
    sprite.objects.set(overlay.bg_sprite_id, .transform, Mat4x4.translate(vec3(margin, -margin - panel.y(), 0)));
    // The text origin is the first line's baseline.
    text.objects.set(overlay.text_id, .transform, Mat4x4.translate(vec3(margin + padding, -margin - padding - font_size * 0.8, 0)));
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Peak usage plus 25% headroom, rounded up to a whole MiB.
fn suggestedBudget(high_water: usize) usize {
    const mib = 1024 * 1024;
    return std.mem.alignForward(usize, high_water + high_water / 4, mib);
}

fn count(objs: anytype) usize {
    var n: usize = 0;
    var it = objs.slice();
    while (it.next()) |_| n += 1;
    return n;
}

fn addToRenderList(module: anytype, allocator: std.mem.Allocator, pipeline_id: mach.ObjectID, object_id: mach.ObjectID) !void {
    var render_list = module.pipelines.get(pipeline_id, .render_list);
    try render_list.append(allocator, object_id);
    module.pipelines.set(pipeline_id, .render_list, render_list);
}
