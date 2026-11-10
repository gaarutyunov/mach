//! The inspector's data model: a parsed snapshot (written by `mach.dvx.Inspector`), and the
//! graphs of its views with their layout. Independent of rendering, so it can be tested.
const std = @import("std");

pub const Snapshot = struct {
    version: u32 = 0,
    sequence: u64 = 0,
    gpu_track: bool = false,
    modules: []Module = &.{},
    dataflow: []Flow = &.{},
    gpu: Gpu = .{},

    pub const Module = struct {
        name: []const u8,
        type: []const u8 = "",
        systems: []System = &.{},
        lists: []List = &.{},
        gpu_fields: []GpuField = &.{},
        memory: ?Memory = null,
    };
    pub const Memory = struct { used: u64 = 0, peak: u64 = 0, budget: u64 = 0 };
    pub const System = struct {
        name: []const u8,
        kind: []const u8,
        params: []Param = &.{},
        entries: []Entry = &.{},
    };
    /// A system parameter (`kind` = module, mod, context, io, require, other) or a schedule
    /// param (`name`, `type`, `value`).
    pub const Param = struct {
        kind: []const u8 = "",
        module: []const u8 = "",
        mutable: bool = false,
        key: []const u8 = "",
        type: []const u8 = "",
        name: []const u8 = "",
        value: ?[]const u8 = null,
    };
    pub const Entry = struct { module: []const u8, system: []const u8, condition: ?[]const u8 = null };
    pub const List = struct {
        name: []const u8,
        type_id: u32 = 0,
        fields: []Field = &.{},
        live: u64 = 0,
        slots: u64 = 0,
        capacity: u64 = 0,
        objects: []Object = &.{},
    };
    pub const Field = struct { name: []const u8, type: []const u8 = "", gpu: bool = false };
    pub const Object = struct {
        id: u64,
        index: u64 = 0,
        gpu: []GpuField = &.{},
        refs: []Ref = &.{},
        children: []u64 = &.{},
    };
    pub const Ref = struct { field: []const u8, id: ?u64 = null, more: ?u64 = null };
    pub const GpuField = struct { field: []const u8, ptr: u64 };
    pub const Flow = struct { system: []const u8, key: []const u8, type: []const u8 = "", access: []const u8, count: u64 = 0 };

    pub const Gpu = struct {
        enabled: bool = false,
        frame: u64 = 0,
        created_total: u64 = 0,
        released_total: u64 = 0,
        objects: []GpuObject = &.{},
        edges: []GpuEdge = &.{},
        sites: []Site = &.{},
        problems: []Problem = &.{},
    };
    pub const GpuObject = struct {
        id: u32,
        ptr: u64 = 0,
        kind: []const u8,
        label: []const u8 = "",
        refs: i64 = 0,
        created_frame: u64 = 0,
        released_frame: ?u64 = null,
        bytes: u64 = 0,
        uploads: u64 = 0,
        upload_bytes: u64 = 0,
        uses: u64 = 0,
        last_used_frame: u64 = 0,
        created_at: []const u8 = "",
        released_at: ?[]const u8 = null,
        detail: std.json.Value = .null,
    };
    pub const GpuEdge = struct { from: u32, to: u32, kind: []const u8, slot: u32 = 0, count: u64 = 0, last_frame: u64 = 0 };
    pub const Site = struct { kind: []const u8, created: u64 = 0, released: u64 = 0, live: u64 = 0, at: []const u8 = "" };
    pub const Problem = struct { kind: []const u8, object: u32 = 0, count: u64 = 0, frame: u64 = 0, message: []const u8 = "", at: []const u8 = "" };
};

