const std = @import("std");
const zigimg = @import("zigimg");
const assets = @import("assets");
const mach = @import("mach");
const gfx = mach.gfx;
const gpu = mach.gpu;
const math = mach.math;

const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    mach.gfx.Text,
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
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ gfx.Text, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

app_thread: mach.Thread,
window: mach.ObjectID,
tick_timer: mach.time.Timer,
spawn_timer: mach.time.Timer,
rand: std.Random.DefaultPrng,

anim_time: f32 = 0,
direction: Vec2 = vec2(0, 0),
spawning: bool = false,
player_id: mach.ObjectID = undefined,
style1_id: mach.ObjectID = undefined,
pipeline_id: ?mach.ObjectID = null,

const upscale = 1.0;

const text1: []const []const u8 = &.{
    "Text but with spaces\n",
    "and\n",
    "newlines\n",
};

const text2: []const []const u8 = &.{"$!?"};

pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    core.on_exit = app_mod.id.deinit;

    const window = try core.windows.new(.{
        .title = "gfx.Text",
        .on_render = app_mod.id.render,
    });

    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .window = window,
        .tick_timer = mach.time.Timer.start(io),
        .spawn_timer = mach.time.Timer.start(io),
        .rand = std.Random.DefaultPrng.init(1337),
    };
}

fn setupPipeline(
    app: *App,
    text: *gfx.Text,
    core: *mach.Core,
) !void {
    // Create a text rendering pipeline
    app.pipeline_id = try text.pipelines.new(.{
        .window = core.window,
        .render_pass = undefined,
    });

    // Create a text style
    app.style1_id = try text.styles.new(.{
        .font_size = 48 * gfx.px_per_pt, // 48pt
    });

    // Create our player text.
    app.player_id = try text.createFmt(Mat4x4.translate(vec3(-0.02, 0, 0)), .{
        .{
            app.style1_id,
            " Text with spaces\n" ++
                " and newlines\n" ++
                " but nothing fancy (yet)",
            .{},
        },
    });
    // Register the text object with our text rendering pipeline.
    var texts = text.pipelines.get(app.pipeline_id.?, .render_list);
    try texts.append(allocator, app.player_id);
    text.pipelines.set(app.pipeline_id.?, .render_list, texts);
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ gfx.Text, .cleanup },
    .{ mach.Core, .snapshotStart },
    .{ gfx.Text, .snapshot },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(
    core: *mach.Core,
    app: *App,
    text: *gfx.Text,
    allocator: std.mem.Allocator,
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

    if (app.pipeline_id == null) return;
    const player_id = app.player_id;
    const pipeline_id = app.pipeline_id.?;
    var player = text.objects.getValue(player_id);
    var player_pos = player.transform.translation();
    if (spawning and app.spawn_timer.read() > 1.0 / 60.0) {
        // Spawn new entities
        _ = app.spawn_timer.lap();
        for (0..10) |_| {
            var new_pos = player_pos;
            new_pos.v[0] += app.rand.random().floatNorm(f32) * 50;
            new_pos.v[1] += app.rand.random().floatNorm(f32) * 50;

            const new_text_id = try text.createFmt(
                Mat4x4.scaleScalar(upscale).mul(&Mat4x4.translate(new_pos)),
                .{.{ app.style1_id, "?!", .{} }},
            );
            // Register the text object with our text rendering pipeline.
            var texts = text.pipelines.get(pipeline_id, .render_list);
            try texts.append(allocator, new_text_id);
            text.pipelines.set(pipeline_id, .render_list, texts);
        }
    }

    // Multiply by delta_time to ensure that movement is the same speed regardless of tick rate.
    const delta_time = app.tick_timer.lap();

    // Rotate all text objects in the pipeline.
    const pipeline_texts = text.pipelines.get(pipeline_id, .render_list);
    for (pipeline_texts.items) |text_id| {
        if (!text.objects.is(text_id)) continue;
        if (text_id == player_id) continue; // don't rotate the player
        var s = text.objects.getValue(text_id);

        const location = s.transform.translation();
        var transform = Mat4x4.ident;
        transform = transform.mul(&Mat4x4.translate(location));
        transform = transform.mul(&Mat4x4.rotateZ(2 * math.pi * app.anim_time));
        transform = transform.mul(&Mat4x4.scaleScalar(@min(math.cos(app.anim_time / 2.0), 0.5)));
        text.objects.set(text_id, .transform, transform);
    }

    // Calculate the player position, by moving in the direction the player wants to go
    // by the speed amount.
    const speed = 200.0;
    player_pos.v[0] += direction.x() * speed * delta_time;
    player_pos.v[1] += direction.y() * speed * delta_time;
    text.objects.set(player_id, .transform, Mat4x4.translate(player_pos));

    app.anim_time += delta_time;
}

pub fn render(
    core: *mach.Core,
    app: *App,
    text: *gfx.Text,
    text_mod: mach.Mod(gfx.Text),
) !void {
    if (app.pipeline_id == null) {
        try setupPipeline(app, text, core);
        return;
    }

    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(core.window);

    // Grab the back buffer of the swapchain
    // TODO(core): this wouldn't exist in browser
    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();

    // Create a command encoder
    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

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

    // Render text
    text.pipelines.set(app.pipeline_id.?, .render_pass, render_pass);
    text_mod.call(.render);

    // Finish render pass
    render_pass.end();
    var command = encoder.finish(&.{ .label = label });
    window.queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    render_pass.release();

    {
        core.windows.lock();
        defer core.windows.unlock();
        try core.fmtTitle(
            app.window,
            "text [ {d}fps ] [ Input {d}hz ]",
            .{ core.frame.rate, core.input.rate },
        );
    }
}

pub fn deinit(
    app: *App,
    text: *gfx.Text,
) void {
    app.app_thread.join();
    // Cleanup here, if desired.
    if (app.pipeline_id != null) text.objects.delete(app.player_id);
}
