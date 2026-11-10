//! Mach inspector: interactive graphs of a running Mach program, streamed live by
//! `mach.dvx.Inspector` (the tool connects to it like Tracy's viewer), or from a saved capture.
//! Built with Mach itself (gfx.Sprite, gfx.Text). Not part of the runtime: a separate tool, see
//! `zig build inspector`.
//!
//! Views (keys 1-6):
//! 1. Systems: schedules, systems, the modules they access or call, and the schedule values
//!    flowing between them (who puts and who reads `ctx.schedule` values).
//! 2. Objects: modules' `mach.Objects` lists, their objects, relations between objects (IDs in
//!    fields, parent/child) and the GPU objects they hold (CPU -> GPU).
//! 3. GPU: GPU objects and how they refer to each other: textures -> views -> bind groups ->
//!    pipelines, bind group layouts -> pipeline layouts -> pipelines, shaders -> pipelines,
//!    and which bind groups pipelines are drawn with. Problems found by the tracker are red.
//! 4. Lifetimes: when each GPU object was created and released (frames), and the code creating
//!    GPU objects with how many it created, released, and are still alive.
//! 5. Threads: which systems run on which thread, the `mach.Objects` lists they access with the
//!    locks held, and likely races.
//! 6. Timeline: what each thread ran in the last 50 ms.
//!
//! Mouse: drag the background to pan, scroll or pinch to zoom, click a node to see its details
//! and highlight its connections, drag a node to move it, click a schedule's bool params to
//! toggle them in the running app. Keys: G layout, C coloring, F fit, R request a snapshot,
//! W save a capture, S export SVG, H show released GPU objects, P problems, L relayout,
//! Esc deselect, arrows pan, +/- zoom. See README.md.
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;
const Model = @import("Model.zig");
const Force = @import("Force.zig");
const Live = @import("Live.zig");
const protocol = mach.dvx.inspector_protocol;

const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const App = @This();

pub const Modules = mach.Modules(.{
    mach.Core,
    gfx.Sprite,
    gfx.Text,
    App,
});

pub const mach_module = .app;

pub const mach_systems = .{ .main, .init, .tick, .appTick, .render, .beginFrame, .beginUiPass, .endFrame, .deinit };

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ gfx.Sprite, .init },
    .{ gfx.Text, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ gfx.Sprite, .cleanup },
    .{ gfx.Text, .cleanup },
    .{ mach.Core, .snapshotStart },
    .{ gfx.Sprite, .snapshot },
    .{ gfx.Text, .snapshot },
    .{ mach.Core, .snapshotEnd },
});

/// The graph is drawn in a first pass, panels on top of it in a second.
pub const render = mach.schedule(.{
    .{ App, .beginFrame },
    .{ gfx.Sprite, .render },
    .{ gfx.Text, .render },
    .{ App, .beginUiPass },
    .{ gfx.Sprite, .render },
    .{ gfx.Text, .render },
    .{ App, .endFrame },
});

const ui_group: gfx.RenderGroup = @fromBackingInt(1);

/// The palette texture has one 4x4 block per color, sprites sample the middle of their block.
const palette_block = 4;
const palette = blk: {
    var colors: [@typeInfo(Model.Color).@"enum".field_names.len][4]u8 = undefined;
    for (&colors, 0..) |*c, i| c.* = switch (@as(Model.Color, @fromBackingInt(@intCast(i)))) {
        .white => .{ 235, 237, 242, 255 },
        .panel => .{ 22, 24, 31, 238 },
        .border => .{ 84, 90, 108, 255 },
        .edge => .{ 112, 120, 142, 255 },
        .edge_hi => .{ 255, 205, 90, 255 },
        .select => .{ 255, 205, 90, 255 },
        .problem => .{ 232, 72, 64, 255 },
        .dim => .{ 38, 41, 50, 255 },
        .module => .{ 52, 98, 170, 255 },
        .system => .{ 44, 120, 86, 255 },
        .schedule => .{ 118, 76, 160, 255 },
        .value => .{ 160, 112, 40, 255 },
        .list => .{ 36, 116, 132, 255 },
        .object => .{ 66, 78, 100, 255 },
        .shader => .{ 150, 64, 124, 255 },
        .pipeline => .{ 176, 88, 44, 255 },
        .layout => .{ 92, 92, 150, 255 },
        .bind_group => .{ 40, 132, 140, 255 },
        .buffer => .{ 66, 120, 66, 255 },
        .texture => .{ 150, 128, 44, 255 },
        .sampler => .{ 110, 92, 72, 255 },
        .gpu_other => .{ 80, 86, 98, 255 },
        .released => .{ 48, 50, 58, 255 },
        .bar => .{ 70, 150, 104, 255 },
        .edge_dim => .{ 44, 47, 56, 255 },
        .grid => .{ 30, 33, 42, 255 },
        .pass => .{ 120, 60, 60, 255 },
        .warn => .{ 220, 150, 50, 255 },
        // Distinct hues for connected components.
        .comp0 => .{ 46, 110, 190, 255 },
        .comp1 => .{ 196, 92, 40, 255 },
        .comp2 => .{ 52, 140, 74, 255 },
        .comp3 => .{ 150, 60, 160, 255 },
        .comp4 => .{ 170, 140, 30, 255 },
        .comp5 => .{ 30, 140, 150, 255 },
        .comp6 => .{ 180, 60, 90, 255 },
        .comp7 => .{ 100, 110, 30, 255 },
        .comp8 => .{ 90, 80, 180, 255 },
        .comp9 => .{ 140, 90, 50, 255 },
        .comp10 => .{ 60, 120, 120, 255 },
        .comp11 => .{ 130, 130, 140, 255 },
        .comp_single => .{ 56, 60, 70, 255 },
        .comp_hub => .{ 200, 200, 210, 255 },
    };
    break :blk colors;
};
const palette_width = palette.len * palette_block;
const clear_color = gpu.Color{ .r = 0.055, .g = 0.06, .b = 0.075, .a = 1 };

const TextStyle = enum { normal, dim, title, problem, accent };

const NodeSprites = struct {
    fill: mach.ObjectID,
    border: mach.ObjectID,
    text: mach.ObjectID,
};

const EdgeSprites = struct {
    line: mach.ObjectID,
    head: mach.ObjectID,
};

const Drag = union(enum) {
    none,
    pan,
    node: u32,
};

const max_panel_lines = 56;
const max_line_len = 160;

allocator: std.mem.Allocator,
io: std.Io,
window: mach.ObjectID,
app_thread: mach.Thread,

// `--screenshot path.ppm` (testing aid): render one frame offscreen, save it, and exit.
screenshot_path: ?[]const u8 = null,
shot_timer: ?mach.time.Timer = null,
shot_texture: ?*gpu.Texture = null,
screenshot_done: std.atomic.Value(bool) = .init(false),
/// Set by the app thread once a snapshot's scene is built.
scene_ready: std.atomic.Value(bool) = .init(false),

// GPU resources, created by the render thread.
palette_texture: *gpu.Texture = undefined,
gpu_ready: std.atomic.Value(bool) = .init(false),