/// Parses a snapshot. Its memory belongs to `arena`.
pub fn parse(arena: std.mem.Allocator, json: []const u8) !Snapshot {
    return std.json.parseFromSliceLeaky(Snapshot, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Palette indices, see `App.palette`.
pub const Color = enum(u8) {
    white,
    panel,
    border,
    edge,
    edge_hi,
    select,
    problem,
    dim,
    module,
    system,
    schedule,
    value,
    list,
    object,
    shader,
    pipeline,
    layout,
    bind_group,
    buffer,
    texture,
    sampler,
    gpu_other,
    released,
    bar,
    edge_dim,
    grid,
    pass,
    warn,
};

pub const View = enum {
    systems,
    objects,
    gpu,
    lifetimes,

    pub fn title(v: View) []const u8 {
        return switch (v) {
            .systems => "Systems",
            .objects => "Objects",
            .gpu => "GPU",
            .lifetimes => "Lifetimes",
        };
    }
};

pub const Node = struct {
    /// Stable across snapshots, to keep positions the user dragged nodes to.
    key: u64,
    label: []const u8,
    sub: []const u8 = "",
    color: Color,
    /// Multi-line text for the details panel.
    details: []const u8 = "",
    problem: bool = false,
    released: bool = false,
    /// The GPU object it shows, if any (to select it from a problem).
    gpu_id: u32 = 0,
    layer: u32 = 0,
    order: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Edge = struct {
    from: u32,
    to: u32,
    color: Color = .edge,
    label: []const u8 = "",
};

pub const Graph = struct {
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    /// Whether nodes already have positions (no layered layout).
    positioned: bool = false,
    keys: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    pub fn addNode(g: *Graph, a: std.mem.Allocator, n: Node) !u32 {
        if (g.keys.get(n.key)) |i| return i;
        const i: u32 = @intCast(g.nodes.items.len);
        try g.nodes.append(a, n);
        try g.keys.put(a, n.key, i);
        return i;
    }

    pub fn find(g: *const Graph, key: u64) ?u32 {
        return g.keys.get(key);
    }

    pub fn addEdge(g: *Graph, a: std.mem.Allocator, e: Edge) !void {
        if (e.from == e.to) return;
        for (g.edges.items) |x| if (x.from == e.from and x.to == e.to) return;
        try g.edges.append(a, e);
    }

    /// The node at a world position, if any.
    pub fn hit(g: *const Graph, x: f32, y: f32) ?u32 {
        var i = g.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const n = g.nodes.items[i];
            if (x >= n.x and x <= n.x + n.w and y >= n.y and y <= n.y + n.h) return @intCast(i);
        }
        return null;
    }

    pub fn bounds(g: *const Graph) [4]f32 {
        if (g.nodes.items.len == 0) return .{ 0, 0, 100, 100 };
        var b: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for (g.nodes.items) |n| {
            b[0] = @min(b[0], n.x);
            b[1] = @min(b[1], n.y);
            b[2] = @max(b[2], n.x + n.w);
            b[3] = @max(b[3], n.y + n.h);
        }
        return b;
    }
};

pub fn keyOf(parts: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    inline for (parts) |p| {
        switch (@typeInfo(@TypeOf(p))) {
            .int, .comptime_int => h.update(std.mem.asBytes(&@as(u64, p))),
            else => h.update(p),
        }
        h.update("\x00");
    }
    return h.final();
}

pub const font_size: f32 = 14;
pub const char_w: f32 = font_size * 0.52;
/// gfx.Text advances lines by the font size.
pub const line_h: f32 = font_size;
pub const pad: f32 = 8;

fn sizeNode(n: *Node) void {
    const lines: f32 = if (n.sub.len > 0) 2 else 1;
    const chars: f32 = @floatFromInt(@max(n.label.len, n.sub.len));
    n.w = @max(60, chars * char_w + 2 * pad);
    n.h = lines * line_h + pad;
}

// ---------------------------------------------------------------------------------------------
// Views

pub const Options = struct {
    show_released: bool = false,
    /// Most objects per `mach.Objects` list shown in the objects view.
    max_objects: usize = 16,
};

pub fn build(a: std.mem.Allocator, s: *const Snapshot, view: View, opt: Options) !Graph {
    var g: Graph = .{};
    switch (view) {
        .systems => try buildSystems(a, s, &g),
        .objects => try buildObjects(a, s, &g, opt),
        .gpu => try buildGpu(a, s, &g, opt),
        .lifetimes => try buildLifetimes(a, s, &g, opt),
    }
    for (g.nodes.items) |*n| {
        if (n.w == 0) sizeNode(n);
    }
    if (!g.positioned) try layout(a, &g);
    return g;
}

fn systemKey(module: []const u8, system: []const u8) u64 {
    return keyOf(.{ "sys", module, system });
}

fn shortModule(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "mach_")) name["mach_".len..] else name;
}

