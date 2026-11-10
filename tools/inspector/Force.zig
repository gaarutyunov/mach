//! Force-directed layout simulated on the GPU (see force.wgsl): nodes keep the columns of the
//! layered layout (left to right), and are arranged vertically so that related nodes line up.
//!
//! Threading: the app thread hands the graph over with `setGraph`, pins dragged nodes with `pin`,
//! and picks up positions with `takePositions`. The render thread runs the simulation in `step`,
//! where all GPU work happens.
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const Model = @import("Model.zig");

const Force = @This();

pub const Node = extern struct {
    pos: [2]f32,
    vel: [2]f32 = .{ 0, 0 },
    half: [2]f32,
    pinned: u32 = 0,
    _pad: u32 = 0,
};

pub const Params = extern struct {
    count: u32,
    edge_count: u32,
    alpha: f32,
    /// Between nodes of the same column.
    repulsion: f32 = 300,
    /// The vertical gap kept between nodes of the same column.
    spring_len: f32 = 10,
    spring_k: f32 = 0.05,
    gravity: f32 = 0.004,
    damping: f32 = 0.6,
    flow: f32 = 0.05,
    max_speed: f32 = 80,
    _pad0: u32 = 0,
    _pad1: u32 = 0,
};

const shader = mach.wgsl.Shader("force.wgsl", @embedFile("force.wgsl"));
comptime {
    shader.checkHostType("params", Params);
    shader.checkHostType("nodes_in", Node);
    shader.checkHostType("nodes_out", Node);
}

const workgroup_size = 64;
/// Simulation steps per frame.
const steps_per_frame = 8;
/// The simulation stops once alpha decays below this.
const alpha_min = 0.004;
const alpha_decay = 0.985;

/// The graph handed from the app thread to the render thread.
const Input = struct {
    nodes: []Node,
    offsets: []u32,
    adj: []u32,
    edge_count: u32,
    alpha: f32,
    gen: u64,
};

const Pin = struct { index: u32, pos: [2]f32, pinned: bool };

allocator: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,

// App thread -> render thread, under `mutex`.
pending: ?Input = null,
pins: std.ArrayList(Pin) = .empty,
reheat: f32 = 0,

// Render thread -> app thread, under `mutex`.
positions: std.ArrayList([2]f32) = .empty,
positions_seq: u64 = 0,
/// The simulation's current alpha (1 when it starts, decaying until it stops).
alpha: f32 = 0,

/// The graph handed over by the latest `setGraph`, and the one `positions` were computed for:
/// positions of an older graph don't apply to the current one's nodes.
graph_gen: u64 = 0,
positions_gen: u64 = 0,

// App thread only.
taken_seq: u64 = 0,

// Render thread only.
gpu_state: ?Gpu = null,

const Gpu = struct {
    count: u32,
    edge_count: u32,
    alpha: f32,
    /// The `graph_gen` of the graph simulated.
    gen: u64,
    pipeline: *gpu.ComputePipeline,
    layout: *gpu.BindGroupLayout,
    params: *gpu.Buffer,
    nodes: [2]*gpu.Buffer,
    offsets: *gpu.Buffer,
    adj: *gpu.Buffer,
    readback: *gpu.Buffer,
    /// [0] reads nodes[0] and writes nodes[1], [1] the other way around.
    groups: [2]*gpu.BindGroup,

    fn deinit(g: *Gpu) void {
        for (g.groups) |b| b.release();
        g.readback.release();
        g.adj.release();
        g.offsets.release();
        for (g.nodes) |b| b.release();
        g.params.release();
        g.layout.release();
        g.pipeline.release();
    }
};

pub fn init(allocator: std.mem.Allocator, io: std.Io) Force {
    return .{ .allocator = allocator, .io = io };
}

/// Frees everything; GPU resources must be released before, with `releaseGpu` on the render
/// thread.
pub fn deinit(f: *Force) void {
    if (f.pending) |p| f.freeInput(p);
    f.pins.deinit(f.allocator);
    f.positions.deinit(f.allocator);
}

pub fn releaseGpu(f: *Force) void {
    if (f.gpu_state) |*g| g.deinit();
    f.gpu_state = null;
}

fn freeInput(f: *Force, p: Input) void {
    f.allocator.free(p.nodes);
    f.allocator.free(p.offsets);
    f.allocator.free(p.adj);
}

