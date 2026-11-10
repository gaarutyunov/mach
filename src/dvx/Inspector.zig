//! Inspector exporter: periodically writes a JSON snapshot of the program for the inspector tool
//! (`zig build inspector -- mach-inspect.json`), which draws it as an interactive graph:
//!
//! * modules, their systems and schedules, and what each system accesses (modules it takes as
//!   parameters, modules it calls via `mach.Mod`, schedule values it requires)
//! * schedule dataflow: which systems put and read which `ctx.schedule` values (recorded at
//!   runtime)
//! * `mach.Objects` lists and their objects, parent/child relations, object IDs held in fields,
//!   and GPU objects held in fields (CPU -> GPU)
//! * GPU objects (from sysgpu's tracker, see `-Dgpu_track`): lifetimes, reference counts, the
//!   code which created and released them, how they refer to each other (pipeline -> layout ->
//!   bind group layouts, bind group -> buffers/views/samplers, view -> texture, ...), uploads,
//!   and API usage problems (over-releases, leaks, bind groups not matching their layout or
//!   their pipeline's shaders, ...)
//!
//! Compiled in Debug builds (override with `-Dinspector=true|false`), and inactive unless the
//! `MACH_INSPECT` environment variable is set: to `1` to write `mach-inspect.json` in the working
//! directory, or to a file path. `MACH_INSPECT_INTERVAL` sets the seconds between snapshots
//! (default 1). The file is replaced atomically, so the tool can reload it as it changes.
//!
//! Usage: register `mach.dvx.Inspector` in your `mach.Modules`, schedule `.{ dvx.Inspector,
//! .init }` in your init, and `.{ dvx.Inspector, .tick }` on the thread which mutates your
//! objects (usually the app tick).
const std = @import("std");
const mach = @import("../main.zig");
const build_options = @import("build-options");
const track = @import("../sysgpu/main.zig").track;
const dataflow = @import("../module/dataflow.zig");

const Inspector = @This();

/// Whether the inspector is compiled in, see `-Dinspector`.
pub const enabled = build_options.inspector;

pub const mach_module = .mach_dvx_inspector;

pub const mach_systems = .{ .init, .tick, .dump };

/// Version of the snapshot format, increased on incompatible changes.
pub const format_version = 1;

active: bool = false,
path_buf: [std.fs.max_path_bytes]u8 = undefined,
path_len: usize = 0,
interval: f64 = 1,
timer: mach.time.Timer = undefined,
snapshots: u64 = 0,
buffer: [64 * 1024]u8 = undefined,

pub fn init(inspector: *Inspector, ctx: mach.Context) void {
    inspector.* = .{};
    if (!enabled) return;
    const env = std.c.getenv("MACH_INSPECT") orelse return;
    const value = std.mem.span(env);
    if (value.len == 0 or std.mem.eql(u8, value, "0")) return;
    const path = if (std.mem.eql(u8, value, "1")) "mach-inspect.json" else value;
    if (path.len > inspector.path_buf.len - 8) return ctx.err("MACH_INSPECT path too long", .{});
    @memcpy(inspector.path_buf[0..path.len], path);
    inspector.path_len = path.len;
    if (std.c.getenv("MACH_INSPECT_INTERVAL")) |interval| {
        inspector.interval = std.fmt.parseFloat(f64, std.mem.span(interval)) catch 1;
    }
    inspector.active = true;
    inspector.timer = mach.time.Timer.start(ctx.io);
    dataflow.start();
    ctx.info("writing snapshots to {s} every {d}s, view them with: zig build inspector -- {s}", .{ path, inspector.interval, path });
}

/// Writes a snapshot if the interval has elapsed.
pub fn tick(inspector: *Inspector, ctx: mach.Context) void {
    if (!enabled or !inspector.active) return;
    // The first snapshot waits for the app to get going.
    if (inspector.timer.read() < inspector.interval) return;
    _ = inspector.timer.lap();
    inspector.dump(ctx);
}

/// Writes a snapshot now.
pub fn dump(inspector: *Inspector, ctx: mach.Context) void {
    if (!enabled or !inspector.active) return;
    inspector.write(ctx) catch |err| ctx.err("writing snapshot: {s}", .{@errorName(err)});
}

fn write(inspector: *Inspector, ctx: mach.Context) !void {
    const io = ctx.io;
    const path = inspector.path_buf[0..inspector.path_len];
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    const cwd = std.Io.Dir.cwd();
    {
        const file = try cwd.createFile(io, tmp, .{});
        defer file.close(io);
        var fw = file.writer(io, &inspector.buffer);
        const w = &fw.interface;
        try writeSnapshot(w, ctx, inspector.snapshots);
        try w.flush();
    }
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
    inspector.snapshots += 1;
}

/// Writes a whole snapshot: a JSON object with the modules' structure and state (see
/// `mach.Context.inspect`) and the GPU tracker's (`gpu`).
pub fn writeSnapshot(w: *std.Io.Writer, ctx: mach.Context, sequence: u64) !void {
    try w.print("{{\"version\":{d},\"sequence\":{d},\"gpu_track\":{},", .{ format_version, sequence, track.enabled });
    try ctx.inspect(w);
    try w.writeAll(",\"gpu\":");
    try track.writeJson(w);
    try w.writeAll("}\n");
}