fn buildSystems(a: std.mem.Allocator, s: *const Snapshot, g: *Graph) !void {
    // Systems and schedules.
    for (s.modules) |m| {
        for (m.systems) |sys| {
            const is_schedule = std.mem.eql(u8, sys.kind, "schedule");
            var d: std.Io.Writer.Allocating = .init(a);
            const w = &d.writer;
            try w.print("{s} {s}.{s}\n", .{ if (is_schedule) "schedule" else "system", m.name, sys.name });
            if (is_schedule) {
                for (sys.entries, 0..) |e, i| try w.print("  {d}. {s}.{s}{s}{s}\n", .{ i + 1, e.module, e.system, if (e.condition != null) " if ." else "", e.condition orelse "" });
                if (sys.params.len > 0) try w.writeAll("params:\n");
                for (sys.params) |p| try w.print("  .{s}: {s} = {s}\n", .{ p.name, p.type, p.value orelse "?" });
            } else {
                try w.writeAll("parameters:\n");
                for (sys.params) |p| {
                    if (std.mem.eql(u8, p.kind, "module")) {
                        try w.print("  {s}{s}\n", .{ if (p.mutable) "*" else "*const ", p.module });
                    } else if (std.mem.eql(u8, p.kind, "mod")) {
                        try w.print("  mach.Mod({s}) (calls its systems)\n", .{p.module});
                    } else if (std.mem.eql(u8, p.kind, "require")) {
                        try w.print("  mach.Require(.{s}, {s})\n", .{ p.key, p.type });
                    } else if (std.mem.eql(u8, p.kind, "other")) {
                        try w.print("  {s}\n", .{p.type});
                    } else try w.print("  {s}\n", .{p.kind});
                }
            }
            _ = try g.addNode(a, .{
                .key = systemKey(m.name, sys.name),
                .label = try std.fmt.allocPrint(a, "{s}.{s}", .{ shortModule(m.name), sys.name }),
                .sub = if (is_schedule) try std.fmt.allocPrint(a, "schedule, {d} entries", .{sys.entries.len}) else "",
                .color = if (is_schedule) .schedule else .system,
                .details = d.written(),
            });
        }
    }
    // Modules (the state systems access).
    for (s.modules) |m| {
        var d: std.Io.Writer.Allocating = .init(a);
        const w = &d.writer;
        try w.print("module {s}\n{s}\n", .{ m.name, m.type });
        if (m.memory) |mem| try w.print("memory: {Bi:.1} used, {Bi:.1} peak, budget {Bi:.1}\n", .{ mem.used, mem.peak, mem.budget });
        for (m.lists) |l| try w.print("objects .{s}: {d} live / {d} capacity\n", .{ l.name, l.live, l.capacity });
        _ = try g.addNode(a, .{
            .key = keyOf(.{ "mod", m.name }),
            .label = m.name,
            .sub = try std.fmt.allocPrint(a, "{d} systems, {d} object lists", .{ m.systems.len, m.lists.len }),
            .color = .module,
            .details = d.written(),
        });
    }
    // Edges: schedule -> entries, system -> modules it accesses or calls.
    for (s.modules) |m| {
        for (m.systems) |sys| {
            const from = g.find(systemKey(m.name, sys.name)) orelse continue;
            for (sys.entries, 0..) |e, i| {
                const to = g.find(systemKey(e.module, e.system)) orelse continue;
                try g.addEdge(a, .{ .from = from, .to = to, .label = try std.fmt.allocPrint(a, "{d}{s}{s}", .{ i + 1, if (e.condition != null) " if ." else "", e.condition orelse "" }), .color = .edge });
            }
            for (sys.params) |p| {
                if (std.mem.eql(u8, p.kind, "module") or std.mem.eql(u8, p.kind, "mod")) {
                    if (std.mem.eql(u8, p.module, m.name) and std.mem.eql(u8, p.kind, "module")) continue; // its own state
                    const to = g.find(keyOf(.{ "mod", p.module })) orelse continue;
                    try g.addEdge(a, .{ .from = from, .to = to, .color = if (std.mem.eql(u8, p.kind, "mod")) .schedule else .edge, .label = if (std.mem.eql(u8, p.kind, "mod")) "calls" else if (p.mutable) "writes" else "reads" });
                } else if (std.mem.eql(u8, p.kind, "require")) {
                    const v = try valueNode(a, g, p.key, p.type);
                    try g.addEdge(a, .{ .from = v, .to = from, .color = .value, .label = "requires" });
                }
            }
        }
    }
    // Schedule values: system -> value (put), value -> system (get).
    for (s.dataflow) |f| {
        const dot = std.mem.indexOfScalar(u8, f.system, '.') orelse continue;
        const sys = g.find(systemKey(f.system[0..dot], f.system[dot + 1 ..])) orelse continue;
        const v = try valueNode(a, g, f.key, f.type);
        const put = std.mem.eql(u8, f.access, "put");
        if (put) {
            try g.addEdge(a, .{ .from = sys, .to = v, .color = .value, .label = "puts" });
        } else {
            try g.addEdge(a, .{ .from = v, .to = sys, .color = .value, .label = f.access });
        }
        const n = &g.nodes.items[v];
        n.details = try std.fmt.allocPrint(a, "{s}{s} .{s} x{d}\n", .{ n.details, f.system, f.access, f.count });
    }
}

fn valueNode(a: std.mem.Allocator, g: *Graph, key: []const u8, type_name: []const u8) !u32 {
    if (g.find(keyOf(.{ "val", key }))) |i| return i;
    return g.addNode(a, .{
        .key = keyOf(.{ "val", key }),
        .label = try std.fmt.allocPrint(a, ".{s}", .{key}),
        .sub = shortType(type_name),
        .color = .value,
        .details = try std.fmt.allocPrint(a, "schedule value .{s}: {s}\naccesses:\n", .{ key, type_name }),
    });
}

fn shortType(t: []const u8) []const u8 {
    // "*sysgpu.sysgpu.texture_view.TextureView" -> "TextureView"
    if (std.mem.indexOfScalar(u8, t, '(') != null) return t;
    const last = std.mem.lastIndexOfScalar(u8, t, '.') orelse return t;
    return t[last + 1 ..];
}

fn gpuColor(kind: []const u8) Color {
    const map = .{
        .{ "shader_module", Color.shader },
        .{ "render_pipeline", Color.pipeline },
        .{ "compute_pipeline", Color.pipeline },
        .{ "pipeline_layout", Color.layout },
        .{ "bind_group_layout", Color.layout },
        .{ "bind_group", Color.bind_group },
        .{ "buffer", Color.buffer },
        .{ "texture", Color.texture },
        .{ "texture_view", Color.texture },
        .{ "sampler", Color.sampler },
        .{ "render_pass_encoder", Color.pass },
        .{ "compute_pass_encoder", Color.pass },
    };
    inline for (map) |e| if (std.mem.eql(u8, kind, e[0])) return e[1];
    return .gpu_other;
}

pub fn isTransientKind(kind: []const u8) bool {
    const kinds = [_][]const u8{ "command_encoder", "command_buffer", "render_pass_encoder", "compute_pass_encoder", "render_bundle_encoder" };
    for (kinds) |k| if (std.mem.eql(u8, kind, k)) return true;
    return false;
}

fn gpuProblems(s: *const Snapshot, id: u32) usize {
    var n: usize = 0;
    for (s.gpu.problems) |p| {
        if (p.object == id) n += 1;
    }
    return n;
}

