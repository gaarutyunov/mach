const std = @import("std");
const zigimg = @import("zigimg");
const assets = @import("assets");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;

const vec2 = math.vec2;
const vec3 = math.vec3;
const Vec2 = math.Vec2;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    mach.gfx.Sprite,
    mach.gfx.Text,
    mach.Audio,
    App,
});

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .appTick,
    .tick,
    .render,
    .deinit,
    .deinit2,
    .audioStateChange,
};

pub const mach_tags = .{.window_meta};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ mach.Audio, .init },
    .{ gfx.Text, .init },
    .{ gfx.Sprite, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const deinit = mach.schedule(.{
    .{ mach.Audio, .deinit },
    .{ App, .deinit2 },
});

app_thread: mach.Thread,
allocator: std.mem.Allocator,
window_id: mach.ObjectID,
tick_timer: mach.time.Timer,
spawn_timer: mach.time.Timer,
rand: std.Random.DefaultPrng,

info_text_style_id: mach.ObjectID = undefined,
has_setup_shared: bool = false,
sprite_texture: *gpu.Texture = undefined,
sfx: mach.Audio.Opus = undefined,
next_window_num: usize = 2,

// Mouse capture demo state, updated from mouse_capture_* / mouse_motion_relative events.
mouse_capture_status: enum { released, captured, denied } = .released,
mouse_capture_dx_total: f64 = 0,
mouse_capture_dy_total: f64 = 0,

window_meta: mach.Objects(.{}, struct {
    window_id: mach.ObjectID,
    window_num: usize,
    sprite_pipeline_id: ?mach.ObjectID = null,
    text_pipeline_id: ?mach.ObjectID = null,
    info_text_id: ?mach.ObjectID = null,

    gotta_go_fast: bool = false,
    num_sprites_spawned: usize = 0,
}),

pub fn init(
    core: *mach.Core,
    audio: *mach.Audio,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
    io: std.Io,
    ctx: mach.Context,
) !void {
    const allocator = ctx.allocator;
    core.on_exit = app_mod.id.deinit;

    // Configure the audio module to call our App.audioStateChange function when a sound buffer
    // finishes playing.
    audio.on_state_change = app_mod.id.audioStateChange;

    const window = try core.windows.new(.{
        .title = "hardware check",
        .on_render = app_mod.id.render,
    });

    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .allocator = allocator,
        .window_id = window,
        .window_meta = app.window_meta,
        .tick_timer = mach.time.Timer.start(io),
        .spawn_timer = mach.time.Timer.start(io),
        .rand = std.Random.DefaultPrng.init(1337),
    };

    // Tag the main window with its metadata
    const main_window_meta = try app.window_meta.new(.{ .window_id = window, .window_num = 1 });
    try core.windows.setTag(window, App, .window_meta, main_window_meta);
}

pub fn deinit2(
    app: *App,
) void {
    app.app_thread.join();
}

/// Called on the high-priority audio OS thread when the audio driver needs more audio samples, so
/// this callback should be fast to respond.
pub fn audioStateChange(audio: *mach.Audio) !void {
    audio.buffers.lock();
    defer audio.buffers.unlock();

    // Find audio objects that are no longer playing
    var buffers = audio.buffers.slice();
    while (buffers.next()) |buf_id| {
        if (audio.buffers.get(buf_id, .playing)) continue;

        // Mark the audio buffer for deletion; Audio.cleanup will free it.
        audio.buffers.delete(buf_id);
    }
}

/// One-time initialization of shared resources used in all windows.
fn setupShared(
    core: *mach.Core,
    app: *App,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
) !void {
    const window = core.windows.getValue(core.window);

    // Load sfx
    app.sfx = try mach.Audio.Opus.decodeStream(app.allocator, .{ .data = assets.sfx.scifi_gun });

    // Load sprite texture
    app.sprite_texture = try loadTexture(window.device, window.queue, app.allocator);

    // Prepare text style
    app.info_text_style_id = try text.styles.new(.{
        .font_size = 48 * gfx.px_per_pt,
    });

    // Setup main window
    try app.setupWindow(core, sprite, text, core.window);
}