// Created by the app thread once `gpu_ready` is set.
ready: bool = false,
world_sprites: mach.ObjectID = undefined,
world_text: mach.ObjectID = undefined,
ui_sprites: mach.ObjectID = undefined,
ui_text: mach.ObjectID = undefined,
styles: [@typeInfo(TextStyle).@"enum".field_names.len]mach.ObjectID = undefined,

// The snapshot file.
/// A capture file to show, or null to connect live to a running app.
path: ?[]const u8,
mtime: i96 = 0,
live: Live,
/// The raw JSON of the current snapshot, for saving captures.
snapshot_json: ?[]u8 = null,
reload_timer: mach.time.Timer,
snapshot_arena: std.heap.ArenaAllocator,
snapshot: ?Model.Snapshot = null,
status: []const u8 = "waiting for snapshot",
status_buf: [256]u8 = undefined,

// The current view.
view: Model.View = .gpu,
options: Model.Options = .{},
graph_arena: std.heap.ArenaAllocator,
graph: Model.Graph = .{},
/// Positions of nodes the user moved, by node key, kept across reloads.
moved: std.AutoHashMapUnmanaged(u64, [2]f32) = .empty,
selected: ?u32 = null,
show_problems: bool = true,
needs_fit: bool = true,
/// How graph views are laid out: a force simulation on the GPU (`G` toggles), or columns.
layout_mode: enum { gravity, columns } = .gravity,
/// How nodes are colored (`C` cycles).
color_mode: enum { kind, component } = .kind,
/// Connected components of the current graph, for the legend in `.component` color mode.
components: []const Model.Component = &.{},
force: Force,
/// Fit the view once the force simulation settles.
fit_on_settle: bool = false,
/// Node positions of the previous scene, by key, to keep them when a new snapshot arrives.
prev_positions: std.AutoHashMapUnmanaged(u64, [2]f32) = .empty,
/// The zoom edges were last sized for.
edges_zoom: f32 = 0,

// Camera: the world position at the window's center, and pixels per world unit.
cam_x: f32 = 0,
cam_y: f32 = 0,
zoom: f32 = 1,
win_w: f32 = 1280,
win_h: f32 = 800,

// Input.
mouse_x: f32 = 0,
mouse_y: f32 = 0,
drag: Drag = .none,
press_x: f32 = 0,
press_y: f32 = 0,
drag_moved: bool = false,

// Scene objects.
node_sprites: std.ArrayList(NodeSprites) = .empty,
edge_sprites: std.ArrayList(EdgeSprites) = .empty,
ui_objects: std.ArrayList(mach.ObjectID) = .empty,
ui_texts: std.ArrayList(mach.ObjectID) = .empty,
/// The problem shown on each line of the problems panel, for clicks.
problem_lines: std.ArrayList(u32) = .empty,
problems_panel: [4]f32 = .{ 0, 0, 0, 0 },
/// Clickable lines of the details panel: toggles of the selected schedule's bool params.
toggle_lines: std.ArrayList(struct { y: f32, toggle: Model.Toggle }) = .empty,
/// Other panels (x, y, w, h in window units, y down), which swallow clicks.
panels: std.ArrayList([4]f32) = .empty,

pub fn init(core: *mach.Core, app: *App, app_mod: mach.Mod(App), core_mod: mach.Mod(mach.Core), ctx: mach.Context) !void {
    core.on_exit = app_mod.id.deinit;
    const window = try core.windows.new(.{
        .title = "Mach inspector",
        .on_render = app_mod.id.render,
        .width = 1440,
        .height = 900,
    });
    // Arguments: an optional capture file to open (else connect live to a running app), and
    // testing aids: `--view <name>` and `--screenshot <out.ppm>` (render once, save, exit).
    var path: ?[]const u8 = null;
    var view: Model.View = .gpu;
    var screenshot: ?[]const u8 = null;
    if (mach.process_args) |args| {
        var it = try args.iterateAllocator(ctx.allocator);
        defer it.deinit();
        _ = it.skip();
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--view")) {
                if (it.next()) |v| view = std.meta.stringToEnum(Model.View, v) orelse view;
            } else if (std.mem.eql(u8, arg, "--screenshot")) {
                if (it.next()) |v| screenshot = try ctx.allocator.dupe(u8, v);
            } else path = try ctx.allocator.dupe(u8, arg);
        }
    }
    app.* = .{
        .screenshot_path = screenshot,
        .view = view,
        .allocator = ctx.allocator,
        .io = ctx.io,
        .window = window,
        .path = path,
        .live = Live.init(ctx.allocator, ctx.io),
        .reload_timer = mach.time.Timer.start(ctx.io),
        .force = Force.init(ctx.allocator, ctx.io),
        .snapshot_arena = .init(ctx.allocator),
        .graph_arena = .init(ctx.allocator),
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
    };
    if (path == null) try app.live.start();
}

pub fn deinit(app: *App, sprite_mod: mach.Mod(gfx.Sprite), text_mod: mach.Mod(gfx.Text)) void {
    app.app_thread.join();
    app.live.deinit();
    app.prev_positions.deinit(app.allocator);
    app.toggle_lines.deinit(app.allocator);
    // On the render thread, which owns the simulation's GPU resources.
    app.force.releaseGpu();
    app.force.deinit();
    sprite_mod.call(.deinit);
    text_mod.call(.deinit);
    // The sprite pipelines hold their own reference to it.
    if (app.gpu_ready.load(.acquire)) app.palette_texture.release();
}

// ---------------------------------------------------------------------------------------------
// App thread