fn gpuDetails(a: std.mem.Allocator, s: *const Snapshot, o: Snapshot.GpuObject) ![]const u8 {
    var d: std.Io.Writer.Allocating = .init(a);
    const w = &d.writer;
    try w.print("{s} #{d} '{s}'\n", .{ o.kind, o.id, o.label });
    try w.print("refs: {d}{s}\n", .{ o.refs, if (o.released_frame != null) " (released)" else "" });
    try w.print("created: frame {d} at {s}\n", .{ o.created_frame, o.created_at });
    if (o.released_frame) |f| try w.print("released: frame {d} at {s}\n", .{ f, o.released_at orelse "?" });
    if (o.bytes > 0) try w.print("memory: {Bi:.1}\n", .{o.bytes});
    if (o.uploads > 0) try w.print("CPU->GPU uploads: {d} ({Bi:.1})\n", .{ o.uploads, o.upload_bytes });
    if (o.uses > 0) try w.print("used: {d} times, last in frame {d}\n", .{ o.uses, o.last_used_frame });
    switch (o.detail) {
        .object => |obj| {
            if (obj.get("width")) |width| try w.print("size: {d}x{d}x{d} {s}, {d} mips\n", .{ width.integer, obj.get("height").?.integer, obj.get("depth").?.integer, obj.get("format").?.string, obj.get("mips").?.integer });
            if (obj.get("entries")) |entries| {
                try w.writeAll("entries:\n");
                for (entries.array.items) |e| try w.print("  {d}: {s} {s}{s}{s}\n", .{
                    e.object.get("binding").?.integer,
                    e.object.get("kind").?.string,
                    if (e.object.get("vertex").?.bool) "V" else "",
                    if (e.object.get("fragment").?.bool) "F" else "",
                    if (e.object.get("compute").?.bool) "C" else "",
                });
            }
            if (obj.get("bindings")) |bindings| {
                try w.writeAll("shader bindings:\n");
                for (bindings.array.items) |b| try w.print("  @group({d}) @binding({d}) {s}: {s} {s}{s}{s}\n", .{
                    b.object.get("group").?.integer,
                    b.object.get("binding").?.integer,
                    b.object.get("name").?.string,
                    b.object.get("kind").?.string,
                    if (b.object.get("vertex").?.bool) "V" else "",
                    if (b.object.get("fragment").?.bool) "F" else "",
                    if (b.object.get("compute").?.bool) "C" else "",
                });
            }
            if (obj.get("auto_layout")) |auto| if (auto.bool) try w.writeAll("layout: automatic\n");
        },
        else => {},
    }
    for (s.gpu.problems) |p| {
        if (p.object == o.id) try w.print("PROBLEM {s} (x{d}): {s}\n  at {s}\n", .{ p.kind, p.count, p.message, p.at });
    }
    return d.written();
}

fn edgeLabel(a: std.mem.Allocator, e: Snapshot.GpuEdge) ![]const u8 {
    if (std.mem.eql(u8, e.kind, "group_layout") or std.mem.eql(u8, e.kind, "draws_with")) return std.fmt.allocPrint(a, "@group({d})", .{e.slot});
    if (std.mem.eql(u8, e.kind, "resource")) return std.fmt.allocPrint(a, "binding {d}", .{e.slot});
    if (std.mem.eql(u8, e.kind, "shader")) return switch (e.slot) {
        0 => "vertex",
        1 => "fragment",
        else => "compute",
    };
    return e.kind;
}

fn buildGpu(a: std.mem.Allocator, s: *const Snapshot, g: *Graph, opt: Options) !void {
    // Released objects which shown objects refer to are still alive in the backend (e.g. a
    // pipeline keeps its shader modules and layout): show them too.
    var kept: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    {
        var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (s.gpu.objects) |o| if (o.released_frame == null and !isTransientKind(o.kind)) try live.put(a, o.id, {});
        var changed = true;
        while (changed) {
            changed = false;
            for (s.gpu.edges) |e| {
                if (std.mem.eql(u8, e.kind, "draws_with")) continue;
                if ((live.contains(e.from) or kept.contains(e.from)) and !live.contains(e.to) and !kept.contains(e.to)) {
                    try kept.put(a, e.to, e.from);
                    changed = true;
                }
            }
        }
    }
    for (s.gpu.objects) |o| {
        if (isTransientKind(o.kind)) continue;
        const kept_by = kept.get(o.id);
        if (o.released_frame != null and !opt.show_released and kept_by == null) continue;
        // One node per swap chain view would flood the graph.
        if (std.mem.eql(u8, o.label, "swap chain view")) continue;
        const problems = gpuProblems(s, o.id);
        _ = try g.addNode(a, .{
            .key = keyOf(.{ "gpu", o.id }),
            .label = try std.fmt.allocPrint(a, "{s} {s}", .{ o.kind, if (o.label.len > 0) o.label else "(no label)" }),
            .sub = if (o.released_frame != null and kept_by != null)
                try std.fmt.allocPrint(a, "#{d} released, kept alive by #{d}", .{ o.id, kept_by.? })
            else
                try std.fmt.allocPrint(a, "#{d} refs {d}{s}", .{ o.id, o.refs, if (o.released_frame != null) " released" else "" }),
            .color = if (o.released_frame != null and kept_by == null) .released else gpuColor(o.kind),
            .details = if (kept_by) |k| try std.fmt.allocPrint(a, "{s}released by the app, but kept alive by the backend while #{d} uses it\n", .{ try gpuDetails(a, s, o), k }) else try gpuDetails(a, s, o),
            .problem = problems > 0,
            .released = o.released_frame != null,
            .gpu_id = o.id,
        });
    }
    for (s.gpu.edges) |e| {
        const from = g.find(keyOf(.{ "gpu", e.from })) orelse continue;
        const to = g.find(keyOf(.{ "gpu", e.to })) orelse continue;
        // Point from what is used to what uses it, so data flows left to right: buffer ->
        // bind group -> pipeline.
        try g.addEdge(a, .{ .from = to, .to = from, .label = try edgeLabel(a, e), .color = if (std.mem.eql(u8, e.kind, "draws_with")) .bind_group else .edge });
    }
}