/// Set up per-window sprite pipeline, text pipeline, and info text.
fn setupWindow(app: *App, core: *mach.Core, sprite: *gfx.Sprite, text: *gfx.Text, window_id: mach.ObjectID) !void {
    const window_meta_id = core.windows.getTag(window_id, App, .window_meta) orelse return;
    if (app.window_meta.get(window_meta_id, .sprite_pipeline_id) != null) return;

    // Setup sprite pipeline
    const sprite_pipeline = try sprite.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
        .texture = app.sprite_texture,
    });
    app.window_meta.set(window_meta_id, .sprite_pipeline_id, sprite_pipeline);

    // Setup text pipeline
    const text_pipeline = try text.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
    });
    app.window_meta.set(window_meta_id, .text_pipeline_id, text_pipeline);

    // Create info text.
    const info_id = try text.createFmt(Mat4x4.translate(vec3(0, 0, 0)), .{
        .{ app.info_text_style_id, "[info]", .{} },
    });
    // Register the text object with our text rendering pipeline.
    var texts = text.pipelines.get(text_pipeline, .render_list);
    try texts.append(app.allocator, info_id);
    text.pipelines.set(text_pipeline, .render_list, texts);
    app.window_meta.set(window_meta_id, .info_text_id, info_id);
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.Audio, .cleanup },
    .{ gfx.Sprite, .cleanup },
    .{ gfx.Text, .cleanup },
    .{ mach.Core, .snapshotStart },
    .{ gfx.Sprite, .snapshot },
    .{ gfx.Text, .snapshot },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    audio: *mach.Audio,
) !void {
    var iter = core.events(.default);
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .space => {
                        // Space bar pressed: make sprites go faster
                        if (core.windows.getTag(ev.window_id, App, .window_meta)) |window_meta_id|
                            app.window_meta.set(window_meta_id, .gotta_go_fast, true);
                    },
                    .v => {
                        // V key: change vsync mode to next mode
                        const vsync = core.windows.get(ev.window_id, .vsync_mode);
                        const new_vsync: mach.Core.VSyncMode = switch (vsync) {
                            .double => .triple,
                            .triple => .low_latency,
                            .low_latency => .adaptive,
                            .adaptive => .none_low_latency,
                            .none_low_latency => .none_max_throughput,
                            .none_max_throughput => .double,
                        };
                        core.windows.set(ev.window_id, .vsync_mode, new_vsync);
                    },
                    .g => {
                        // G key: toggle mouse capture on the focused window. The platform may
                        // grant it instantly, deny it, or revoke it (e.g. on focus loss); which
                        // we observe via the mouse_capture_{gained,lost} events below
                        const want = !core.windows.get(ev.window_id, .mouse_capture);
                        core.windows.set(ev.window_id, .mouse_capture, want);
                        // Reset the accumulated delta whenever we start a new request.
                        app.mouse_capture_dx_total = 0;
                        app.mouse_capture_dy_total = 0;
                    },
                    .one => {
                        // 1 key: create a new window
                        var title_buf: [32]u8 = undefined;
                        const title = std.fmt.bufPrint(&title_buf, "Window {d}", .{app.next_window_num}) catch break;
                        const title_z = app.allocator.allocSentinel(u8, title.len, 0) catch break;
                        @memcpy(title_z, title);

                        const new_window = core.windows.new(.{
                            .title = title_z,
                            .on_render = app_mod.id.render,
                        }) catch break;

                        const meta = app.window_meta.new(.{
                            .window_id = new_window,
                            .window_num = app.next_window_num,
                        }) catch break;

                        core.windows.setTag(new_window, App, .window_meta, meta) catch break;
                        app.next_window_num += 1;
                    },
                    .two => {
                        // 2 key: delete the most recent window.

                        // Find the extra window with the highest window_num.
                        var highest_num: usize = 1;
                        var highest_meta: ?mach.ObjectID = null;
                        var metas = app.window_meta.slice();
                        while (metas.next()) |window_meta_id| {
                            const num = app.window_meta.get(window_meta_id, .window_num);
                            if (num > highest_num) {
                                highest_num = num;
                                highest_meta = window_meta_id;
                            }
                        }
                        if (highest_meta) |window_meta_id| {
                            // Null out pipeline render passes before deleting meta so
                            // the snapshot doesn't leave stale pointers for sprite/text render.
                            if (app.window_meta.get(window_meta_id, .sprite_pipeline_id)) |sprite_pipeline_id| {
                                sprite.pipelines.set(sprite_pipeline_id, .render_pass, null);
                            }
                            if (app.window_meta.get(window_meta_id, .text_pipeline_id)) |text_pipeline_id| {
                                text.pipelines.set(text_pipeline_id, .render_pass, null);
                            }
                            const window_id = app.window_meta.get(window_meta_id, .window_id);
                            core.windows.removeTag(window_id, App, .window_meta);
                            app.window_meta.free(window_meta_id);
                            core.windows.delete(window_id);
                        }
                    },
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .space => {
                        // Space bar released: slow down sprites
                        if (core.windows.getTag(ev.window_id, App, .window_meta)) |window_meta_id|
                            app.window_meta.set(window_meta_id, .gotta_go_fast, false);
                    },
                    else => {},
                }
            },

            .mouse_capture_gained => {
                app.mouse_capture_status = .captured;
            },
            .mouse_capture_lost => |ev| {
                app.mouse_capture_status = if (ev.denied) .denied else .released;
            },
            .mouse_motion_relative => |ev| {
                app.mouse_capture_dx_total += ev.dx;
                app.mouse_capture_dy_total += ev.dy;
            },

            .open => |ev| {
                // Window opened: set it up if not the main window.
                if (ev.window_id != app.window_id) {
                    app.setupWindow(core, sprite, text, ev.window_id) catch {};
                }
            },

            // Main window closed: exit the app
            // TODO: vet mach.Core events to ensure all send a window ID, and handle this here.
            .close => core.exit(),
            else => {},
        }
    }

    const delta_time = app.tick_timer.lap();
    if (!app.has_setup_shared) return;

    // Update per-window info text.
    var window_count: usize = 0;
    {
        var metas = app.window_meta.slice();
        while (metas.next()) |window_meta_id| {
            window_count += 1;
            const info_id = app.window_meta.get(window_meta_id, .info_text_id) orelse continue;
            const window_id = app.window_meta.get(window_meta_id, .window_id);
            const window_num = app.window_meta.get(window_meta_id, .window_num);
            const vsync_mode = core.windows.get(window_id, .vsync_mode);
            const num_spawned = app.window_meta.get(window_meta_id, .num_sprites_spawned);

            try text.setFmt(info_id, .{
                .{
                    app.info_text_style_id,
                    "Window {d}\n" ++
                        "[ render: {d}hz | input: {d}hz ]\n" ++
                        "[ Sprites: {d} | Windows: {d} ]\n" ++
                        "(v) sync: {s}\n" ++
                        "(g) mouse capture: {s} (dx={d} dy={d})\n" ++
                        "(1) new window\n" ++
                        "(2) close window",
                    .{
                        window_num,
                        core.frame.rate,
                        core.input.rate,
                        num_spawned,
                        window_count,
                        @tagName(vsync_mode),
                        @tagName(app.mouse_capture_status),
                        // TODO(text): text.setFmt hashes args for memoization and cannot hash f64; round to i64.
                        @as(i64, @intFromFloat(app.mouse_capture_dx_total)),
                        @as(i64, @intFromFloat(app.mouse_capture_dy_total)),
                    },
                },
            });

            {
                core.windows.lock();
                defer core.windows.unlock();
                try core.fmtTitle(
                    window_id,
                    "hardware-check window {d} [ {d}fps ] [ Input {d}hz ] [ Sprites: {d} ]",
                    .{ window_num, core.frame.rate, core.input.rate, num_spawned },
                );
            }
        }
    }

    // Spawn and animate sprites per-window.
    {
        var metas = app.window_meta.slice();
        while (metas.next()) |window_meta_id| {
            const sprite_pipeline_id = app.window_meta.get(window_meta_id, .sprite_pipeline_id) orelse continue;
            const window_id = app.window_meta.get(window_meta_id, .window_id);
            const window = core.windows.getValue(window_id);
            const fast = app.window_meta.get(window_meta_id, .gotta_go_fast);

            // Spawn
            const entities_per_second: f32 = @floatFromInt(
                app.rand.random().intRangeAtMost(usize, 0, if (fast) 50 else 10),
            );
            if (app.spawn_timer.read() > 1.0 / entities_per_second) {
                _ = app.spawn_timer.lap();
                var new_pos = vec3(-(@as(f32, @floatFromInt(window.width)) / 2), 0, 0);
                new_pos.v[1] += app.rand.random().floatNorm(f32) * 50;

                const new_sprite_id = try sprite.objects.new(.{
                    .transform = Mat4x4.translate(new_pos),
                    .size = vec2(32, 32),
                    .uv_transform = Mat3x3.translate(vec2(0, 0)),
                });
                // Register the sprite with our sprite rendering pipeline.
                var sprites = sprite.pipelines.get(sprite_pipeline_id, .render_list);
                try sprites.append(app.allocator, new_sprite_id);
                sprite.pipelines.set(sprite_pipeline_id, .render_list, sprites);
                app.window_meta.set(window_meta_id, .num_sprites_spawned, app.window_meta.get(window_meta_id, .num_sprites_spawned) + 1);
            }

            // Animate
            const pipeline_sprites = sprite.pipelines.get(sprite_pipeline_id, .render_list);
            for (pipeline_sprites.items) |sprite_id| {
                if (!sprite.objects.is(sprite_id)) continue;

                const location = sprite.objects.getValue(sprite_id).transform.translation();
                const speed: f32 = if (fast) 2000 else 100;
                const progression = std.math.clamp((location.v[0] + (@as(f32, @floatFromInt(window.height)) / 2.0)) / @as(f32, @floatFromInt(window.height)), 0, 1);
                const scale = mach.math.lerp(2, 0, progression);
                if (progression >= 0.6) {
                    sprite.objects.delete(sprite_id);

                    // Play a sound effect when a sprite disappears.
                    const samples = try audio.allocSamples(app.sfx.samples.len);
                    @memcpy(samples, app.sfx.samples);
                    audio.buffers.lock();
                    defer audio.buffers.unlock();
                    _ = try audio.buffers.new(.{
                        .samples = samples,
                        .channels = app.sfx.channels,
                    });
                } else {
                    var transform = Mat4x4.ident;
                    transform = transform.mul(&Mat4x4.translate(location.add(&vec3(speed * delta_time, (speed / 2.0) * delta_time * progression, 0))));
                    transform = transform.mul(&Mat4x4.scaleScalar(scale));
                    sprite.objects.set(sprite_id, .transform, transform);
                }
            }
        }
    }
}

