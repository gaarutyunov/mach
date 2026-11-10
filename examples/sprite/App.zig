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
const Vec3 = math.Vec3;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    mach.gfx.Sprite,
    mach.dvx.Inspector,
    App,
});

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .appTick,
    .tick,
    .render,
    .setupGpu,
    .beginFrame,
    .endFrame,
    .deinit,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ gfx.Sprite, .init },
    .{ mach.dvx.Inspector, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

allocator: std.mem.Allocator,
window: mach.ObjectID,
tick_timer: mach.time.Timer,
spawn_timer: mach.time.Timer,
rand: std.Random.DefaultPrng,
app_thread: mach.Thread,

sprites: usize = 0,
anim_time: f32 = 0,
direction: Vec2 = vec2(0, 0),
spawning: bool = false,
player_id: mach.ObjectID = undefined,
pipeline_id: ?mach.ObjectID = null,
/// The sprite sheet, released on exit (the sprite pipeline holds its own reference to it).
texture: ?*gpu.Texture = null,
/// Set by the render thread once it loaded `texture`, see setupGpu.
gpu_ready: std.atomic.Value(bool) = .init(false),

pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
    io: std.Io,
    ctx: mach.Context,
) !void {
    const allocator = ctx.allocator;
    // You should use mach.Timer in general, but here we call std.Io.Timestamp.now() to show that
    // you can always get an 'io' parameter in any module function - it's automatically injected
    // for you.
    const timestamp = std.Io.Timestamp.now(io, .awake);
    std.debug.print("sprite: init at timestamp {d}ns\n", .{timestamp.nanoseconds});

    core.on_exit = app_mod.id.deinit;

    const window = try core.windows.new(.{
        .title = "gfx.Sprite",
        .on_render = app_mod.id.render,
    });

    app.* = .{
        .allocator = allocator,
        .window = window,
        .tick_timer = mach.time.Timer.start(io),
        .spawn_timer = mach.time.Timer.start(io),
        .rand = std.Random.DefaultPrng.init(1337),
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
    };
}

/// Loads our texture. Runs once on the render thread, where all GPU work happens; the app thread
/// creates the pipeline using it once `gpu_ready` is set (see setupPipeline).
pub fn setupGpu(core: *mach.Core, app: *App, ctx: mach.Context) !void {
    ctx.schedule.params(RenderParams).needs_setup = false;
    const window = core.windows.getValue(core.window);
    app.texture = try loadTexture(window.device, window.queue, app.allocator);
    app.gpu_ready.store(true, .release);
}