fn buildObjects(a: std.mem.Allocator, s: *const Snapshot, g: *Graph, opt: Options) !void {
    var gpu_by_ptr: std.AutoHashMapUnmanaged(u64, Snapshot.GpuObject) = .empty;
    for (s.gpu.objects) |o| if (o.released_frame == null) try gpu_by_ptr.put(a, o.ptr, o);
    var by_id: std.AutoHashMapUnmanaged(u64, u32) = .empty;

    for (s.modules) |m| {
        if (m.lists.len == 0 and m.gpu_fields.len == 0) continue;
        const mi = try g.addNode(a, .{ .key = keyOf(.{ "mod", m.name }), .label = m.name, .color = .module, .details = m.type });
        for (m.gpu_fields) |f| {
            const gi = try gpuNode(a, s, g, &gpu_by_ptr, f.ptr) orelse continue;
            try g.addEdge(a, .{ .from = mi, .to = gi, .label = f.field, .color = .texture });
        }
        for (m.lists) |l| {
            var d: std.Io.Writer.Allocating = .init(a);
            const w = &d.writer;
            try w.print("{s}.{s}: mach.Objects\n{d} live, {d} slots, capacity {d}\nfields:\n", .{ m.name, l.name, l.live, l.slots, l.capacity });
            for (l.fields) |f| try w.print("  {s}: {s}{s}\n", .{ f.name, f.type, if (f.gpu) "  (GPU)" else "" });
            const li = try g.addNode(a, .{
                .key = keyOf(.{ "list", m.name, l.name }),
                .label = try std.fmt.allocPrint(a, "{s}.{s}", .{ shortModule(m.name), l.name }),
                .sub = try std.fmt.allocPrint(a, "{d} live / {d} capacity", .{ l.live, l.capacity }),
                .color = .list,
                .details = d.written(),
            });
            try g.addEdge(a, .{ .from = mi, .to = li });
            for (l.objects, 0..) |o, oi| {
                if (oi == opt.max_objects) {
                    const more = try g.addNode(a, .{ .key = keyOf(.{ "more", m.name, l.name }), .label = try std.fmt.allocPrint(a, "+{d} more", .{l.live - opt.max_objects}), .color = .dim });
                    try g.addEdge(a, .{ .from = li, .to = more });
                    break;
                }
                const ni = try objectNode(a, g, l, o, m.name);
                try g.addEdge(a, .{ .from = li, .to = ni });
                // References by ID resolve to the first list having it (render copies of a list,
                // such as gfx.Sprite's render_objects, share the IDs of the original).
                const gop = try by_id.getOrPut(a, o.id);
                if (!gop.found_existing) gop.value_ptr.* = ni;
            }
        }
    }
    // Relations between objects and to GPU objects.
    for (s.modules) |m| for (m.lists) |l| for (l.objects) |o| {
        const from = g.find(keyOf(.{ "obj", m.name, l.name, o.id })) orelse continue;
        for (o.refs) |r| {
            const id = r.id orelse continue;
            const to = by_id.get(id) orelse continue;
            try g.addEdge(a, .{ .from = from, .to = to, .label = r.field, .color = .object });
        }
        for (o.children) |c| {
            const to = by_id.get(c) orelse continue;
            try g.addEdge(a, .{ .from = from, .to = to, .label = "child", .color = .value });
        }
        for (o.gpu) |f| {
            const gi = try gpuNode(a, s, g, &gpu_by_ptr, f.ptr) orelse continue;
            try g.addEdge(a, .{ .from = from, .to = gi, .label = f.field, .color = .texture });
        }
    };
}

fn objectNode(a: std.mem.Allocator, g: *Graph, l: Snapshot.List, o: Snapshot.Object, module: []const u8) !u32 {
    var d: std.Io.Writer.Allocating = .init(a);
    const w = &d.writer;
    try w.print("object {d} (index {d}) of {s}.{s}\n", .{ o.id, o.index, module, l.name });
    for (o.refs) |r| {
        if (r.id) |id| try w.print("  .{s} -> object {d}\n", .{ r.field, id }) else if (r.more) |n| try w.print("  .{s}: +{d} more\n", .{ r.field, n });
    }
    for (o.gpu) |f| try w.print("  .{s} -> GPU object at 0x{x}\n", .{ f.field, f.ptr });
    if (o.children.len > 0) try w.print("  {d} children\n", .{o.children.len});
    return g.addNode(a, .{
        .key = keyOf(.{ "obj", module, l.name, o.id }),
        .label = try std.fmt.allocPrint(a, "{s} #{d}", .{ l.name, o.index }),
        .color = .object,
        .details = d.written(),
    });
}

fn gpuNode(a: std.mem.Allocator, s: *const Snapshot, g: *Graph, by_ptr: *std.AutoHashMapUnmanaged(u64, Snapshot.GpuObject), ptr: u64) !?u32 {
    const o = by_ptr.get(ptr) orelse return null;
    return try g.addNode(a, .{
        .key = keyOf(.{ "gpu", o.id }),
        .label = try std.fmt.allocPrint(a, "{s} {s}", .{ o.kind, o.label }),
        .sub = try std.fmt.allocPrint(a, "#{d} refs {d}", .{ o.id, o.refs }),
        .color = gpuColor(o.kind),
        .details = try gpuDetails(a, s, o),
        .problem = gpuProblems(s, o.id) > 0,
        .gpu_id = o.id,
    });
}

