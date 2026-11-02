/// Loads and plays opus sound files.
///
/// Plays a long background music sound file that plays on repeat, and a short sound effect that
/// plays when pressing keys.
const std = @import("std");
const builtin = @import("builtin");

const mach = @import("mach");
const assets = @import("assets");
const gpu = mach.gpu;
const math = mach.math;
const sysaudio = mach.sysaudio;

pub const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    mach.Audio,
    App,
});

pub const mach_module = .app;

pub const mach_tags = .{
    // A tag we'll attach to mach.Audio buffers to indicate they are background music
    .bgm,
};

pub const mach_systems = .{
    .main,
    .init,
    .appTick,
    .tick,
    .render,
    .deinit,
    .deinitApp,
    .audioStateChange,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ mach.Audio, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const deinit = mach.schedule(.{
    .{ App, .deinitApp },
    .{ mach.Audio, .deinit },
});

app_thread: mach.Thread,
window: mach.ObjectID,

sfx: mach.Audio.Opus,

pub fn init(
    core: *mach.Core,
    core_mod: mach.Mod(mach.Core),
    audio: *mach.Audio,
    app: *App,
    app_mod: mach.Mod(App),
    allocator: std.mem.Allocator,
) !void {
    core.on_exit = app_mod.id.deinit;

    const window = try core.windows.new(.{
        .title = "play-opus",
        .on_render = app_mod.id.render,
    });

    // Configure the audio module to call our App.audioStateChange function when a sound buffer
    // finishes playing.
    audio.on_state_change = app_mod.id.audioStateChange;

    const bgm = try mach.Audio.Opus.decodeStream(allocator, .{ .data = assets.bgm.bit_bit_loop });
    defer allocator.free(bgm.samples);

    const sfx = try mach.Audio.Opus.decodeStream(allocator, .{ .data = assets.sfx.sword1 });

    // Initialize module state
    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .window = window,
        .sfx = sfx,
    };

    {
        audio.buffers.lock();
        defer audio.buffers.unlock();

        // Audio.cleanup will free this samples buffer when the bgm buffer is deleted, so we must
        // allocate it with audio.allocSamples and copy into it (rather than passing the
        // user-owned bgm.samples directly).
        const bgm_samples = try audio.allocSamples(bgm.samples.len);
        @memcpy(bgm_samples, bgm.samples);

        const bgm_buffer = try audio.buffers.new(.{
            .samples = bgm_samples,
            .channels = bgm.channels,
        });
        // Tag the buffer as background music
        try audio.buffers.setTag(bgm_buffer, App, .bgm, null);
    }

    std.debug.print("controls:\n", .{});
    std.debug.print("[typing]     Play SFX\n", .{});
    std.debug.print("[arrow up]   increase volume 10%\n", .{});
    std.debug.print("[arrow down] decrease volume 10%\n", .{});
}

pub fn deinitApp(app: *App, allocator: std.mem.Allocator) void {
    app.app_thread.join();
    allocator.free(app.sfx.samples);
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

        if (audio.buffers.hasTag(buf_id, App, .bgm)) {
            // Repeat background music forever
            audio.buffers.set(buf_id, .index, 0);
            audio.buffers.set(buf_id, .playing, true);
        } else audio.buffers.delete(buf_id);
    }
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.Audio, .cleanup },
    .{ mach.Core, .snapshotStart },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(
    core: *mach.Core,
    audio: *mach.Audio,
    app: *App,
) !void {
    var iter = core.events(.default);
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| switch (ev.key) {
                .down => {
                    const vol = math.clamp(try audio.player.volume() - 0.1, 0, 1);
                    try audio.player.setVolume(vol);
                    std.debug.print("[volume] {d:.0}%\n", .{vol * 100.0});
                },
                .up => {
                    const vol = math.clamp(try audio.player.volume() + 0.1, 0, 1);
                    try audio.player.setVolume(vol);
                    std.debug.print("[volume] {d:.0}%\n", .{vol * 100.0});
                },
                else => {
                    // Play a new SFX. Audio.cleanup will free the samples buffer when this audio
                    // buffer is deleted, so we allocate a fresh copy here rather than reusing
                    // app.sfx.samples (which is owned by App).
                    const samples = try audio.allocSamples(app.sfx.samples.len);
                    @memcpy(samples, app.sfx.samples);

                    audio.buffers.lock();
                    defer audio.buffers.unlock();

                    _ = try audio.buffers.new(.{
                        .samples = samples,
                        .channels = app.sfx.channels,

                        // Start 0.15s into the sfx, which removes the silence at the start of the
                        // audio clip and makes it more apparent the low latency between pressing a
                        // key and sfx actually playing.
                        .index = @intFromFloat(@as(f32, @floatFromInt(audio.player.sampleRate() * app.sfx.channels)) * 0.15),
                    });
                },
            },
            .close => core.exit(),
            else => {},
        }
    }

    {
        core.windows.lock();
        defer core.windows.unlock();
        try core.fmtTitle(app.window, "play-opus [ {d}fps ] [ Input {d}hz ]", .{
            core.frame.rate, core.input.rate,
        });
    }
}

pub fn render(
    core: *mach.Core,
) !void {
    const label = @tagName(mach_module) ++ ".render";
    var window = core.windows.getValue(core.window);

    // Grab the back buffer of the swapchain
    // TODO(core): this wouldn't exist in browser
    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();

    // Create a command encoder
    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    // Begin render pass
    const sky_blue_background = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = sky_blue_background,
        .load_op = .clear,
        .store_op = .store,
    }};
    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));
    defer render_pass.release();

    // Draw nothing

    // Finish render pass
    render_pass.end();

    // Submit our commands to the queue
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});
}