pub fn appTick(core: *mach.Core, app: *App, sprite: *gfx.Sprite, text: *gfx.Text) !void {
    var dirty_scene = false;
    var dirty_ui = false;
    var dirty_camera = false;

    {
        core.windows.lockShared();
        defer core.windows.unlockShared();
        const w: f32 = @floatFromInt(core.windows.get(app.window, .width));
        const h: f32 = @floatFromInt(core.windows.get(app.window, .height));
        if (w != app.win_w or h != app.win_h) {
            app.win_w = w;
            app.win_h = h;
            dirty_ui = true;
            dirty_camera = true;
        }
    }

    if (app.screenshot_done.load(.acquire)) core.exit();
    var iter = core.events(.default);
    while (iter.next()) |event| switch (event) {
        .close => core.exit(),
        .key_press, .key_repeat => |ev| {
            const pan_step = 120 / app.zoom;
            switch (ev.key) {
                .one => app.setView(.systems, &dirty_scene),
                .two => app.setView(.objects, &dirty_scene),
                .three => app.setView(.gpu, &dirty_scene),
                .four => app.setView(.lifetimes, &dirty_scene),
                .five => app.setView(.threads, &dirty_scene),
                .six => app.setView(.timeline, &dirty_scene),
                .f => {
                    app.fit();
                    dirty_camera = true;
                },
                .r => {
                    app.mtime = 0;
                    if (app.path == null) app.live.send(.{ .cmd = "snapshot" });
                },
                .w => app.saveCapture(),
                .s => app.exportSvg(app.view, "mach-inspect"),
                .h => {
                    app.options.show_released = !app.options.show_released;
                    dirty_scene = true;
                },
                .p => {
                    app.show_problems = !app.show_problems;
                    dirty_ui = true;
                },
                .g => {
                    app.layout_mode = if (app.layout_mode == .gravity) .columns else .gravity;
                    app.needs_fit = true;
                    dirty_scene = true;
                },
                .k => {
                    app.options.show_copies = !app.options.show_copies;
                    dirty_scene = true;
                },
                .c => {
                    app.color_mode = if (app.color_mode == .kind) .component else .kind;
                    dirty_scene = true;
                },
                .l => {
                    app.moved.clearRetainingCapacity();
                    app.needs_fit = true;
                    dirty_scene = true;
                },
                .escape => {
                    app.selected = null;
                    dirty_scene = true;
                },
                .left => app.cam_x -= pan_step,
                .right => app.cam_x += pan_step,
                .up => app.cam_y += pan_step,
                .down => app.cam_y -= pan_step,
                .equal, .kp_add => app.zoomAt(app.win_w / 2, app.win_h / 2, 1.25),
                .minus, .kp_subtract => app.zoomAt(app.win_w / 2, app.win_h / 2, 0.8),
                else => {},
            }
            dirty_camera = true;
        },
        .mouse_motion => |ev| {
            const x: f32 = @floatCast(ev.pos.x);
            const y: f32 = @floatCast(ev.pos.y);
            const dx = x - app.mouse_x;
            const dy = y - app.mouse_y;
            app.mouse_x = x;
            app.mouse_y = y;
            if (@abs(x - app.press_x) + @abs(y - app.press_y) > 3) app.drag_moved = true;
            switch (app.drag) {
                .none => {},
                .pan => {
                    app.cam_x -= dx / app.zoom;
                    app.cam_y += dy / app.zoom;
                    dirty_camera = true;
                },
                .node => |i| if (app.drag_moved) {
                    const n = &app.graph.nodes.items[i];
                    n.x += dx / app.zoom;
                    n.y -= dy / app.zoom;
                    try app.moved.put(app.allocator, n.key, .{ n.x, n.y });
                    if (app.simulating()) app.force.pin(i, .{ n.x + n.w / 2, n.y + n.h / 2 }, true);
                    try app.placeNode(sprite, text, i);
                },
            }
        },
        .mouse_press => |ev| {
            app.mouse_x = @floatCast(ev.pos.x);
            app.mouse_y = @floatCast(ev.pos.y);
            app.press_x = app.mouse_x;
            app.press_y = app.mouse_y;
            app.drag_moved = false;
            if (ev.button != .left) continue;
            if (app.clickUi(&dirty_scene, &dirty_camera)) continue;
            const wx, const wy = app.toWorld(app.mouse_x, app.mouse_y);
            app.drag = if (app.graph.hit(wx, wy)) |i| .{ .node = i } else .pan;
        },
        .mouse_release => |ev| {
            if (ev.button != .left) continue;
            // Let the simulation take over the dragged node again.
            if (app.drag == .node and app.drag_moved and app.simulating()) {
                const i = app.drag.node;
                const n = app.graph.nodes.items[i];
                app.force.pin(i, .{ n.x + n.w / 2, n.y + n.h / 2 }, false);
            }
            if (!app.drag_moved) {
                // A click: select what's under the cursor, or deselect.
                const wx, const wy = app.toWorld(app.mouse_x, app.mouse_y);
                const hit = app.graph.hit(wx, wy);
                if (app.drag != .none and hit != app.selected) {
                    app.selected = hit;
                    dirty_scene = true;
                }
            }
            app.drag = .none;
        },
        .mouse_scroll => |ev| {
            app.zoomAt(app.mouse_x, app.mouse_y, std.math.pow(f32, 1.1, ev.yoffset));
            dirty_camera = true;
        },
        .zoom_gesture => |ev| {
            app.zoomAt(app.mouse_x, app.mouse_y, 1 + ev.zoom);
            dirty_camera = true;
        },
        else => {},
    };

    if (!app.ready) {
        if (!app.gpu_ready.load(.acquire)) return;
        try app.setup(sprite, text);
        dirty_ui = true;
        dirty_camera = true;
    }

    // Reload the snapshot when the file changes.
    if (app.reload_timer.read() > (if (app.path == null) @as(f64, 0.1) else 0.5) and app.drag == .none) {
        _ = app.reload_timer.lap();
        if (app.reload()) dirty_scene = true;
    }

    if (app.simulating() and !dirty_scene) {
        const dragged: ?u32 = switch (app.drag) {
            .node => |i| i,
            else => null,
        };
        if (app.force.takePositions(&app.graph, dragged)) {
            try app.placeAll(sprite, text);
            if (app.fit_on_settle and !app.force.running()) {
                app.fit_on_settle = false;
                app.fit();
                dirty_camera = true;
            }
        }
    }

    if (dirty_scene) {
        try app.rebuildScene(sprite, text);
        dirty_ui = true;
        dirty_camera = true;
    }
    if (dirty_ui) try app.rebuildUi(sprite, text);
    if (dirty_camera or dirty_ui) {
        app.applyCamera(sprite, text);
        // Edge thickness depends on the zoom.
        if (app.zoom != app.edges_zoom) {
            app.edges_zoom = app.zoom;
            for (0..app.graph.edges.items.len) |ei| app.placeEdge(sprite, @intCast(ei));
        }
    }
}

/// Whether the current graph is laid out by the force simulation.
fn simulating(app: *const App) bool {
    return app.layout_mode == .gravity and !app.graph.positioned and app.graph.nodes.items.len > 0;
}

fn setView(app: *App, view: Model.View, dirty: *bool) void {
    if (app.view == view) return;
    app.view = view;
    app.selected = null;
    app.needs_fit = true;
    dirty.* = true;
}

fn toWorld(app: *const App, x: f32, y: f32) struct { f32, f32 } {
    return .{ app.cam_x + (x - app.win_w / 2) / app.zoom, app.cam_y - (y - app.win_h / 2) / app.zoom };
}

fn zoomAt(app: *App, x: f32, y: f32, factor: f32) void {
    const before_x, const before_y = app.toWorld(x, y);
    app.zoom = std.math.clamp(app.zoom * factor, 0.02, 8);
    const after_x, const after_y = app.toWorld(x, y);
    app.cam_x += before_x - after_x;
    app.cam_y += before_y - after_y;
}

fn fit(app: *App) void {
    const b = app.graph.bounds();
    const w = @max(b[2] - b[0], 1);
    const h = @max(b[3] - b[1], 1);
    const avail_w = app.win_w - 40 - (if (app.selected != null) details_width else 0);
    const avail_h = app.win_h - top_bar_h - 40;
    app.zoom = std.math.clamp(@min(avail_w / w, avail_h / h), 0.02, 2);
    app.cam_x = (b[0] + b[2]) / 2;
    app.cam_y = (b[1] + b[3]) / 2 + (top_bar_h / 2) / app.zoom;
}