/// Starts simulating a graph, from its nodes' current positions, at `alpha` (1 for a new layout,
/// lower to only settle what changed).
pub fn setGraph(f: *Force, g: *const Model.Graph, alpha: f32) !void {
    const n = g.nodes.items.len;
    const nodes = try f.allocator.alloc(Node, n);
    errdefer f.allocator.free(nodes);
    for (g.nodes.items, nodes) |src, *dst| dst.* = .{
        .pos = .{ src.x + src.w / 2, src.y + src.h / 2 },
        .half = .{ src.w / 2, src.h / 2 },
    };
    // Undirected adjacency (CSR), the top bit marking the edges the node is the source of.
    const offsets = try f.allocator.alloc(u32, n + 1);
    errdefer f.allocator.free(offsets);
    @memset(offsets, 0);
    for (g.edges.items) |e| {
        offsets[e.from + 1] += 1;
        offsets[e.to + 1] += 1;
    }
    for (1..n + 1) |i| offsets[i] += offsets[i - 1];
    const adj = try f.allocator.alloc(u32, @max(offsets[n], 1));
    errdefer f.allocator.free(adj);
    const fill = try f.allocator.alloc(u32, n);
    defer f.allocator.free(fill);
    @memcpy(fill, offsets[0..n]);
    for (g.edges.items) |e| {
        adj[fill[e.from]] = e.to | 0x8000_0000;
        fill[e.from] += 1;
        adj[fill[e.to]] = e.from;
        fill[e.to] += 1;
    }

    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    if (f.pending) |old| f.freeInput(old);
    f.graph_gen += 1;
    f.pending = .{ .nodes = nodes, .offsets = offsets, .adj = adj, .edge_count = @intCast(g.edges.items.len), .alpha = alpha, .gen = f.graph_gen };
    f.pins.clearRetainingCapacity();
    f.alpha = alpha;
}

/// Pins a node at a position (its center), e.g. while it's dragged, and reheats the simulation so
/// the rest follows.
pub fn pin(f: *Force, index: u32, center: [2]f32, pinned: bool) void {
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    f.pins.append(f.allocator, .{ .index = index, .pos = center, .pinned = pinned }) catch return;
    f.reheat = @max(f.reheat, 0.3);
}

/// Restarts the simulation from the current positions.
pub fn restart(f: *Force) void {
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    f.reheat = 1;
}

/// Whether the simulation is running.
pub fn running(f: *Force) bool {
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    return f.alpha >= alpha_min or f.pending != null;
}