/// A timeline of GPU object lifetimes, one row per object (frames on the x axis), followed by the
/// creation sites with their counts.
fn buildLifetimes(a: std.mem.Allocator, s: *const Snapshot, g: *Graph, opt: Options) !void {
    g.positioned = true;
    const frames: f32 = @floatFromInt(@max(s.gpu.frame, 1));
    const width: f32 = 1600;
    const px_per_frame = width / frames;
    const row_h = line_h + 4;
    var y: f32 = 0;

    // Axis.
    _ = try g.addNode(a, .{ .key = keyOf(.{"axis"}), .label = try std.fmt.allocPrint(a, "frame 0 .. {d}   (bars: created -> released, open bars are alive)", .{s.gpu.frame}), .color = .grid, .x = 0, .y = y, .w = width, .h = row_h });
    y -= row_h + 6;

    var objects: std.ArrayList(Snapshot.GpuObject) = .empty;
    for (s.gpu.objects) |o| {
        if (isTransientKind(o.kind)) continue;
        if (o.released_frame != null and !opt.show_released) continue;
        try objects.append(a, o);
    }
    std.mem.sortUnstable(Snapshot.GpuObject, objects.items, {}, struct {
        fn lt(_: void, x: Snapshot.GpuObject, z: Snapshot.GpuObject) bool {
            return x.created_frame < z.created_frame or (x.created_frame == z.created_frame and x.id < z.id);
        }
    }.lt);
    for (objects.items) |o| {
        const start: f32 = @as(f32, @floatFromInt(o.created_frame)) * px_per_frame;
        const end: f32 = @as(f32, @floatFromInt(o.released_frame orelse s.gpu.frame)) * px_per_frame;
        const label = try std.fmt.allocPrint(a, "{s} '{s}' #{d}{s}", .{ o.kind, o.label, o.id, if (o.released_frame == null) "" else "  (released)" });
        _ = try g.addNode(a, .{
            .key = keyOf(.{ "life", o.id }),
            .label = label,
            .color = if (gpuProblems(s, o.id) > 0) .problem else if (o.released_frame != null) .released else gpuColor(o.kind),
            .details = try gpuDetails(a, s, o),
            .problem = gpuProblems(s, o.id) > 0,
            .released = o.released_frame != null,
            .gpu_id = o.id,
            .x = start,
            .y = y,
            .w = @max(end - start, @as(f32, @floatFromInt(label.len)) * char_w + 2 * pad),
            .h = row_h,
        });
        y -= row_h + 2;
    }

    // Creation sites: per-frame objects show up here, with how many are still alive.
    y -= 20;
    _ = try g.addNode(a, .{ .key = keyOf(.{"sites"}), .label = "creation sites: created / released / alive", .color = .grid, .x = 0, .y = y, .w = width, .h = row_h });
    y -= row_h + 6;
    var sites: std.ArrayList(Snapshot.Site) = .empty;
    try sites.appendSlice(a, s.gpu.sites);
    std.mem.sortUnstable(Snapshot.Site, sites.items, {}, struct {
        fn lt(_: void, x: Snapshot.Site, z: Snapshot.Site) bool {
            return x.created > z.created;
        }
    }.lt);
    for (sites.items) |site| {
        // A per-frame object with more alive than one or two frames' worth is leaking.
        const leaking = isTransientKind(site.kind) and site.live > 2;
        const label = try std.fmt.allocPrint(a, "{s} x{d} / {d} / {d}  {s}", .{ site.kind, site.created, site.released, site.live, site.at });
        _ = try g.addNode(a, .{
            .key = keyOf(.{ "site", site.at, site.kind }),
            .label = label,
            .color = if (leaking) .problem else if (site.live > 0) gpuColor(site.kind) else .released,
            .details = try std.fmt.allocPrint(a, "{s} created at {s}\ncreated {d}, released {d}, alive {d}{s}\n", .{ site.kind, site.at, site.created, site.released, site.live, if (leaking) "\nLEAK: per-frame objects from here aren't released" else "" }),
            .problem = leaking,
            .x = 0,
            .y = y,
            .w = @as(f32, @floatFromInt(label.len)) * char_w + 2 * pad,
            .h = row_h,
        });
        y -= row_h + 2;
    }
}

// ---------------------------------------------------------------------------------------------
// SVG export