/// Takes the latest snapshot: from the live connection, or the capture file if it changed.
/// Returns whether there was a new one.
fn reload(app: *App) bool {
    const path = app.path orelse {
        var name_buf: [64]u8 = undefined;
        const st = app.live.status(&name_buf);
        if (!st.connected) {
            app.setStatus("searching for a running Mach app on 127.0.0.1:{d}-{d} (Debug builds serve the inspector)", .{ protocol.first_port, protocol.first_port + protocol.num_ports - 1 });
            return false;
        }
        const json = app.live.take() orelse {
            app.setStatus("live: {s} (pid {d}, port {d}), {d} snapshots", .{ st.app, st.pid, st.port, st.snapshots });
            return false;
        };
        app.setStatus("live: {s} (pid {d}, port {d}), {d} snapshots", .{ st.app, st.pid, st.port, st.snapshots });
        return app.load(json);
    };
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(app.io, path, .{}) catch {
        app.setStatus("can't open capture {s}", .{path});
        return false;
    };
    const mtime = stat.mtime.nanoseconds;
    if (mtime == app.mtime) return false;
    const json = cwd.readFileAlloc(app.io, path, app.allocator, .limited(512 * 1024 * 1024)) catch |err| {
        app.setStatus("reading {s}: {s}", .{ path, @errorName(err) });
        return false;
    };
    app.mtime = mtime;
    app.setStatus("capture {s}", .{path});
    return app.load(json);
}

/// Parses a snapshot, taking ownership of `json`.
fn load(app: *App, json: []u8) bool {
    if (app.snapshot_json) |old| app.allocator.free(old);
    app.snapshot_json = json;
    _ = app.snapshot_arena.reset(.retain_capacity);
    app.snapshot = Model.parse(app.snapshot_arena.allocator(), json) catch |err| {
        app.setStatus("parsing snapshot: {s}", .{@errorName(err)});
        return true;
    };
    return true;
}

/// Saves the current snapshot as a capture file, which the tool can open later.
fn saveCapture(app: *App) void {
    const json = app.snapshot_json orelse return;
    const s = app.snapshot orelse return;
    var name: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "mach-capture-{d}.json", .{s.sequence}) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = json }) catch |err| {
        app.setStatus("saving {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    app.setStatus("saved {s} (open it with: zig build inspector -- {s})", .{ path, path });
}

fn setStatus(app: *App, comptime fmt: []const u8, args: anytype) void {
    app.status = std.fmt.bufPrint(&app.status_buf, fmt, args) catch app.status_buf[0..];
}

/// Writes a view of the current snapshot to `<prefix>-<view>.svg`.
fn exportSvg(app: *App, view: Model.View, prefix: []const u8) void {
    const s = app.snapshot orelse return;
    var arena: std.heap.ArenaAllocator = .init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Model.build(a, &s, view, app.options) catch return;
    if (view == app.view) {
        // Keep the positions on screen, including moved nodes.
        for (app.graph.nodes.items) |cur| if (g.find(cur.key)) |i| {
            g.nodes.items[i].x = cur.x;
            g.nodes.items[i].y = cur.y;
        };
    }
    const path = std.fmt.allocPrint(a, "{s}-{s}.svg", .{ prefix, @tagName(view) }) catch return;
    const title = std.fmt.allocPrint(a, "Mach inspector: {s} ({s}, snapshot #{d})", .{ view.title(), app.path orelse "live", s.sequence }) catch return;
    var out: std.Io.Writer.Allocating = .init(a);
    Model.writeSvg(&g, &out.writer, &palette, title) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() }) catch |err| {
        app.setStatus("writing {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    app.setStatus("wrote {s}", .{path});
}

// ---------------------------------------------------------------------------------------------
// Scene

fn setup(app: *App, sprite: *gfx.Sprite, text: *gfx.Text) !void {
    app.world_sprites = try sprite.pipelines.new(.{ .window = app.window, .texture = app.palette_texture });
    app.world_text = try text.pipelines.new(.{ .window = app.window });
    app.ui_sprites = try sprite.pipelines.new(.{ .window = app.window, .texture = app.palette_texture, .render_group = ui_group });
    app.ui_text = try text.pipelines.new(.{ .window = app.window, .render_group = ui_group });
    // gfx.Text divides font sizes by a fixed pixel density of 2.
    const size = Model.font_size * 2;
    app.styles[@backingInt(TextStyle.normal)] = try text.styles.new(.{ .font_size = size, .color = vec4(0.93, 0.94, 0.96, 1) });
    app.styles[@backingInt(TextStyle.dim)] = try text.styles.new(.{ .font_size = size, .color = vec4(0.62, 0.65, 0.72, 1) });
    app.styles[@backingInt(TextStyle.title)] = try text.styles.new(.{ .font_size = size, .color = vec4(1, 0.82, 0.38, 1) });
    app.styles[@backingInt(TextStyle.problem)] = try text.styles.new(.{ .font_size = size, .color = vec4(1, 0.45, 0.4, 1) });
    app.styles[@backingInt(TextStyle.accent)] = try text.styles.new(.{ .font_size = size, .color = vec4(0.55, 0.8, 1, 1) });
    app.ready = true;
}

fn style(app: *const App, s: TextStyle) mach.ObjectID {
    return app.styles[@backingInt(s)];
}

fn uvFor(color: Model.Color) Mat3x3 {
    const x: f32 = @floatFromInt(@as(u32, @backingInt(color)) * palette_block + 1);
    return Mat3x3.translate(vec2(x, 1));
}

fn rectTransform(x: f32, y: f32, w: f32, h: f32, z: f32) Mat4x4 {
    return Mat4x4.translate(vec3(x, y, z)).mul(&Mat4x4.scale(vec3(w, h, 1)));
}

fn lineTransform(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, z: f32) Mat4x4 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    return Mat4x4.translate(vec3(x0, y0, z))
        .mul(&Mat4x4.rotateZ(std.math.atan2(dy, dx)))
        .mul(&Mat4x4.translate(vec3(0, -thickness / 2, 0)))
        .mul(&Mat4x4.scale(vec3(@max(len, 0.001), thickness, 1)));
}

fn newRect(sprite: *gfx.Sprite, transform: Mat4x4, color: Model.Color) !mach.ObjectID {
    return sprite.objects.new(.{ .transform = transform, .uv_transform = uvFor(color), .size = vec2(1, 1) });
}

fn appendToRenderList(module: anytype, allocator: std.mem.Allocator, pipeline: mach.ObjectID, ids: []const mach.ObjectID) !void {
    var list = module.pipelines.get(pipeline, .render_list);
    try list.appendSlice(allocator, ids);
    module.pipelines.set(pipeline, .render_list, list);
}