/// Copies the latest simulated positions into the graph's nodes (except `skip`, e.g. a node being
/// dragged). Returns whether there were new ones.
pub fn takePositions(f: *Force, g: *Model.Graph, skip: ?u32) bool {
    f.mutex.lockUncancelable(f.io);
    defer f.mutex.unlock(f.io);
    if (f.positions_seq == f.taken_seq or f.positions_gen != f.graph_gen or f.positions.items.len != g.nodes.items.len) return false;
    f.taken_seq = f.positions_seq;
    for (g.nodes.items, f.positions.items, 0..) |*n, p, i| {
        if (skip == @as(u32, @intCast(i))) continue;
        n.x = p[0] - n.w / 2;
        n.y = p[1] - n.h / 2;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Render thread

/// Runs a few simulation steps and reads the positions back. Call once per frame on the render
/// thread.
pub fn step(f: *Force, device: *gpu.Device, queue: *gpu.Queue) void {
    // Take what the app thread handed over.
    var input: ?Input = null;
    var pins: [64]Pin = undefined;
    var num_pins: usize = 0;
    var reheat: f32 = 0;
    {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        input = f.pending;
        f.pending = null;
        num_pins = @min(f.pins.items.len, pins.len);
        @memcpy(pins[0..num_pins], f.pins.items[f.pins.items.len - num_pins ..]);
        f.pins.clearRetainingCapacity();
        reheat = f.reheat;
        f.reheat = 0;
    }
    if (input) |in| {
        defer f.freeInput(in);
        f.upload(device, queue, in) catch |err| {
            std.log.err("inspector: force layout: {s}", .{@errorName(err)});
            return;
        };
    }
    const g = if (f.gpu_state) |*g| g else return;
    if (g.count == 0) return;

    for (pins[0..num_pins]) |p| {
        if (p.index >= g.count) continue;
        // Overwrite position and pinned (and zero the velocity) of the node in the current buffer.
        const partial = [_]f32{ p.pos[0], p.pos[1], 0, 0 };
        queue.writeBuffer(g.nodes[0], @as(u64, p.index) * @sizeOf(Node), &partial);
        const pinned = [_]u32{@intFromBool(p.pinned)};
        queue.writeBuffer(g.nodes[0], @as(u64, p.index) * @sizeOf(Node) + @offsetOf(Node, "pinned"), &pinned);
    }
    g.alpha = @max(g.alpha, reheat);
    if (g.alpha < alpha_min and num_pins == 0) return;

    const encoder = device.createCommandEncoder(&.{ .label = "inspector force layout" });
    defer encoder.release();
    for (0..steps_per_frame) |s| {
        const params: Params = .{ .count = g.count, .edge_count = g.edge_count, .alpha = g.alpha };
        // Each step needs its own alpha, but writeBuffer on the encoder happens in order with
        // the passes.
        encoder.writeBuffer(g.params, 0, &[_]Params{params});
        const pass = encoder.beginComputePass(&.{ .label = "inspector force step" });
        pass.setPipeline(g.pipeline);
        pass.setBindGroup(0, g.groups[s % 2], null);
        pass.dispatchWorkgroups((g.count + workgroup_size - 1) / workgroup_size, 1, 1);
        pass.end();
        pass.release();
        g.alpha *= alpha_decay;
    }
    // An even number of steps: the result is back in nodes[0].
    encoder.copyBufferToBuffer(g.nodes[0], 0, g.readback, 0, @as(u64, g.count) * @sizeOf(Node));
    const command = encoder.finish(&.{ .label = "inspector force layout" });
    defer command.release();
    queue.submit(&[_]*gpu.CommandBuffer{command});

    // Read the positions back (waiting for the GPU: this is a tool, simplicity wins).
    const State = struct {
        var mapped: std.atomic.Value(bool) = .init(false);
        inline fn callback(_: void, _: gpu.Buffer.MapAsyncStatus) void {
            mapped.store(true, .release);
        }
    };
    State.mapped.store(false, .release);
    const size = @as(usize, g.count) * @sizeOf(Node);
    g.readback.mapAsync(.{ .read = true }, 0, size, {}, State.callback);
    var spins: usize = 0;
    while (!State.mapped.load(.acquire) and spins < 10_000_000) : (spins += 1) device.tick();
    const nodes = g.readback.getConstMappedRange(Node, 0, g.count) orelse return;
    {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.positions.clearRetainingCapacity();
        for (nodes) |n| f.positions.append(f.allocator, n.pos) catch break;
        f.positions_seq += 1;
        f.positions_gen = g.gen;
        f.alpha = g.alpha;
    }
    g.readback.unmap();
}

fn upload(f: *Force, device: *gpu.Device, queue: *gpu.Queue, in: Input) !void {
    f.releaseGpu();
    const count: u32 = @intCast(in.nodes.len);
    if (count == 0) return;
    const node_bytes = @as(u64, count) * @sizeOf(Node);
    const storage: gpu.Buffer.UsageFlags = .{ .storage = true, .copy_dst = true, .copy_src = true };

    const layout = device.createBindGroupLayout(&shader.layoutDescriptor(0, "inspector force layout"));
    const bind_group_layouts = [_]*gpu.BindGroupLayout{layout};
    const pipeline_layout = device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .label = "inspector force layout",
        .bind_group_layouts = &bind_group_layouts,
    }));
    defer pipeline_layout.release();
    const module = device.createShaderModuleWGSL(shader.file_name, @embedFile("force.wgsl"));
    defer module.release();
    const pipeline = device.createComputePipeline(&.{
        .label = "inspector force layout",
        .layout = pipeline_layout,
        .compute = .{ .module = module, .entry_point = shader.computeEntry("step") },
    });

    const params = device.createBuffer(&.{ .label = "inspector force params", .usage = .{ .uniform = true, .copy_dst = true }, .size = @sizeOf(Params) });
    const nodes = [2]*gpu.Buffer{
        device.createBuffer(&.{ .label = "inspector force nodes a", .usage = storage, .size = node_bytes }),
        device.createBuffer(&.{ .label = "inspector force nodes b", .usage = storage, .size = node_bytes }),
    };
    const offsets = device.createBuffer(&.{ .label = "inspector force adjacency offsets", .usage = storage, .size = in.offsets.len * @sizeOf(u32) });
    const adj = device.createBuffer(&.{ .label = "inspector force adjacency", .usage = storage, .size = in.adj.len * @sizeOf(u32) });
    const readback = device.createBuffer(&.{ .label = "inspector force readback", .usage = .{ .map_read = true, .copy_dst = true }, .size = node_bytes });

    queue.writeBuffer(nodes[0], 0, in.nodes);
    queue.writeBuffer(nodes[1], 0, in.nodes);
    queue.writeBuffer(offsets, 0, in.offsets);
    queue.writeBuffer(adj, 0, in.adj);

    var groups: [2]*gpu.BindGroup = undefined;
    for (&groups, 0..) |*group, i| {
        group.* = device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
            .label = "inspector force",
            .layout = layout,
            .entries = &shader.bindGroupEntries(0, .{
                .params = .{ .buffer = params },
                .nodes_in = .{ .buffer = nodes[i] },
                .nodes_out = .{ .buffer = nodes[1 - i] },
                .adj_offsets = .{ .buffer = offsets },
                .adj = .{ .buffer = adj },
            }),
        }));
    }
    f.gpu_state = .{
        .count = count,
        .edge_count = in.edge_count,
        .alpha = in.alpha,
        .gen = in.gen,
        .pipeline = pipeline,
        .layout = layout,
        .params = params,
        .nodes = nodes,
        .offsets = offsets,
        .adj = adj,
        .readback = readback,
        .groups = groups,
    };
}