/// Writes a graph as SVG, with `colors` the RGBA of each `Color`.
pub fn writeSvg(g: *const Graph, w: *std.Io.Writer, colors: []const [4]u8, title: []const u8) !void {
    const b = g.bounds();
    const margin: f32 = 40;
    const width = b[2] - b[0] + 2 * margin;
    const height = b[3] - b[1] + 2 * margin + 30;
    // SVG's y goes down: flip around the top of the bounds.
    const ox = margin - b[0];
    const oy = b[3] + margin + 30;
    try w.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d:.0}\" font-family=\"Menlo, monospace\" font-size=\"{d:.0}\">\n", .{ width, height, font_size });
    try w.print("<rect width=\"100%\" height=\"100%\" fill=\"#0e0f13\"/>\n<text x=\"{d:.0}\" y=\"24\" fill=\"#ffd060\">", .{margin});
    try xmlText(w, title);
    try w.writeAll("</text>\n");
    for (g.edges.items) |e| {
        const a = g.nodes.items[e.from];
        const c = g.nodes.items[e.to];
        const col = colors[@backingInt(e.color)];
        try w.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#{x:0>2}{x:0>2}{x:0>2}\" stroke-width=\"1.5\"/>\n", .{
            ox + a.x + a.w, oy - (a.y + a.h / 2), ox + c.x, oy - (c.y + c.h / 2), col[0], col[1], col[2],
        });
    }
    for (g.nodes.items) |n| {
        const col = colors[@backingInt(n.color)];
        const stroke = if (n.problem) colors[@backingInt(Color.problem)] else colors[@backingInt(Color.border)];
        try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"3\" fill=\"#{x:0>2}{x:0>2}{x:0>2}\" stroke=\"#{x:0>2}{x:0>2}{x:0>2}\" stroke-width=\"{d}\"/>\n", .{
            ox + n.x, oy - (n.y + n.h), n.w, n.h, col[0], col[1], col[2], stroke[0], stroke[1], stroke[2], @as(u32, if (n.problem) 3 else 1),
        });
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"#eceef2\">", .{ ox + n.x + pad, oy - (n.y + n.h) + pad / 2 + font_size });
        try xmlText(w, n.label);
        if (n.sub.len > 0) {
            try w.print("<tspan x=\"{d:.1}\" dy=\"{d:.1}\" fill=\"#a0a6b4\">", .{ ox + n.x + pad, line_h });
            try xmlText(w, n.sub);
            try w.writeAll("</tspan>");
        }
        try w.writeAll("</text>\n");
    }
    try w.writeAll("</svg>\n");
}

fn xmlText(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        else => try w.writeByte(c),
    };
}

// ---------------------------------------------------------------------------------------------
// Layered layout: layers by longest path (cycles broken), order by barycenter sweeps.

const max_per_column = 30;
const layer_gap: f32 = 120;
const node_gap: f32 = 14;

pub fn layout(a: std.mem.Allocator, g: *Graph) !void {
    const n = g.nodes.items.len;
    if (n == 0) return;

    // Remove cycles: DFS, dropping back edges.
    var out_edges = try a.alloc(std.ArrayList(u32), n);
    for (out_edges) |*l| l.* = .empty;
    for (g.edges.items) |e| try out_edges[e.from].append(a, e.to);
    const state = try a.alloc(u8, n); // 0 new, 1 on stack, 2 done
    @memset(state, 0);
    var dag: std.ArrayList([2]u32) = .empty;
    const Frame = struct { node: u32, next: usize };
    var stack: std.ArrayList(Frame) = .empty;
    for (0..n) |root| {
        if (state[root] != 0) continue;
        try stack.append(a, .{ .node = @intCast(root), .next = 0 });
        state[root] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const outs = out_edges[top.node].items;
            if (top.next == outs.len) {
                state[top.node] = 2;
                _ = stack.pop();
                continue;
            }
            const to = outs[top.next];
            top.next += 1;
            if (state[to] == 1) continue; // back edge
            try dag.append(a, .{ top.node, to });
            if (state[to] == 0) {
                state[to] = 1;
                try stack.append(a, .{ .node = to, .next = 0 });
            }
        }
    }

    // Longest path layering (Bellman-Ford style relaxation over the DAG).
    const layer = try a.alloc(u32, n);
    @memset(layer, 0);
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds < n + 1) : (rounds += 1) {
        changed = false;
        for (dag.items) |e| {
            if (layer[e[1]] < layer[e[0]] + 1) {
                layer[e[1]] = layer[e[0]] + 1;
                changed = true;
            }
        }
    }
    // Pull sources right next to their first successor, so they don't all sit in layer 0.
    for (0..n) |i| {
        var min_succ: u32 = std.math.maxInt(u32);
        var has_pred = false;
        for (dag.items) |e| {
            if (e[0] == i) min_succ = @min(min_succ, layer[e[1]]);
            if (e[1] == i) has_pred = true;
        }
        if (!has_pred and min_succ != std.math.maxInt(u32) and min_succ > 0) layer[i] = min_succ - 1;
    }

    var num_layers: u32 = 0;
    for (layer, g.nodes.items) |l, *node| {
        node.layer = l;
        num_layers = @max(num_layers, l + 1);
    }

    // Initial order: insertion order within each layer.
    var layers = try a.alloc(std.ArrayList(u32), num_layers);
    for (layers) |*l| l.* = .empty;
    for (0..n) |i| try layers[layer[i]].append(a, @intCast(i));
    for (layers) |l| for (l.items, 0..) |ni, pos| {
        g.nodes.items[ni].order = @floatFromInt(pos);
    };

    // Barycenter sweeps.
    const bary = try a.alloc(f32, n);
    for (0..12) |sweep| {
        const down = sweep % 2 == 0;
        for (0..n) |i| {
            var sum: f32 = 0;
            var count: f32 = 0;
            for (g.edges.items) |e| {
                const other: ?u32 = if (down and e.to == i) e.from else if (!down and e.from == i) e.to else null;
                if (other) |o| {
                    sum += g.nodes.items[o].order;
                    count += 1;
                }
            }
            bary[i] = if (count > 0) sum / count else g.nodes.items[i].order;
        }
        for (layers) |l| {
            std.mem.sort(u32, l.items, bary, struct {
                fn lt(b: []f32, x: u32, y: u32) bool {
                    return b[x] < b[y];
                }
            }.lt);
            for (l.items, 0..) |ni, pos| g.nodes.items[ni].order = @floatFromInt(pos);
        }
    }

    // Coordinates: layers left to right, big layers wrapped into several columns, each centered
    // vertically. y grows up, so rows go down from 0.
    var x: f32 = 0;
    for (layers) |l| {
        var col_start: usize = 0;
        while (col_start < l.items.len) : (col_start += max_per_column) {
            const col = l.items[col_start..@min(l.items.len, col_start + max_per_column)];
            var col_w: f32 = 0;
            var col_h: f32 = 0;
            for (col) |ni| {
                col_w = @max(col_w, g.nodes.items[ni].w);
                col_h += g.nodes.items[ni].h + node_gap;
            }
            var y: f32 = col_h / 2;
            for (col) |ni| {
                const node = &g.nodes.items[ni];
                y -= node.h;
                node.x = x;
                node.y = y;
                y -= node_gap;
            }
            x += col_w + layer_gap;
        }
    }
}