fn deleteAll(app: *App, sprite: *gfx.Sprite, text: *gfx.Text) void {
    for (app.node_sprites.items) |n| {
        sprite.objects.delete(n.fill);
        sprite.objects.delete(n.border);
        text.objects.delete(n.text);
    }
    for (app.edge_sprites.items) |e| {
        sprite.objects.delete(e.line);
        sprite.objects.delete(e.head);
    }
    app.node_sprites.clearRetainingCapacity();
    app.edge_sprites.clearRetainingCapacity();
}

/// Whether node `i` is the selection or connected to it.
fn isNeighbor(app: *const App, i: u32) bool {
    const sel = app.selected orelse return true;
    if (sel == i) return true;
    for (app.graph.edges.items) |e| {
        if ((e.from == sel and e.to == i) or (e.to == sel and e.from == i)) return true;
    }
    return false;
}

fn edgeTouchesSelection(app: *const App, e: Model.Edge) bool {
    const sel = app.selected orelse return false;
    return e.from == sel or e.to == sel;
}

fn rebuildScene(app: *App, sprite: *gfx.Sprite, text: *gfx.Text) !void {
    if (!app.ready) return;
    app.deleteAll(sprite, text);
    // Keep positions across snapshots of the same view.
    app.prev_positions.clearRetainingCapacity();
    if (!app.needs_fit) {
        for (app.graph.nodes.items) |n| app.prev_positions.put(app.allocator, n.key, .{ n.x, n.y }) catch break;
    }
    _ = app.graph_arena.reset(.retain_capacity);
    app.graph = .{};
    const s = app.snapshot orelse return;
    app.graph = try Model.build(app.graph_arena.allocator(), &s, app.view, app.options);
    if (app.selected) |i| if (i >= app.graph.nodes.items.len) {
        app.selected = null;
    };
    for (app.graph.nodes.items) |*n| {
        if (app.moved.get(n.key)) |pos| {
            n.x = pos[0];
            n.y = pos[1];
        }
    }
    app.components = &.{};
    if (app.color_mode == .component and !app.graph.positioned) {
        app.components = try Model.colorByComponent(app.graph_arena.allocator(), &app.graph);
    }
    if (app.simulating()) {
        var known: usize = 0;
        for (app.graph.nodes.items) |*n| {
            if (app.prev_positions.get(n.key)) |pos| {
                n.x = pos[0];
                n.y = pos[1];
                known += 1;
            }
        }
        // Mostly the same graph (e.g. a new live snapshot): only settle what changed.
        const warm = known * 10 >= app.graph.nodes.items.len * 9;
        try app.force.setGraph(&app.graph, if (warm) 0.1 else 1);
        if (app.needs_fit) app.fit_on_settle = true;
    }

    var sprite_ids: std.ArrayList(mach.ObjectID) = .empty;
    defer sprite_ids.deinit(app.allocator);
    var text_ids: std.ArrayList(mach.ObjectID) = .empty;
    defer text_ids.deinit(app.allocator);

    for (app.graph.edges.items) |e| {
        const line = try newRect(sprite, Mat4x4.ident, .edge);
        const head = try newRect(sprite, Mat4x4.ident, .edge);
        try app.edge_sprites.append(app.allocator, .{ .line = line, .head = head });
        try sprite_ids.appendSlice(app.allocator, &.{ line, head });
        _ = e;
    }
    for (app.graph.nodes.items, 0..) |n, i| {
        const neighbor = app.isNeighbor(@intCast(i));
        const fill = try newRect(sprite, Mat4x4.ident, if (neighbor) n.color else .dim);
        const border_color: Model.Color = if (app.selected == @as(u32, @intCast(i))) .select else if (n.problem) .problem else .border;
        const border = try newRect(sprite, Mat4x4.ident, border_color);
        const label_style: TextStyle = if (!neighbor) .dim else if (n.problem) .problem else .normal;
        const t = if (n.sub.len > 0)
            try text.createFmt(Mat4x4.ident, .{
                .{ app.style(label_style), "{s}\n", .{n.label} },
                .{ app.style(.dim), "{s}", .{n.sub} },
            })
        else
            try text.createFmt(Mat4x4.ident, .{.{ app.style(label_style), "{s}", .{n.label} }});
        try app.node_sprites.append(app.allocator, .{ .fill = fill, .border = border, .text = t });
        try sprite_ids.appendSlice(app.allocator, &.{ border, fill });
        try text_ids.append(app.allocator, t);
    }
    try appendToRenderList(sprite, app.allocator, app.world_sprites, sprite_ids.items);
    try appendToRenderList(text, app.allocator, app.world_text, text_ids.items);

    try app.placeAll(sprite, text);
    if (app.needs_fit) {
        app.fit();
        app.needs_fit = false;
    }
    app.scene_ready.store(true, .release);
}

/// Positions every node and edge.
fn placeAll(app: *App, sprite: *gfx.Sprite, text: *gfx.Text) !void {
    for (0..app.graph.nodes.items.len) |i| app.placeNodeOnly(sprite, text, @intCast(i));
    for (0..app.graph.edges.items.len) |ei| app.placeEdge(sprite, @intCast(ei));
}

/// Positions a node's sprites and text, and the edges touching it.
fn placeNode(app: *App, sprite: *gfx.Sprite, text: *gfx.Text, i: u32) !void {
    app.placeNodeOnly(sprite, text, i);
    for (app.graph.edges.items, 0..) |e, ei| {
        if (e.from == i or e.to == i) app.placeEdge(sprite, @intCast(ei));
    }
}

fn placeNodeOnly(app: *App, sprite: *gfx.Sprite, text: *gfx.Text, i: u32) void {
    const n = app.graph.nodes.items[i];
    const s = app.node_sprites.items[i];
    const bw: f32 = if (app.selected == i or n.problem) 3 else 1;
    sprite.objects.set(s.border, .transform, rectTransform(n.x - bw, n.y - bw, n.w + 2 * bw, n.h + 2 * bw, 0.5));
    sprite.objects.set(s.fill, .transform, rectTransform(n.x, n.y, n.w, n.h, 0.4));
    text.objects.set(s.text, .transform, Mat4x4.translate(vec3(n.x + Model.pad, n.y + n.h - Model.pad / 2 - Model.font_size * 0.85, 0)));
}

fn placeEdge(app: *App, sprite: *gfx.Sprite, ei: u32) void {
    const e = app.graph.edges.items[ei];
    const a = app.graph.nodes.items[e.from];
    const b = app.graph.nodes.items[e.to];
    // From the right side of `a` to the left side of `b` when b is to the right, else between
    // the closest vertical sides.
    var x0 = a.x + a.w;
    var x1 = b.x;
    if (b.x + b.w < a.x) {
        x0 = a.x;
        x1 = b.x + b.w;
    } else if (b.x < a.x + a.w) {
        x0 = a.x + a.w / 2;
        x1 = b.x + b.w / 2;
    }
    const y0 = a.y + a.h / 2;
    const y1 = b.y + (if (b.x < a.x + a.w and b.x + b.w > a.x) (if (b.y > a.y) @as(f32, 0) else b.h) else b.h / 2);
    const hi = app.edgeTouchesSelection(e);
    const color: Model.Color = if (hi) .edge_hi else if (app.selected != null) .edge_dim else e.color;
    const s = app.edge_sprites.items[ei];
    // Constant on screen, whatever the zoom.
    const thickness: f32 = (if (hi) @as(f32, 2.5) else 1.5) / app.zoom;
    sprite.objects.set(s.line, .transform, lineTransform(x0, y0, x1, y1, thickness, 0.9));
    sprite.objects.set(s.line, .uv_transform, uvFor(color));
    const head = @min(8, 8 / app.zoom);
    sprite.objects.set(s.head, .transform, rectTransform(x1 - head / 2, y1 - head / 2, head, head, 0.8));
    sprite.objects.set(s.head, .uv_transform, uvFor(color));
}

