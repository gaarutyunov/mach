//! Inspector: serves live snapshots of the program to the inspector tool (`zig build inspector`),
//! which draws it as interactive graphs. Works like Tracy: the app listens on a local port, the
//! tool connects, and nothing is recorded until it does.
//!
//! Snapshots contain:
//! * modules, their systems and schedules, and what each system accesses (modules it takes as
//!   parameters, modules it calls via `mach.Mod`, schedule values it requires)
//! * schedule dataflow: which systems put and read which `ctx.schedule` values
//! * threads: which systems run on which thread, which `mach.Objects` lists they access with which
//!   locks held, and likely races
//! * `mach.Objects` lists and their objects, parent/child relations, object IDs held in fields,
//!   and GPU objects held in fields (CPU -> GPU)
//! * GPU objects (from sysgpu's tracker, see `-Dgpu_track`): lifetimes, reference counts, the
//!   code which created and released them, how they refer to each other, uploads, and API usage
//!   problems
//!
//! The tool can also send commands, e.g. to set a schedule's bool params (conditions).
//!
//! Compiled in Debug builds (override with `-Dinspector=true|false`); otherwise every system does
//! nothing. Listens on 127.0.0.1, port `inspector_protocol.first_port` or the next free one.
//!
//! Usage: register `mach.dvx.Inspector` in your `mach.Modules`, and schedule
//! `.{ dvx.Inspector, .init }` in your init, `.{ dvx.Inspector, .tick }` on the thread which
//! mutates your objects (usually the app tick), and `.{ dvx.Inspector, .deinit }` on exit.
const std = @import("std");
const builtin = @import("builtin");
const mach = @import("../main.zig");
const build_options = @import("build-options");
const track = @import("../sysgpu/main.zig").track;
const dataflow = @import("../module/dataflow.zig");
const protocol = @import("inspector_protocol.zig");

const Inspector = @This();

/// Whether the inspector is compiled in, see `-Dinspector`.
pub const enabled = build_options.inspector;

pub const mach_module = .mach_dvx_inspector;

pub const mach_systems = .{ .init, .tick, .deinit };

allocator: std.mem.Allocator = undefined,
io: std.Io = undefined,
/// The port listened on, or 0.
port: u16 = 0,
server: ?std.Io.net.Server = null,
server_thread: ?std.Thread = null,
stopping: std.atomic.Value(bool) = .init(false),

/// Seconds between snapshots while a tool is connected.
interval: f64 = 1,
timer: mach.time.Timer = undefined,
sequence: u64 = 0,

/// State shared between the app thread and the connection's threads.
mutex: std.Io.Mutex = .init,
connected: bool = false,
/// The latest snapshot not yet sent (only the latest matters).
outgoing: ?[]u8 = null,
outgoing_ready: std.Io.Event = .unset,
/// Commands received, applied on the app thread by `tick`.
commands: std.ArrayList(protocol.Command) = .empty,
command_arena: std.heap.ArenaAllocator = undefined,
snapshot_requested: bool = false,

pub fn init(inspector: *Inspector, ctx: mach.Context) void {
    inspector.* = .{};
    if (!enabled) return;
    inspector.allocator = ctx.allocator;
    inspector.io = ctx.io;
    inspector.timer = mach.time.Timer.start(ctx.io);
    inspector.command_arena = .init(ctx.allocator);

    // The first free port.
    var port = protocol.first_port;
    while (port < protocol.first_port + protocol.num_ports) : (port += 1) {
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        inspector.server = address.listen(ctx.io, .{}) catch continue;
        inspector.port = port;
        break;
    }
    if (inspector.server == null) {
        ctx.warn("no free port in {d}-{d}, the inspector tool can't connect", .{ protocol.first_port, protocol.first_port + protocol.num_ports - 1 });
        return;
    }
    inspector.server_thread = std.Thread.spawn(.{}, serve, .{inspector}) catch |err| {
        ctx.err("starting the inspector server: {s}", .{@errorName(err)});
        return;
    };
    ctx.info("listening on 127.0.0.1:{d}, connect with: zig build inspector", .{inspector.port});
}

/// Applies the tool's commands, and sends a snapshot when due. Run it on the thread which mutates
/// your objects.
pub fn tick(inspector: *Inspector, ctx: mach.Context) void {
    if (!enabled or inspector.server == null) return;
    var requested = false;
    {
        inspector.mutex.lockUncancelable(inspector.io);
        defer inspector.mutex.unlock(inspector.io);
        if (!inspector.connected) return;
        for (inspector.commands.items) |c| inspector.apply(ctx, c);
        inspector.commands.clearRetainingCapacity();
        _ = inspector.command_arena.reset(.retain_capacity);
        requested = inspector.snapshot_requested;
        inspector.snapshot_requested = false;
    }
    if (!requested and inspector.timer.read() < inspector.interval) return;
    _ = inspector.timer.lap();

    var out: std.Io.Writer.Allocating = .init(inspector.allocator);
    writeSnapshot(&out.writer, ctx, inspector.sequence) catch |err| {
        out.deinit();
        return ctx.err("writing snapshot: {s}", .{@errorName(err)});
    };
    inspector.sequence += 1;
    const snapshot = out.toOwnedSlice() catch return;
    inspector.mutex.lockUncancelable(inspector.io);
    defer inspector.mutex.unlock(inspector.io);
    if (inspector.outgoing) |old| inspector.allocator.free(old);
    inspector.outgoing = snapshot;
    inspector.outgoing_ready.set(inspector.io);
}