test "layout of a small graph" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Graph = .{};
    const n0 = try g.addNode(a, .{ .key = 1, .label = "a", .color = .system });
    const n1 = try g.addNode(a, .{ .key = 2, .label = "b", .color = .system });
    const n2 = try g.addNode(a, .{ .key = 3, .label = "c", .color = .system });
    try g.addEdge(a, .{ .from = n0, .to = n1 });
    try g.addEdge(a, .{ .from = n1, .to = n2 });
    try g.addEdge(a, .{ .from = n2, .to = n0 }); // cycle
    for (g.nodes.items) |*n| sizeNode(n);
    try layout(a, &g);
    try std.testing.expect(g.nodes.items[n0].x < g.nodes.items[n1].x);
    try std.testing.expect(g.nodes.items[n1].x < g.nodes.items[n2].x);
    try std.testing.expectEqual(n1, g.hit(g.nodes.items[n1].x + 1, g.nodes.items[n1].y + 1).?);
}

test "builds every view from a snapshot" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"version":1,"sequence":3,"gpu_track":true,
        \\"modules":[{"name":"app","type":"App","systems":[
        \\  {"name":"render","kind":"schedule","entries":[{"module":"app","system":"begin"},{"module":"mach_gfx_sprite","system":"render","condition":"ready"}],"params":[{"name":"ready","type":"bool","value":"true"}]},
        \\  {"name":"begin","kind":"fn","params":[{"kind":"module","module":"mach_core","mutable":true},{"kind":"context"}]}],
        \\  "lists":[],"gpu_fields":[]},
        \\ {"name":"mach_gfx_sprite","type":"Sprite","systems":[{"name":"render","kind":"fn","params":[{"kind":"require","key":"render_pass","type":"*RenderPassEncoder"}]}],
        \\  "lists":[{"name":"pipelines","type_id":2,"fields":[{"name":"texture","type":"*Texture","gpu":true}],"live":1,"slots":1,"capacity":4,
        \\    "objects":[{"id":99,"index":0,"gpu":[{"field":"texture","ptr":4096}],"refs":[{"field":"window","id":5}],"children":[]}]}],"gpu_fields":[]},
        \\ {"name":"mach_core","systems":[],"lists":[]}],
        \\"dataflow":[{"system":"app.begin","key":"render_pass","type":"*sysgpu.RenderPassEncoder","access":"put","count":10}],
        \\"gpu":{"enabled":true,"frame":100,"objects":[
        \\  {"id":1,"ptr":4096,"kind":"texture","label":"atlas","refs":1,"created_frame":0,"released_frame":null,"created_at":"a.zig:1: f","released_at":null,"detail":{"width":64,"height":64,"depth":1,"format":"rgba8_unorm","mips":1}},
        \\  {"id":2,"ptr":8192,"kind":"bind_group_layout","label":"l","refs":1,"created_frame":1,"released_frame":null,"created_at":"a.zig:2: f","released_at":null,"detail":{"entries":[{"binding":0,"kind":"uniform_buffer","vertex":true,"fragment":false,"compute":false}]}},
        \\  {"id":3,"ptr":1,"kind":"command_encoder","label":"","refs":0,"created_frame":5,"released_frame":5,"created_at":"a.zig:3: f","released_at":"a.zig:4: f","detail":null}],
        \\ "edges":[{"from":2,"to":1,"kind":"resource","slot":0,"count":1,"last_frame":1}],
        \\ "sites":[{"kind":"command_encoder","created":100,"released":90,"live":10,"at":"a.zig:3: f"}],
        \\ "problems":[{"kind":"over_release","object":1,"count":2,"frame":7,"message":"texture 'atlas' released twice","at":"a.zig:9: g"}]}}
    ;
    const s = try parse(a, json);
    try std.testing.expectEqual(3, s.modules.len);

    const systems = try build(a, &s, .systems, .{});
    try std.testing.expect(systems.find(systemKey("app", "render")) != null);
    try std.testing.expect(systems.find(keyOf(.{ "val", "render_pass" })) != null);
    try std.testing.expect(systems.edges.items.len >= 4);

    const objects = try build(a, &s, .objects, .{});
    try std.testing.expect(objects.find(keyOf(.{ "gpu", @as(u32, 1) })) != null);

    const gpu = try build(a, &s, .gpu, .{});
    try std.testing.expectEqual(2, gpu.nodes.items.len); // the encoder is per-frame
    const tex = gpu.nodes.items[gpu.find(keyOf(.{ "gpu", @as(u32, 1) })).?];
    try std.testing.expect(tex.problem);
    try std.testing.expect(std.mem.indexOf(u8, tex.details, "over_release") != null);

    const life = try build(a, &s, .lifetimes, .{});
    try std.testing.expect(life.positioned);
    const site = life.nodes.items[life.find(keyOf(.{ "site", "a.zig:3: f", "command_encoder" })).?];
    try std.testing.expect(site.problem); // 10 per-frame encoders alive: leak
}