fn applyCamera(app: *App, sprite: *gfx.Sprite, text: *gfx.Text) void {
    if (!app.ready) return;
    const hw = app.win_w / 2 / app.zoom;
    const hh = app.win_h / 2 / app.zoom;
    const world = Mat4x4.projection2D(.{
        .left = app.cam_x - hw,
        .right = app.cam_x + hw,
        .bottom = app.cam_y - hh,
        .top = app.cam_y + hh,
        .near = -0.1,
        .far = 100,
    });
    sprite.pipelines.set(app.world_sprites, .view_projection, world);
    text.pipelines.set(app.world_text, .view_projection, world);
    // UI: window units, origin at the top-left, y up (so on-screen y is negative).
    const ui = Mat4x4.projection2D(.{ .left = 0, .right = app.win_w, .bottom = -app.win_h, .top = 0, .near = -0.1, .far = 100 });
    sprite.pipelines.set(app.ui_sprites, .view_projection, ui);
    text.pipelines.set(app.ui_text, .view_projection, ui);
}

// ---------------------------------------------------------------------------------------------
// Panels

const top_bar_h: f32 = 52;
const details_width: f32 = 500;
const ui_line_h = Model.line_h;

const Lines = struct {
    buf: [max_panel_lines][max_line_len]u8 = undefined,
    lens: [max_panel_lines]usize = @splat(0),
    styles: [max_panel_lines]TextStyle = @splat(.normal),
    n: usize = 0,
    max_len: usize = 0,

    fn add(l: *Lines, s: TextStyle, comptime fmt: []const u8, args: anytype) void {
        if (l.n == max_panel_lines) return;
        var w: std.Io.Writer = .fixed(&l.buf[l.n]);
        w.print(fmt, args) catch {}; // truncated
        l.lens[l.n] = w.end;
        l.styles[l.n] = s;
        l.max_len = @max(l.max_len, w.end);
        l.n += 1;
    }
};

/// A `Text.setFmt` spec printing one line, with `fmt` comptime as setFmt requires.
const LineSpec = struct { mach.ObjectID, comptime []const u8 = "{s}{s}", struct { []const u8, []const u8 } };

fn addPanelText(app: *App, text: *gfx.Text, lines: *const Lines, x: f32, y: f32) !void {
    var specs: [max_panel_lines]LineSpec = undefined;
    for (&specs, 0..) |*spec, i| {
        const used = i < lines.n;
        const line = if (used) lines.buf[i][0..lines.lens[i]] else "";
        const newline = if (used and i + 1 < lines.n) "\n" else "";
        spec.* = .{ app.style(if (used) lines.styles[i] else .dim), "{s}{s}", .{ line, newline } };
    }
    const id = try text.createFmt(Mat4x4.translate(vec3(x, y - Model.font_size * 0.85, 0)), specs);
    try app.ui_texts.append(app.allocator, id);
    try appendToRenderList(text, app.allocator, app.ui_text, &.{id});
}

fn addPanel(app: *App, sprite: *gfx.Sprite, x: f32, y: f32, w: f32, h: f32, color: Model.Color) !void {
    // UI coordinates: y is negative going down the window.
    try app.panels.append(app.allocator, .{ x, y, w, h });
    const id = try newRect(sprite, rectTransform(x, -y - h, w, h, 0.5), color);
    try app.ui_objects.append(app.allocator, id);
    try appendToRenderList(sprite, app.allocator, app.ui_sprites, &.{id});
}