/// Creates our pipeline and sprites. Runs on the app thread, which owns them: the render thread
/// only reads their snapshot.
fn setupPipeline(app: *App, sprite: *gfx.Sprite) !void {
    // Create a sprite rendering pipeline
    app.pipeline_id = try sprite.pipelines.new(.{
        .window = app.window,
        .texture = app.texture.?,
    });

    // Create our player sprite
    app.player_id = try sprite.objects.new(.{
        .transform = Mat4x4.translate(vec3(-0.02, 0, 0)),
        .size = vec2(32, 32),
        .uv_transform = Mat3x3.translate(vec2(0, 0)),
    });
    // Register the sprite with our sprite rendering pipeline.
    var sprites = sprite.pipelines.get(app.pipeline_id.?, .render_list);
    try sprites.append(app.allocator, app.player_id);
    sprite.pipelines.set(app.pipeline_id.?, .render_list, sprites);
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.dvx.Inspector, .tick },
    .{ gfx.Sprite, .cleanup },
    .{ mach.Core, .snapshotStart },
    .{ gfx.Sprite, .snapshot },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(
    core: *mach.Core,
    app: *App,
    sprite: *gfx.Sprite,
) !void {
    const label = @tagName(mach_module) ++ ".tick";
    _ = label;

    var direction = app.direction;
    var spawning = app.spawning;
    var iter = core.events(.default);
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] -= 1,
                    .right => direction.v[0] += 1,
                    .up => direction.v[1] += 1,
                    .down => direction.v[1] -= 1,
                    .space => spawning = true,
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] += 1,
                    .right => direction.v[0] -= 1,
                    .up => direction.v[1] -= 1,
                    .down => direction.v[1] += 1,
                    .space => spawning = false,
                    else => {},
                }
            },
            .close => core.exit(),
            else => {},
        }
    }
    app.direction = direction;
    app.spawning = spawning;

    if (app.pipeline_id == null) {
        if (!app.gpu_ready.load(.acquire)) return;
        try setupPipeline(app, sprite);
    }
    const player_id = app.player_id;
    const pipeline_id = app.pipeline_id.?;
    var player = sprite.objects.getValue(player_id);
    var player_pos = player.transform.translation();
    if (spawning and app.spawn_timer.read() > 1.0 / 60.0) {
        // Spawn new entities
        _ = app.spawn_timer.lap();
        for (0..100) |_| {
            var new_pos = player_pos;
            new_pos.v[0] += app.rand.random().floatNorm(f32) * 25;
            new_pos.v[1] += app.rand.random().floatNorm(f32) * 25;

            const new_sprite_id = try sprite.objects.new(.{
                .transform = Mat4x4.translate(new_pos).mul(&Mat4x4.scale(Vec3.splat(0.3))),
                .size = vec2(32, 32),
                .uv_transform = Mat3x3.translate(vec2(0, 0)),
            });
            // Register the sprite with our sprite rendering pipeline.
            var sprites = sprite.pipelines.get(pipeline_id, .render_list);
            try sprites.append(app.allocator, new_sprite_id);
            sprite.pipelines.set(pipeline_id, .render_list, sprites);
            app.sprites += 1;
        }
    }

    // Multiply by delta_time to ensure that movement is the same speed regardless of tick rate.
    const delta_time = app.tick_timer.lap();

    // Rotate all sprites in the pipeline.
    const pipeline_sprites = sprite.pipelines.get(pipeline_id, .render_list);
    for (pipeline_sprites.items) |sprite_id| {
        if (!sprite.objects.is(sprite_id)) continue;
        if (sprite_id == player_id) continue; // don't rotate the player
        var s = sprite.objects.getValue(sprite_id);
        const location = s.transform.translation();
        var transform = Mat4x4.ident;
        transform = transform.mul(&Mat4x4.translate(location));
        transform = transform.mul(&Mat4x4.rotateZ(2 * math.pi * app.anim_time));
        transform = transform.mul(&Mat4x4.scaleScalar(@min(math.cos(app.anim_time / 2.0), 0.5)));
        sprite.objects.set(sprite_id, .transform, transform);
    }

    // Calculate the player position, by moving in the direction the player wants to go
    // by the speed amount.
    const speed = 200.0;
    player_pos.v[0] += direction.x() * speed * delta_time;
    player_pos.v[1] += direction.y() * speed * delta_time;
    sprite.objects.set(player_id, .transform, Mat4x4.translate(player_pos));

    app.anim_time += delta_time;
}

pub const RenderParams = struct {
    needs_setup: bool = true,
};

/// Runs on the render thread. Each system takes what it needs from the schedule's context, and
/// the finalizers of what was put there run when the schedule ends, if not removed before that.
pub const render = mach.scheduleWith(RenderParams, .{
    .{ App, .setupGpu, .needs_setup },
    .{ App, .beginFrame },
    .{ gfx.Sprite, .render },
    .{ App, .endFrame },
});

pub fn beginFrame(core: *mach.Core, ctx: mach.Context) void {
    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(core.window);

    // Grab the back buffer of the swapchain
    // TODO(core): this wouldn't exist in browser
    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return ctx.schedule.stop();
    ctx.schedule.put(.back_buffer, back_buffer_view, .{.release});

    // Create a command encoder
    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    ctx.schedule.put(.encoder, encoder, .{.release});

    // Begin render pass
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
    ctx.schedule.put(.render_pass, render_pass, .{ .end, .release });
}

pub fn endFrame(core: *mach.Core, app: *App, ctx: mach.Context) !void {
    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(core.window);

    // Finish render pass
    ctx.schedule.remove(.render_pass);
    const encoder = ctx.schedule.require(.encoder, *gpu.CommandEncoder);
    var command = encoder.finish(&.{ .label = label });
    window.queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();

    {
        core.windows.lock();
        defer core.windows.unlock();
        try core.fmtTitle(
            app.window,
            "sprite [ {d}fps ] [ Input {d}hz ] [ Sprites: {d} ]",
            .{ core.frame.rate, core.input.rate, app.sprites },
        );
    }
}

pub fn deinit(
    app: *App,
    sprite: *gfx.Sprite,
    sprite_mod: mach.Mod(gfx.Sprite),
    inspector_mod: mach.Mod(mach.dvx.Inspector),
) void {
    app.app_thread.join();
    if (app.pipeline_id != null) sprite.objects.delete(app.player_id);
    // Release GPU resources before mach.Core releases the device.
    sprite_mod.call(.deinit);
    if (app.texture) |t| t.release();
    inspector_mod.call(.deinit);
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