fn apply(inspector: *Inspector, ctx: mach.Context, c: protocol.Command) void {
    if (std.mem.eql(u8, c.cmd, "snapshot")) {
        inspector.snapshot_requested = true;
    } else if (std.mem.eql(u8, c.cmd, "interval")) {
        inspector.interval = std.math.clamp(c.seconds, 0.05, 60);
    } else if (std.mem.eql(u8, c.cmd, "set_param")) {
        if (ctx.setScheduleParam(c.schedule, c.field, c.value)) {
            ctx.info("set {s}.{s} = {}", .{ c.schedule, c.field, c.value });
            inspector.snapshot_requested = true;
        } else ctx.warn("no bool param {s}.{s}", .{ c.schedule, c.field });
    }
}

/// Stops serving. Run it on exit.
pub fn deinit(inspector: *Inspector) void {
    if (!enabled) return;
    inspector.stopping.store(true, .release);
    // Wakes the connection's writer, which then closes it.
    inspector.outgoing_ready.set(inspector.io);
    if (inspector.server_thread) |t| {
        // Closing the listening socket doesn't wake accept() on every platform: connect to it.
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", inspector.port) catch unreachable;
        if (address.connect(inspector.io, .{ .mode = .stream })) |s| s.close(inspector.io) else |_| {}
        t.join();
    }
    inspector.server_thread = null;
    if (inspector.server) |*server| server.deinit(inspector.io);
    inspector.server = null;
    if (inspector.outgoing) |o| inspector.allocator.free(o);
    inspector.outgoing = null;
    inspector.commands.deinit(inspector.allocator);
    inspector.command_arena.deinit();
}

/// Accepts one tool at a time, and streams snapshots to it.
fn serve(inspector: *Inspector) void {
    mach.module_threads.setName("inspector");
    const io = inspector.io;
    while (!inspector.stopping.load(.acquire)) {
        var server = inspector.server orelse return;
        const stream = server.accept(io) catch return;
        if (inspector.stopping.load(.acquire)) {
            stream.close(io);
            return;
        }
        inspector.connection(stream);
    }
}

fn connection(inspector: *Inspector, stream: std.Io.net.Stream) void {
    const io = inspector.io;
    defer stream.close(io);
    var write_buf: [64 * 1024]u8 = undefined;
    var sw = stream.writer(io, &write_buf);

    var hello_buf: [256]u8 = undefined;
    const hello = std.fmt.bufPrint(&hello_buf, "{{\"version\":{d},\"app\":\"{s}\",\"pid\":{d},\"port\":{d}}}", .{
        protocol.version, appName(), pid(), inspector.port,
    }) catch return;
    protocol.writeFrame(&sw.interface, .hello, hello) catch return;

    {
        inspector.mutex.lockUncancelable(io);
        defer inspector.mutex.unlock(io);
        inspector.connected = true;
        inspector.snapshot_requested = true;
    }
    dataflow.start();
    defer {
        dataflow.stop();
        inspector.mutex.lockUncancelable(io);
        inspector.connected = false;
        inspector.mutex.unlock(io);
    }

    // Commands are read on their own thread, so reads and writes don't block each other.
    const reader = std.Thread.spawn(.{}, readCommands, .{ inspector, stream }) catch return;
    defer reader.join();
    defer stream.shutdown(io, .both) catch {};

    while (!inspector.stopping.load(.acquire)) {
        inspector.outgoing_ready.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } }) catch {};
        inspector.mutex.lockUncancelable(io);
        const snapshot = inspector.outgoing;
        inspector.outgoing = null;
        inspector.outgoing_ready.reset();
        const still_connected = inspector.connected;
        inspector.mutex.unlock(io);
        if (!still_connected) return;
        const s = snapshot orelse continue;
        defer inspector.allocator.free(s);
        protocol.writeFrame(&sw.interface, .snapshot, s) catch return;
    }
}

fn readCommands(inspector: *Inspector, stream: std.Io.net.Stream) void {
    const io = inspector.io;
    var read_buf: [4096]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    while (true) {
        const frame = protocol.readFrame(&sr.interface, inspector.allocator) catch break;
        defer inspector.allocator.free(frame.payload);
        if (frame.kind != .command) continue;
        inspector.mutex.lockUncancelable(io);
        defer inspector.mutex.unlock(io);
        const c = std.json.parseFromSliceLeaky(protocol.Command, inspector.command_arena.allocator(), frame.payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch continue;
        inspector.commands.append(inspector.allocator, c) catch {};
    }
    // The tool disconnected: wake the writer so it notices.
    inspector.mutex.lockUncancelable(io);
    inspector.connected = false;
    inspector.mutex.unlock(io);
    inspector.outgoing_ready.set(io);
}

fn appName() []const u8 {
    if (mach.process_args) |args| {
        var it = args.iterate();
        if (it.next()) |exe| return std.fs.path.basename(exe);
    }
    // Custom entrypoints may not set mach.process_args.
    if (builtin.os.tag.isDarwin()) {
        const getprogname = struct {
            extern "c" fn getprogname() [*:0]const u8;
        }.getprogname;
        return std.mem.span(getprogname());
    }
    return "mach app";
}

fn pid() i64 {
    return switch (builtin.os.tag) {
        .windows => 0,
        else => std.c.getpid(),
    };
}

/// Writes a whole snapshot: a JSON object with the modules' structure and state (see
/// `mach.Context.inspect`) and the GPU tracker's (`gpu`).
pub fn writeSnapshot(w: *std.Io.Writer, ctx: mach.Context, sequence: u64) !void {
    try w.print("{{\"version\":{d},\"sequence\":{d},\"gpu_track\":{},", .{ protocol.version, sequence, track.enabled });
    try ctx.inspect(w);
    try w.writeAll(",\"gpu\":");
    try track.writeJson(w);
    try w.writeAll("}\n");
}