fn rebuildUi(app: *App, sprite: *gfx.Sprite, text: *gfx.Text) !void {
    if (!app.ready) return;
    for (app.ui_objects.items) |id| sprite.objects.delete(id);
    for (app.ui_texts.items) |id| text.objects.delete(id);
    app.ui_objects.clearRetainingCapacity();
    app.ui_texts.clearRetainingCapacity();
    app.problem_lines.clearRetainingCapacity();
    app.problems_panel = .{ 0, 0, 0, 0 };
    app.panels.clearRetainingCapacity();

    const s = app.snapshot;
    const problems = if (s) |snap| snap.gpu.problems else &.{};

    // Top bar.
    try app.addPanel(sprite, 0, 0, app.win_w, top_bar_h, .panel);
    var top: Lines = .{};
    top.add(.title, "[1] Systems [2] Objects [3] GPU [4] Lifetimes [5] Threads [6] Timeline   view: {s}   [G] layout: {s}   [C] color: {s}   [K] render copies: {s}   [P] problems: {d}   [H] released: {s}   [F] fit  [L] relayout  [R] reload", .{
        app.view.title(),
        if (app.layout_mode == .gravity) "gravity" else "columns",
        if (app.color_mode == .kind) "type" else "component",
        if (app.options.show_copies) "shown" else "hidden",
        problems.len,
        if (app.options.show_released) "shown" else "hidden",
    });
    if (s) |snap| {
        var live: usize = 0;
        for (snap.gpu.objects) |o| if (o.released_frame == null) {
            live += 1;
        };
        top.add(.dim, "{s}   snapshot #{d}   frame {d}   GPU objects: {d} created, {d} released, {d} alive{s}   nodes: {d}", .{
            app.status,                                                                 snap.sequence,             snap.gpu.frame, snap.gpu.created_total, snap.gpu.released_total, live,
            if (!snap.gpu_track) "   (build with -Dgpu_track for GPU objects)" else "", app.graph.nodes.items.len,
        });
    } else top.add(.problem, "{s}", .{app.status});
    try app.addPanelText(text, &top, 12, -10);

    // Details of the selection.
    if (app.selected) |sel| if (sel < app.graph.nodes.items.len) {
        const n = app.graph.nodes.items[sel];
        var d: Lines = .{};
        d.add(.title, "{s}", .{n.label});
        var it = std.mem.splitScalar(u8, n.details, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            d.add(if (std.mem.startsWith(u8, line, "PROBLEM") or std.mem.startsWith(u8, line, "LEAK")) .problem else .normal, "{s}", .{line});
        }
        var ins: usize = 0;
        var outs: usize = 0;
        for (app.graph.edges.items) |e| {
            if (e.to == sel) ins += 1;
            if (e.from == sel) outs += 1;
        }
        app.toggle_lines.clearRetainingCapacity();
        if (n.toggles.len > 0) {
            d.add(.accent, "{s}", .{if (app.path == null) "params (click to toggle in the running app):" else "params (connect live to toggle):"});
            for (n.toggles) |t| {
                // Panel text starts 20 below the top bar; lines are ui_line_h apart.
                try app.toggle_lines.append(app.allocator, .{ .y = top_bar_h + 20 + @as(f32, @floatFromInt(d.n)) * ui_line_h, .toggle = t });
                d.add(if (t.value) .title else .dim, "  [{s}] .{s}", .{ if (t.value) "x" else " ", t.field });
            }
        }
        if (ins > 0) d.add(.accent, "from ({d}):", .{ins});
        for (app.graph.edges.items) |e| if (e.to == sel) d.add(.dim, "  <- {s}  {s}", .{ app.graph.nodes.items[e.from].label, e.label });
        if (outs > 0) d.add(.accent, "to ({d}):", .{outs});
        for (app.graph.edges.items) |e| if (e.from == sel) d.add(.dim, "  -> {s}  {s}", .{ app.graph.nodes.items[e.to].label, e.label });
        const h = @as(f32, @floatFromInt(d.n)) * ui_line_h + 20;
        const x = app.win_w - details_width - 10;
        try app.addPanel(sprite, x, top_bar_h + 10, details_width, @min(h, app.win_h - top_bar_h - 20), .panel);
        try app.addPanelText(text, &d, x + 10, -(top_bar_h + 20));
    };

    // Problems.
    if (app.show_problems and problems.len > 0) {
        var p: Lines = .{};
        p.add(.problem, "{d} problem(s) found by the GPU tracker (click one to show it):", .{problems.len});
        for (problems) |problem| {
            if (p.n + 2 > max_panel_lines / 2) break;
            p.add(.normal, "{s} x{d}: {s}", .{ problem.kind, problem.count, problem.message });
            p.add(.dim, "    at {s}", .{problem.at});
            try app.problem_lines.append(app.allocator, problem.object);
        }
        const w = @min(@as(f32, @floatFromInt(p.max_len)) * Model.char_w + 20, app.win_w - (if (app.selected != null) details_width + 30 else 20));
        const h = @as(f32, @floatFromInt(p.n)) * ui_line_h + 20;
        const y = app.win_h - h - 10;
        try app.addPanel(sprite, 10, y, w, h, .panel);
        try app.addPanelText(text, &p, 20, -(y + 10));
        app.problems_panel = .{ 10, y + 10 + ui_line_h, w, h };
    }

    // Legend.
    const legend: []const struct { Model.Color, []const u8 } = switch (app.view) {
        .systems => &.{ .{ .schedule, "schedule" }, .{ .system, "system" }, .{ .module, "module (state)" }, .{ .value, "schedule value" } },
        .objects => &.{ .{ .module, "module" }, .{ .list, "mach.Objects list" }, .{ .object, "object" }, .{ .texture, "GPU object" } },
        .threads => &.{ .{ .comp0, "thread / its systems" }, .{ .list, "mach.Objects list" }, .{ .value, "writes" }, .{ .edge, "reads" }, .{ .problem, "likely race" } },
        .timeline => &.{ .{ .comp0, "thread lane" }, .{ .comp3, "system run (by system)" } },
        .gpu, .lifetimes => &.{ .{ .shader, "shader" }, .{ .pipeline, "pipeline" }, .{ .layout, "layout" }, .{ .bind_group, "bind group" }, .{ .buffer, "buffer" }, .{ .texture, "texture / view" }, .{ .sampler, "sampler" }, .{ .released, "released" }, .{ .problem, "problem" } },
    };
    var comp_legend: [Model.num_component_colors + 2]struct { Model.Color, []const u8 } = undefined;
    var comp_names: [Model.num_component_colors + 1][40]u8 = undefined;
    const shown_legend = if (app.color_mode == .component and app.components.len > 0) blk: {
        const n = @min(app.components.len, Model.num_component_colors);
        for (app.components[0..n], 0..) |c, k| {
            const name = std.fmt.bufPrint(&comp_names[k], "component {d}: {d} nodes", .{ k + 1, c.size }) catch "component";
            comp_legend[k] = .{ c.color, name };
        }
        comp_legend[n] = .{ .comp_single, "unconnected" };
        comp_legend[n + 1] = .{ .comp_hub, "shared hub (not joining)" };
        break :blk comp_legend[0 .. n + 2];
    } else legend;
    var lg: Lines = .{};
    for (shown_legend) |item| lg.add(.dim, "{s}", .{item[1]});
    const lx = app.win_w - 210;
    const ly = if (app.selected != null) app.win_h - @as(f32, @floatFromInt(shown_legend.len)) * ui_line_h - 20 else top_bar_h + 10;
    if (app.selected == null or ly > top_bar_h + 300) {
        try app.addPanel(sprite, lx - 10, ly - 6, 210, @as(f32, @floatFromInt(shown_legend.len)) * ui_line_h + 12, .panel);
        for (shown_legend, 0..) |item, i| {
            try app.addPanel(sprite, lx, ly + @as(f32, @floatFromInt(i)) * ui_line_h + 4, 10, 10, item[0]);
        }
        try app.addPanelText(text, &lg, lx + 18, -ly);
    }
}

/// Handles a click on a panel. Returns whether it was on one.
fn clickUi(app: *App, dirty_scene: *bool, dirty_camera: *bool) bool {
    if (app.mouse_y < top_bar_h) return true;
    const p = app.problems_panel;
    if (p[2] > 0 and app.mouse_x >= p[0] and app.mouse_x <= p[0] + p[2] and app.mouse_y >= p[1] - ui_line_h and app.mouse_y <= p[1] + p[3]) {
        const line: usize = @intFromFloat(@max(0, (app.mouse_y - p[1]) / ui_line_h));
        const index = line / 2;
        if (index < app.problem_lines.items.len) app.showGpuObject(app.problem_lines.items[index], dirty_scene, dirty_camera);
        return true;
    }
    // Toggling a schedule param in the running app.
    if (app.selected != null and app.mouse_x >= app.win_w - details_width - 10) {
        for (app.toggle_lines.items) |l| {
            if (app.mouse_y >= l.y - 2 and app.mouse_y < l.y + ui_line_h - 2) {
                if (app.path == null) {
                    app.live.send(.{ .cmd = "set_param", .schedule = l.toggle.schedule, .field = l.toggle.field, .value = !l.toggle.value });
                    app.setStatus("set {s}.{s} = {}", .{ l.toggle.schedule, l.toggle.field, !l.toggle.value });
                }
                return true;
            }
        }
    }
    for (app.panels.items) |r| {
        if (app.mouse_x >= r[0] and app.mouse_x <= r[0] + r[2] and app.mouse_y >= r[1] and app.mouse_y <= r[1] + r[3]) return true;
    }
    return false;
}