pub fn render(
    core: *mach.Core,
    app: *App,
    sprite: *gfx.Sprite,
    sprite_mod: mach.Mod(gfx.Sprite),
    text: *gfx.Text,
    text_mod: mach.Mod(gfx.Text),
) !void {
    if (!app.has_setup_shared) {
        try setupShared(core, app, sprite, text);
        app.has_setup_shared = true;
        return;
    }

    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(core.window);

    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();

    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    const sky_blue = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = sky_blue,
        .load_op = .clear,
        .store_op = .store,
    }};
    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));

    // TODO: clean this up ASAP
    // Null out all pipelines, then activate only the current window's.
    {
        var metas = app.window_meta.slice();
        while (metas.next()) |window_meta_id| {
            if (app.window_meta.get(window_meta_id, .sprite_pipeline_id)) |sprite_pipeline_id| {
                sprite.pipelines.set(sprite_pipeline_id, .render_pass, null);
            }
            if (app.window_meta.get(window_meta_id, .text_pipeline_id)) |text_pipeline_id| {
                text.pipelines.set(text_pipeline_id, .render_pass, null);
            }
        }
    }
    if (core.windows.getTag(core.window, App, .window_meta)) |window_meta_id| {
        if (app.window_meta.get(window_meta_id, .sprite_pipeline_id)) |sprite_pipeline_id| {
            sprite.pipelines.set(sprite_pipeline_id, .render_pass, render_pass);
        }
        if (app.window_meta.get(window_meta_id, .text_pipeline_id)) |text_pipeline_id| {
            text.pipelines.set(text_pipeline_id, .render_pass, render_pass);
        }
    }

    // Render
    sprite_mod.call(.render);
    text_mod.call(.render);

    render_pass.end();
    var command = encoder.finish(&.{ .label = label });
    window.queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    render_pass.release();
}

// TODO(sprite): don't require users to copy / write this helper themselves
fn loadTexture(device: *gpu.Device, queue: *gpu.Queue, allocator: std.mem.Allocator) !*gpu.Texture {
    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, assets.sprites_sheet_png);
    defer img.deinit(allocator);
    const img_size = gpu.Extent3D{ .width = @as(u32, @intCast(img.width)), .height = @as(u32, @intCast(img.height)) };

    // Create a GPU texture
    const label = @tagName(mach_module) ++ ".loadTexture";
    const texture = device.createTexture(&.{
        .label = label,
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
        },
    });
    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @as(u32, @intCast(img.width * 4)),
        .rows_per_image = @as(u32, @intCast(img.height)),
    };
    switch (img.pixels) {
        .rgba32 => |pixels| queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, pixels),
        .rgb24 => |pixels| {
            const data = try rgb24ToRgba32(allocator, pixels);
            defer data.deinit(allocator);
            queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, data.rgba32);
        },
        else => @panic("unsupported image color format"),
    }
    return texture;
}

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        out.rgba32[i] = zigimg.color.Rgba32{ .r = in[i].r, .g = in[i].g, .b = in[i].b, .a = 255 };
    }
    return out;
}