/// Switches to the GPU view and selects a GPU object.
fn showGpuObject(app: *App, id: u32, dirty_scene: *bool, dirty_camera: *bool) void {
    const s = app.snapshot orelse return;
    // Show released objects if it was released.
    for (s.gpu.objects) |o| if (o.id == id and o.released_frame != null) {
        app.options.show_released = true;
    };
    if (app.view != .gpu) {
        app.view = .gpu;
        app.needs_fit = false;
    }
    _ = app.graph_arena.reset(.retain_capacity);
    app.graph = Model.build(app.graph_arena.allocator(), &s, app.view, app.options) catch return;
    for (app.graph.nodes.items) |*n| if (app.moved.get(n.key)) |pos| {
        n.x = pos[0];
        n.y = pos[1];
    };
    const i = app.graph.find(Model.keyOf(.{ "gpu", id })) orelse return;
    app.selected = i;
    const n = app.graph.nodes.items[i];
    app.cam_x = n.x + n.w / 2 + details_width / 2 / app.zoom;
    app.cam_y = n.y + n.h / 2;
    dirty_scene.* = true;
    dirty_camera.* = true;
}

// ---------------------------------------------------------------------------------------------
// Render thread

/// Creates the palette texture on first use, and begins the graph's render pass.
pub fn beginFrame(core: *mach.Core, app: *App, ctx: mach.Context) void {
    const window = core.windows.getValue(core.window);
    if (!app.gpu_ready.load(.acquire)) {
        app.createPalette(window.device, window.queue);
        return ctx.schedule.stop();
    }
    app.force.step(window.device, window.queue);
    // Give the app thread time to hand the scene over to the renderer.
    if (app.screenshot_path != null and app.shot_timer == null and app.scene_ready.load(.acquire)) app.shot_timer = mach.time.Timer.start(app.io);
    const take_shot = if (app.shot_timer) |*t| t.read() > 1.5 and app.shot_texture == null else false;
    const back_buffer = if (take_shot and !app.screenshot_done.load(.acquire)) blk: {
        // Render this frame offscreen, to save it in endFrame.
        const texture = window.device.createTexture(&.{
            .label = "inspector screenshot",
            .size = .{ .width = window.framebuffer_width, .height = window.framebuffer_height },
            .format = window.framebuffer_format,
            .usage = .{ .render_attachment = true, .copy_src = true },
        });
        app.shot_texture = texture;
        break :blk texture.createView(&.{ .label = "inspector screenshot" });
    } else window.swap_chain.getCurrentTextureView() orelse return ctx.schedule.stop();
    ctx.schedule.put(.back_buffer, back_buffer, .{.release});
    const encoder = window.device.createCommandEncoder(&.{ .label = "inspector" });
    ctx.schedule.put(.encoder, encoder, .{.release});
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer,
        .clear_value = clear_color,
        .load_op = .clear,
        .store_op = .store,
    }};
    const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{ .label = "inspector graph", .color_attachments = &color_attachments }));
    ctx.schedule.put(.render_pass, pass, .{ .end, .release });
}

/// Ends the graph's pass and begins the panels' pass on top of it.
pub fn beginUiPass(ctx: mach.Context) void {
    ctx.schedule.remove(.render_pass);
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = ctx.schedule.require(.back_buffer, *gpu.TextureView),
        .clear_value = clear_color,
        .load_op = .load,
        .store_op = .store,
    }};
    const encoder = ctx.schedule.require(.encoder, *gpu.CommandEncoder);
    const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{ .label = "inspector ui", .color_attachments = &color_attachments }));
    ctx.schedule.put(.render_pass, pass, .{ .end, .release });
    ctx.schedule.put(.render_group, ui_group, .{});
}

pub fn endFrame(core: *mach.Core, app: *App, ctx: mach.Context) void {
    const window = core.windows.getValue(core.window);
    ctx.schedule.remove(.render_pass);
    const encoder = ctx.schedule.require(.encoder, *gpu.CommandEncoder);
    const shot = app.shot_texture;
    var readback: ?*gpu.Buffer = null;
    const width = window.framebuffer_width;
    const height = window.framebuffer_height;
    const bytes_per_row = std.mem.alignForward(u32, width * 4, 256);
    if (shot) |texture| {
        readback = window.device.createBuffer(&.{
            .label = "inspector screenshot readback",
            .usage = .{ .copy_dst = true, .map_read = true },
            .size = @as(u64, bytes_per_row) * height,
        });
        encoder.copyTextureToBuffer(
            &.{ .texture = texture },
            &.{ .buffer = readback.?, .layout = .{ .bytes_per_row = bytes_per_row, .rows_per_image = height } },
            &.{ .width = width, .height = height },
        );
    }
    const command = encoder.finish(&.{ .label = "inspector" });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});

    if (readback) |buffer| {
        defer buffer.release();
        defer shot.?.release();
        app.shot_texture = null;
        app.saveScreenshot(window.device, buffer, width, height, bytes_per_row, window.framebuffer_format);
        app.screenshot_done.store(true, .release);
    }
}

fn saveScreenshot(app: *App, device: *gpu.Device, buffer: *gpu.Buffer, width: u32, height: u32, bytes_per_row: u32, format: gpu.Texture.Format) void {
    const State = struct {
        var mapped: std.atomic.Value(bool) = .init(false);
        inline fn callback(_: void, status: gpu.Buffer.MapAsyncStatus) void {
            _ = status;
            mapped.store(true, .release);
        }
    };
    const size = @as(usize, bytes_per_row) * height;
    buffer.mapAsync(.{ .read = true }, 0, size, {}, State.callback);
    var spins: usize = 0;
    while (!State.mapped.load(.acquire) and spins < 1_000_000) : (spins += 1) device.tick();
    const data: [*]const u8 = @ptrCast(buffer.getConstMappedRange(u8, 0, size) orelse return);
    const bgra = format == .bgra8_unorm or format == .bgra8_unorm_srgb;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.allocator);
    out.print(app.allocator, "P6\n{d} {d}\n255\n", .{ width, height }) catch return;
    for (0..height) |y| for (0..width) |x| {
        const px = data[y * bytes_per_row + x * 4 ..][0..4];
        const rgb = if (bgra) [3]u8{ px[2], px[1], px[0] } else [3]u8{ px[0], px[1], px[2] };
        out.appendSlice(app.allocator, &rgb) catch return;
    };
    buffer.unmap();
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = app.screenshot_path.?, .data = out.items }) catch return;
}

fn createPalette(app: *App, device: *gpu.Device, queue: *gpu.Queue) void {
    const size = gpu.Extent3D{ .width = palette_width, .height = palette_block };
    const texture = device.createTexture(&.{
        .label = "inspector palette",
        .size = size,
        .format = .rgba8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    var pixels: [palette_block][palette_width][4]u8 = undefined;
    for (&pixels) |*row| for (row, 0..) |*px, x| {
        px.* = palette[x / palette_block];
    };
    const layout = gpu.Texture.DataLayout{ .bytes_per_row = palette_width * 4, .rows_per_image = palette_block };
    queue.writeTexture(&.{ .texture = texture }, &layout, &size, std.mem.sliceAsBytes(&pixels));
    app.palette_texture = texture;
    app.gpu_ready.store(true, .release);
}
