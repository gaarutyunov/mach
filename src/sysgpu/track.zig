//! GPU object tracker: records every GPU object created through sysgpu, with its lifetime (the
//! frames it was created and released in, and the code which did), its app-level reference count,
//! the objects it refers to (a bind group's layout and resources, a pipeline's layout and
//! shaders, a view's texture, ...) and how it is used (draws, uploads).
//!
//! Enabled with `-Dgpu_track` (the default in Debug builds). Every hook is a no-op otherwise.
//!
//! It also checks API usage that sysgpu doesn't validate, logging (once per call site) an error
//! with the source locations involved instead of crashing or rendering garbage later:
//!
//! * over-release: releasing an object more times than it was acquired and referenced
//! * use after release: using an object the app already released
//! * leaks: objects still alive when their device is released (see `report`)
//! * bind groups whose entries don't match their layout (missing bindings, wrong resource types,
//!   buffers or textures without the usage the binding needs)
//! * pipeline layouts which don't provide the bindings the pipeline's shaders use, from the
//!   shaders' reflection
//! * draws with missing bind groups, or bind groups whose layout isn't the pipeline's
//!
//! The tracked objects, their relations and the problems found are exported by `writeJson` for
//! the inspector (`mach.dvx.Inspector`, viewed with `zig build inspector`).
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build-options");
const sysgpu = @import("sysgpu/main.zig");
const shader = @import("shader.zig");

const log = std.log.scoped(.gpu);

/// Whether GPU objects are tracked, see `-Dgpu_track`.
pub const enabled = build_options.gpu_track and !builtin.is_test;

pub const Kind = enum(u8) {
    instance,
    adapter,
    device,
    queue,
    surface,
    swap_chain,
    buffer,
    texture,
    texture_view,
    sampler,
    bind_group_layout,
    bind_group,
    pipeline_layout,
    shader_module,
    render_pipeline,
    compute_pipeline,
    command_encoder,
    command_buffer,
    render_pass_encoder,
    compute_pass_encoder,
    query_set,
    render_bundle,
    render_bundle_encoder,
    external_texture,

    /// Objects which usually live for a single frame.
    pub fn isTransient(k: Kind) bool {
        return switch (k) {
            .command_encoder, .command_buffer, .render_pass_encoder, .compute_pass_encoder, .render_bundle_encoder => true,
            else => false,
        };
    }
};

/// A relation from one object to another.
pub const RefKind = enum(u8) {
    /// Created from this device.
    device,
    /// A bind group's bind group layout, or a pipeline's pipeline layout.
    layout,
    /// A pipeline layout's bind group layout for group `slot`.
    group_layout,
    /// A pipeline's shader module for stage `slot` (0 vertex, 1 fragment, 2 compute).
    shader,
    /// A bind group's resource at binding `slot`.
    resource,
    /// A texture view's texture.
    view_of,
    /// A pass's or command buffer's command encoder.
    encoder,
    /// A render pass's attachment `slot` (color index, or 255 for depth/stencil).
    attachment,
    /// A pipeline drawn with this bind group at group `slot`.
    draws_with,
    /// A pipeline drawn with this vertex buffer at `slot`.
    vertex_buffer,
    /// A pipeline drawn with this index buffer.
    index_buffer,
    /// A swap chain's surface.
    surface,
    /// A view of the swap chain's current texture.
    swap_chain,
};

pub const BindingKind = enum(u8) {
    uniform_buffer,
    storage_buffer,
    read_only_storage_buffer,
    sampler,
    comparison_sampler,
    texture,
    depth_texture,
    storage_texture,
    external_texture,
    unknown,

    pub fn resourceType(k: BindingKind) enum { buffer, sampler, texture_view } {
        return switch (k) {
            .uniform_buffer, .storage_buffer, .read_only_storage_buffer => .buffer,
            .sampler, .comparison_sampler => .sampler,
            else => .texture_view,
        };
    }

    pub fn describe(k: BindingKind) []const u8 {
        return switch (k) {
            .uniform_buffer => "uniform buffer",
            .storage_buffer => "read-write storage buffer",
            .read_only_storage_buffer => "read-only storage buffer",
            .sampler => "sampler",
            .comparison_sampler => "comparison sampler",
            .texture => "sampled texture",
            .depth_texture => "depth texture",
            .storage_texture => "storage texture",
            .external_texture => "external texture",
            .unknown => "unknown resource",
        };
    }

    fn fromLayoutEntry(e: sysgpu.BindGroupLayout.Entry) BindingKind {
        if (e.buffer.type != .undefined) return switch (e.buffer.type) {
            .uniform => .uniform_buffer,
            .storage => .storage_buffer,
            .read_only_storage => .read_only_storage_buffer,
            .undefined => unreachable,
        };
        if (e.sampler.type != .undefined) return if (e.sampler.type == .comparison) .comparison_sampler else .sampler;
        if (e.texture.sample_type != .undefined) return if (e.texture.sample_type == .depth) .depth_texture else .texture;
        if (e.storage_texture.access != .undefined) return .storage_texture;
        return .unknown;
    }

    /// Whether a shader binding of kind `shader_kind` accepts a layout entry of kind `layout_kind`.
    fn accepts(shader_kind: BindingKind, layout_kind: BindingKind) bool {
        if (shader_kind == layout_kind) return true;
        return switch (shader_kind) {
            .sampler => layout_kind == .sampler,
            // A depth texture may be bound with a float/unfilterable layout, and the other way.
            .depth_texture, .texture => layout_kind == .depth_texture or layout_kind == .texture,
            else => false,
        };
    }
};

pub const Stages = packed struct(u8) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _padding: u5 = 0,
};

/// A binding a bind group layout declares.
pub const LayoutEntry = struct {
    binding: u32,
    kind: BindingKind,
    visibility: Stages,
};

/// A resource variable a shader declares, from its reflection.
pub const ShaderBinding = struct {
    group: u32,
    binding: u32,
    kind: BindingKind,
    /// The stages whose entry points use it.
    visibility: Stages,
    name: Name,
};

pub const Name = struct {
    buf: [48]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) Name {
        var n: Name = .{};
        n.len = @intCast(@min(s.len, n.buf.len));
        @memcpy(n.buf[0..n.len], s[0..n.len]);
        return n;
    }

    pub fn initZ(s: ?[*:0]const u8) Name {
        return if (s) |z| init(std.mem.span(z)) else .{};
    }

    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

const trace_len = 6;
pub const Trace = [trace_len]usize;

pub const max_groups = 4;
const none: u32 = 0;

pub const Detail = union(enum) {
    none,
    buffer: struct { usage: sysgpu.Buffer.UsageFlags },
    texture: struct { width: u32, height: u32, depth: u32, format: sysgpu.Texture.Format, mips: u32, usage: sysgpu.Texture.UsageFlags },
    bind_group_layout: struct { entries: []LayoutEntry, hash: u64 },
    pipeline_layout: struct { groups: [max_groups]u32 = @splat(none), count: u8 = 0 },
    shader_module: struct { bindings: []ShaderBinding },
    render_pipeline: Pipeline,
    compute_pipeline: Pipeline,
    bind_group: struct { layout: u32 },
    pass: struct { pipeline: u32 = none, groups: [max_groups]u32 = @splat(none), problems: u8 = 0 },

    pub const Pipeline = struct {
        /// The pipeline layout's bind group layouts, or none for an automatic layout.
        groups: [max_groups]u32 = @splat(none),
        count: u8 = 0,
        auto_layout: bool = false,
    };
};

pub const Object = struct {
    /// Unique for the run of the program, never reused. 0 is no object.
    id: u32,
    ptr: usize,
    kind: Kind,
    label: Name,
    /// App-level references: 1 when acquired, +1 per `reference()`, -1 per `release()`.
    refs: i32 = 1,
    created_frame: u64,
    released_frame: ?u64 = null,
    create_trace: Trace,
    release_trace: Trace = @splat(0),
    /// Approximate GPU memory: buffer size, or texture size including mips.
    bytes: u64 = 0,
    /// Writes from the CPU (queue/encoder writeBuffer, writeTexture).
    uploads: u64 = 0,
    upload_bytes: u64 = 0,
    /// Times it was bound or drawn with, and the last frame it was.
    uses: u64 = 0,
    last_used_frame: u64 = 0,
    detail: Detail = .none,
};

pub const ProblemKind = enum(u8) {
    over_release,
    use_after_release,
    leak,
    bind_group_mismatch,
    layout_mismatch,
    missing_bind_group,
    incompatible_bind_group,
};

pub const Problem = struct {
    kind: ProblemKind,
    object: u32,
    /// How many times it happened (at this call site).
    count: u64 = 1,
    frame: u64,
    trace: Trace,
    message: [320]u8 = undefined,
    message_len: u16 = 0,
    hash: u64 = 0,

    pub fn text(p: *const Problem) []const u8 {
        return p.message[0..p.message_len];
    }
};

pub const Edge = struct {
    from: u32,
    to: u32,
    kind: RefKind,
    slot: u16 = 0,
};

pub const EdgeStat = struct { count: u64 = 0, last_frame: u64 = 0 };

/// Objects created at the same call site.
pub const Site = struct {
    kind: Kind,
    trace: Trace,
    created: u64 = 0,
    released: u64 = 0,
    live: u64 = 0,
};

const history_len = 1024;
const transient_history_len = 64;
const max_problems = 256;

const State = struct {
    mutex: std.atomic.Mutex = .unlocked,
    next_id: u32 = 1,
    frame: u64 = 0,
    live: std.AutoArrayHashMapUnmanaged(usize, Object) = .empty,
    /// Recently released objects, by pointer, to detect use after release and over-release.
    released_ptrs: std.AutoHashMapUnmanaged(usize, Object) = .empty,
    /// Recently released objects, oldest first, for lifetime timelines.
    history: Ring(history_len) = .{},
    transient_history: Ring(transient_history_len) = .{},
    edges: std.AutoArrayHashMapUnmanaged(Edge, EdgeStat) = .empty,
    sites: std.AutoArrayHashMapUnmanaged(usize, Site) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    symbols: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
    addr_symbols: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
    created_total: u64 = 0,
    released_total: u64 = 0,
};

fn Ring(comptime n: usize) type {
    return struct {
        items: [n]Object = undefined,
        start: usize = 0,
        len: usize = 0,

        /// Adds an object, returning the evicted one if full.
        fn push(r: *@This(), o: Object) ?Object {
            if (r.len < n) {
                r.items[(r.start + r.len) % n] = o;
                r.len += 1;
                return null;
            }
            const evicted = r.items[r.start];
            r.items[r.start] = o;
            r.start = (r.start + 1) % n;
            return evicted;
        }

        fn get(r: *const @This(), i: usize) *const Object {
            return &r.items[(r.start + i) % n];
        }
    };
}

var state: State = .{};
const allocator = std.heap.smp_allocator;

fn lock() void {
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlock() void {
    state.mutex.unlock();
}

/// The number of frames presented so far.
pub fn frame() u64 {
    return @atomicLoad(u64, &state.frame, .monotonic);
}

noinline fn captureTrace(first: usize) Trace {
    var out: Trace = @splat(0);
    out[0] = first;
    if (!std.options.allow_stack_tracing) return out;
    // `first` is the return address into the caller of a hook: the API call site. The rest of
    // the trace are its callers.
    var buf: [trace_len + 8]usize = @splat(0);
    const st = std.debug.captureCurrentStackTrace(.{}, &buf);
    const start = std.mem.indexOfScalar(usize, st.return_addresses, first) orelse return out;
    const rest = st.return_addresses[start + 1 ..];
    const n = @min(rest.len, trace_len - 1);
    @memcpy(out[1..][0..n], rest[0..n]);
    return out;
}

// ---------------------------------------------------------------------------------------------
// Hooks, called by sysgpu's API implementation.

/// A new object was acquired by the app (created, or returned by a getter which references it).
/// If `ptr` is already tracked as alive, the getter returned it again: counts as a reference.
pub noinline fn acquired(kind: Kind, ptr: *const anyopaque, label: ?[*:0]const u8, detail: Detail) void {
    if (!enabled) return;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    acquiredLocked(kind, @intFromPtr(ptr), Name.initZ(label), detail, trace);
}

fn acquiredLocked(kind: Kind, ptr: usize, label: Name, detail: Detail, trace: Trace) void {
    if (state.live.getPtr(ptr)) |o| {
        if (o.kind == kind) {
            o.refs += 1;
            freeDetail(detail);
            return;
        }
        // The pointer was reused for another object: the old one was freed by the backend
        // without the app releasing it (or we missed a release).
        retire(ptr);
    }
    _ = state.released_ptrs.remove(ptr);
    const id = state.next_id;
    state.next_id += 1;
    state.created_total += 1;
    var o: Object = .{
        .id = id,
        .ptr = ptr,
        .kind = kind,
        .label = label,
        .created_frame = state.frame,
        .create_trace = trace,
        .detail = detail,
    };
    switch (detail) {
        .texture => |t| o.bytes = textureBytes(t.width, t.height, t.depth, t.format, t.mips),
        else => {},
    }
    state.live.put(allocator, ptr, o) catch return;
    const site = state.sites.getOrPut(allocator, trace[0]) catch return;
    if (!site.found_existing) site.value_ptr.* = .{ .kind = kind, .trace = trace };
    site.value_ptr.created += 1;
    site.value_ptr.live += 1;
}

pub noinline fn setBytes(ptr: *const anyopaque, bytes: u64) void {
    if (!enabled) return;
    lock();
    defer unlock();
    if (state.live.getPtr(@intFromPtr(ptr))) |o| o.bytes = bytes;
}

pub noinline fn referenced(ptr: *const anyopaque) void {
    if (!enabled) return;
    const first = @returnAddress();
    lock();
    defer unlock();
    if (state.live.getPtr(@intFromPtr(ptr))) |o| {
        o.refs += 1;
    } else if (state.released_ptrs.getPtr(@intFromPtr(ptr))) |o| {
        problemLocked(.use_after_release, o.*, captureTrace(first), "reference() on {s} '{s}' which was already released", .{ @tagName(o.kind), o.label.slice() });
    }
}

/// The app released an object. Returns whether the backend should release it too: false for an
/// over-release, which would otherwise free the object twice.
pub noinline fn released(ptr: *const anyopaque) bool {
    if (!enabled) return true;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    const p = @intFromPtr(ptr);
    if (state.live.getPtr(p)) |o| {
        o.refs -= 1;
        if (o.refs > 0) return true;
        o.release_trace = trace;
        retire(p);
        return true;
    } else if (state.released_ptrs.getPtr(p)) |o| {
        problemLocked(.over_release, o.*, trace, "{s} '{s}' released more times than it was acquired/referenced (already released in frame {d}); this release was skipped", .{ @tagName(o.kind), o.label.slice(), o.released_frame orelse 0 });
        return false;
    }
    return true;
}

/// Moves a live object to the released history.
fn retire(ptr: usize) void {
    var entry = state.live.fetchSwapRemove(ptr) orelse return;
    var o = &entry.value;
    o.released_frame = state.frame;
    o.refs = 0;
    state.released_total += 1;
    if (state.sites.getPtr(o.create_trace[0])) |site| {
        site.released += 1;
        site.live -|= 1;
    }
    // Keep only light data for pointer lookups; the full object goes to the history.
    var light = o.*;
    light.detail = .none;
    if (state.released_ptrs.count() > 4 * history_len) state.released_ptrs.clearRetainingCapacity();
    state.released_ptrs.put(allocator, ptr, light) catch {};
    const ring_evicted = if (o.kind.isTransient()) state.transient_history.push(o.*) else state.history.push(o.*);
    if (ring_evicted) |evicted| {
        freeDetail(evicted.detail);
        removeEdgesOf(evicted.id);
    }
}

fn removeEdgesOf(id: u32) void {
    var i: usize = 0;
    while (i < state.edges.count()) {
        const e = state.edges.keys()[i];
        if (e.from == id or e.to == id) state.edges.swapRemoveAt(i) else i += 1;
    }
}

fn freeDetail(d: Detail) void {
    switch (d) {
        .bind_group_layout => |l| allocator.free(l.entries),
        .shader_module => |s| allocator.free(s.bindings),
        else => {},
    }
}

fn idOf(ptr: ?*const anyopaque) u32 {
    const p = ptr orelse return none;
    if (state.live.getPtr(@intFromPtr(p))) |o| return o.id;
    return none;
}

fn liveObject(ptr: ?*const anyopaque) ?*Object {
    const p = ptr orelse return null;
    return state.live.getPtr(@intFromPtr(p));
}

fn objectById(id: u32) ?*Object {
    if (id == none) return null;
    for (state.live.values()) |*o| if (o.id == id) return o;
    return null;
}

fn addEdgeLocked(from: u32, to: u32, kind: RefKind, slot: u16) void {
    if (from == none or to == none) return;
    const gop = state.edges.getOrPut(allocator, .{ .from = from, .to = to, .kind = kind, .slot = slot }) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.count += 1;
    gop.value_ptr.last_frame = state.frame;
}

/// Records that `from` refers to `to`.
pub noinline fn edge(from: ?*const anyopaque, to: ?*const anyopaque, kind: RefKind, slot: u16) void {
    if (!enabled) return;
    lock();
    defer unlock();
    addEdgeLocked(idOf(from), idOf(to), kind, slot);
}

/// Records a use of `ptr` (bound, drawn, submitted), reporting it if it was already released.
pub noinline fn used(ptr: ?*const anyopaque, what: []const u8) void {
    if (!enabled) return;
    const first = @returnAddress();
    lock();
    defer unlock();
    useLocked(ptr, what, first);
}

fn useLocked(ptr: ?*const anyopaque, what: []const u8, first: usize) void {
    const p = @intFromPtr(ptr orelse return);
    if (state.live.getPtr(p)) |o| {
        o.uses += 1;
        o.last_used_frame = state.frame;
    } else if (state.released_ptrs.getPtr(p)) |o| {
        problemLocked(.use_after_release, o.*, captureTrace(first), "{s}: {s} '{s}' was already released (in frame {d})", .{ what, @tagName(o.kind), o.label.slice(), o.released_frame orelse 0 });
    }
}

pub noinline fn uploaded(ptr: *const anyopaque, bytes: u64) void {
    if (!enabled) return;
    const first = @returnAddress();
    lock();
    defer unlock();
    useLocked(ptr, "upload", first);
    if (state.live.getPtr(@intFromPtr(ptr))) |o| {
        o.uploads += 1;
        o.upload_bytes += bytes;
    }
}

pub noinline fn presented() void {
    if (!enabled) return;
    _ = @atomicRmw(u64, &state.frame, .Add, 1, .monotonic);
}

// ---------------------------------------------------------------------------------------------
// Creation with relations and checks.

pub noinline fn bindGroupLayoutCreated(ptr: *const anyopaque, desc: *const sysgpu.BindGroupLayout.Descriptor) void {
    if (!enabled) return;
    const trace = captureTrace(@returnAddress());
    const src = if (desc.entries) |e| e[0..desc.entry_count] else &[_]sysgpu.BindGroupLayout.Entry{};
    const entries = allocator.alloc(LayoutEntry, src.len) catch return;
    var hasher = std.hash.Wyhash.init(0);
    for (src, entries) |s, *d| {
        d.* = .{ .binding = s.binding, .kind = BindingKind.fromLayoutEntry(s), .visibility = .{ .vertex = s.visibility.vertex, .fragment = s.visibility.fragment, .compute = s.visibility.compute } };
    }
    std.mem.sortUnstable(LayoutEntry, entries, {}, struct {
        fn lessThan(_: void, a: LayoutEntry, b: LayoutEntry) bool {
            return a.binding < b.binding;
        }
    }.lessThan);
    for (entries) |e| hasher.update(std.mem.asBytes(&e));
    lock();
    defer unlock();
    acquiredLocked(.bind_group_layout, @intFromPtr(ptr), Name.initZ(desc.label), .{ .bind_group_layout = .{ .entries = entries, .hash = hasher.final() } }, trace);
}

pub noinline fn pipelineLayoutCreated(ptr: *const anyopaque, desc: *const sysgpu.PipelineLayout.Descriptor) void {
    if (!enabled) return;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    const layouts = if (desc.bind_group_layouts) |l| l[0..desc.bind_group_layout_count] else &[_]*sysgpu.BindGroupLayout{};
    var detail: Detail = .{ .pipeline_layout = .{ .count = @intCast(@min(layouts.len, max_groups)) } };
    for (layouts[0..detail.pipeline_layout.count], 0..) |l, i| detail.pipeline_layout.groups[i] = idOf(l);
    acquiredLocked(.pipeline_layout, @intFromPtr(ptr), Name.initZ(desc.label), detail, trace);
    const id = idOf(ptr);
    for (layouts, 0..) |l, i| {
        useLocked(l, "createPipelineLayout", trace[0]);
        addEdgeLocked(id, idOf(l), .group_layout, @intCast(i));
    }
}

pub noinline fn shaderModuleCreated(ptr: *const anyopaque, label: ?[*:0]const u8, air: ?*const shader.Air) void {
    if (!enabled) return;
    const trace = captureTrace(@returnAddress());
    const bindings = if (air) |a| reflectAir(a) else &[_]ShaderBinding{};
    lock();
    defer unlock();
    acquiredLocked(.shader_module, @intFromPtr(ptr), Name.initZ(label), .{ .shader_module = .{ .bindings = @constCast(bindings) } }, trace);
}

/// Checks a bind group descriptor against its layout, before the backend creates it. Returns
/// false if the backend would fail or crash on it (problems were logged).
pub noinline fn checkBindGroup(desc: *const sysgpu.BindGroup.Descriptor) bool {
    if (!enabled) return true;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    // Not created yet: problems are attributed to it once it is, see `bindGroupCreated`.
    const group: Object = .{ .id = none, .ptr = 0, .kind = .bind_group, .label = Name.initZ(desc.label), .created_frame = state.frame, .create_trace = trace };
    var ok = true;
    const entries = if (desc.entries) |e| e[0..desc.entry_count] else &[_]sysgpu.BindGroup.Entry{};
    for (entries) |e| {
        const res: ?*const anyopaque = if (e.buffer) |b| b else if (e.sampler) |smp| smp else if (e.texture_view) |v| v else null;
        useLocked(res, "createBindGroup entry", trace[0]);
    }
    useLocked(desc.layout, "createBindGroup layout", trace[0]);
    const layout = liveObject(desc.layout) orelse return true;
    const layout_entries = switch (layout.detail) {
        .bind_group_layout => |l| l.entries,
        else => return true,
    };
    for (layout_entries) |le| {
        const e = for (entries) |e| {
            if (e.binding == le.binding) break e;
        } else {
            problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' has no entry for binding {d} ({s}) of its layout '{s}'", .{ group.label.slice(), le.binding, le.kind.describe(), layout.label.slice() });
            ok = false;
            continue;
        };
        const given: []const u8 = if (e.buffer != null) "buffer" else if (e.sampler != null) "sampler" else if (e.texture_view != null) "texture view" else "nothing";
        switch (le.kind.resourceType()) {
            .buffer => {
                const buf = e.buffer orelse {
                    problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' binding {d}: layout '{s}' expects a {s}, got a {s}", .{ group.label.slice(), le.binding, layout.label.slice(), le.kind.describe(), given });
                    ok = false;
                    continue;
                };
                const bo = liveObject(buf) orelse continue;
                const usage = switch (bo.detail) {
                    .buffer => |b| b.usage,
                    else => continue,
                };
                const usage_ok = if (le.kind == .uniform_buffer) usage.uniform else usage.storage;
                if (!usage_ok) problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' binding {d}: buffer '{s}' is bound as a {s} but wasn't created with .usage.{s} = true", .{ group.label.slice(), le.binding, bo.label.slice(), le.kind.describe(), if (le.kind == .uniform_buffer) "uniform" else "storage" });
                if (e.offset + e.size > bo.bytes and bo.bytes != 0 and e.size != sysgpu.whole_size) {
                    problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' binding {d}: binds {d} bytes at offset {d} of buffer '{s}', which is only {d} bytes", .{ group.label.slice(), le.binding, e.size, e.offset, bo.label.slice(), bo.bytes });
                }
            },
            .sampler => if (e.sampler == null) {
                problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' binding {d}: layout '{s}' expects a {s}, got a {s}", .{ group.label.slice(), le.binding, layout.label.slice(), le.kind.describe(), given });
                ok = false;
            },
            .texture_view => {
                const view = e.texture_view orelse {
                    problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' binding {d}: layout '{s}' expects a {s}, got a {s}", .{ group.label.slice(), le.binding, layout.label.slice(), le.kind.describe(), given });
                    ok = false;
                    continue;
                };
                const texture = textureOfView(view) orelse continue;
                const usage = switch (texture.detail) {
                    .texture => |t| t.usage,
                    else => continue,
                };
                const usage_ok = if (le.kind == .storage_texture) usage.storage_binding else usage.texture_binding;
                if (!usage_ok) problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' binding {d}: texture '{s}' is bound as a {s} but wasn't created with .usage.{s} = true", .{ group.label.slice(), le.binding, texture.label.slice(), le.kind.describe(), if (le.kind == .storage_texture) "storage_binding" else "texture_binding" });
            },
        }
    }
    for (entries) |e| {
        const known = for (layout_entries) |le| {
            if (le.binding == e.binding) break true;
        } else false;
        if (!known) problemLocked(.bind_group_mismatch, group, trace, "bind group '{s}' has an entry for binding {d}, which its layout '{s}' doesn't declare", .{ group.label.slice(), e.binding, layout.label.slice() });
    }
    return ok;
}

/// Attributes the problems found by a `check*` hook called from the same function (same caller
/// frame) to the object it then created.
fn adoptProblems(id: u32, trace: Trace) void {
    for (state.problems.items) |*p| {
        if (p.object == none and p.trace[1] == trace[1]) p.object = id;
    }
}

pub noinline fn bindGroupCreated(ptr: *const anyopaque, desc: *const sysgpu.BindGroup.Descriptor) void {
    if (!enabled) return;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    acquiredLocked(.bind_group, @intFromPtr(ptr), Name.initZ(desc.label), .{ .bind_group = .{ .layout = idOf(desc.layout) } }, trace);
    const id = idOf(ptr);
    adoptProblems(id, trace);
    addEdgeLocked(id, idOf(desc.layout), .layout, 0);
    const entries = if (desc.entries) |e| e[0..desc.entry_count] else &[_]sysgpu.BindGroup.Entry{};
    for (entries) |e| {
        const res: ?*const anyopaque = if (e.buffer) |b| b else if (e.sampler) |smp| smp else if (e.texture_view) |v| v else null;
        addEdgeLocked(id, idOf(res), .resource, @intCast(e.binding));
    }
}

fn textureOfView(view: *const anyopaque) ?*Object {
    const view_id = idOf(view);
    for (state.edges.keys()) |e| {
        if (e.from == view_id and e.kind == .view_of) return objectById(e.to);
    }
    return null;
}

/// Checks that a pipeline's layout provides every binding its shaders use (from their
/// reflection), before the backend creates it. Returns false if the backend would fail on it
/// (problems were logged).
pub noinline fn checkPipeline(
    kind: Kind,
    label: ?[*:0]const u8,
    layout: ?*const sysgpu.PipelineLayout,
    stages: []const ?*const sysgpu.ShaderModule,
) bool {
    if (!enabled) return true;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    useLocked(layout, "createPipeline layout", trace[0]);
    for (stages) |stage| useLocked(stage, "createPipeline shader", trace[0]);
    if (layout == null) return true; // automatic layout
    const pl = liveObject(layout) orelse return true;
    const groups, const count = switch (pl.detail) {
        .pipeline_layout => |d| .{ d.groups, d.count },
        else => return true,
    };
    const pipeline: Object = .{ .id = none, .ptr = 0, .kind = kind, .label = Name.initZ(label), .created_frame = state.frame, .create_trace = trace };
    var ok = true;
    for (stages) |stage| {
        const module = liveObject(stage) orelse continue;
        const bindings = switch (module.detail) {
            .shader_module => |sm| sm.bindings,
            else => continue,
        };
        for (bindings) |b| {
            if (!b.visibility.vertex and !b.visibility.fragment and !b.visibility.compute) continue;
            if (b.group >= count) {
                problemLocked(.layout_mismatch, pipeline, trace, "pipeline '{s}': shader '{s}' uses @group({d}) @binding({d}) `{s}` ({s}), but its pipeline layout '{s}' has only {d} bind group layout(s)", .{ pipeline.label.slice(), module.label.slice(), b.group, b.binding, b.name.slice(), b.kind.describe(), pl.label.slice(), count });
                ok = false;
                continue;
            }
            const bgl = objectById(groups[b.group]) orelse continue;
            const entries = switch (bgl.detail) {
                .bind_group_layout => |l| l.entries,
                else => continue,
            };
            const le = for (entries) |le| {
                if (le.binding == b.binding) break le;
            } else {
                problemLocked(.layout_mismatch, pipeline, trace, "pipeline '{s}': shader '{s}' uses @group({d}) @binding({d}) `{s}` ({s}), but @group({d})'s bind group layout '{s}' has no entry {d}", .{ pipeline.label.slice(), module.label.slice(), b.group, b.binding, b.name.slice(), b.kind.describe(), b.group, bgl.label.slice(), b.binding });
                ok = false;
                continue;
            };
            if (!b.kind.accepts(le.kind)) {
                problemLocked(.layout_mismatch, pipeline, trace, "pipeline '{s}': shader '{s}' declares @group({d}) @binding({d}) `{s}` as a {s}, but bind group layout '{s}' entry {d} is a {s}", .{ pipeline.label.slice(), module.label.slice(), b.group, b.binding, b.name.slice(), b.kind.describe(), bgl.label.slice(), b.binding, le.kind.describe() });
                ok = false;
                continue;
            }
            const missing_vertex = b.visibility.vertex and !le.visibility.vertex;
            const missing_fragment = b.visibility.fragment and !le.visibility.fragment;
            const missing_compute = b.visibility.compute and !le.visibility.compute;
            if (missing_vertex or missing_fragment or missing_compute) {
                problemLocked(.layout_mismatch, pipeline, trace, "pipeline '{s}': shader '{s}' uses `{s}` (@group({d}) @binding({d})) in the {s} stage, but bind group layout '{s}' entry {d} isn't visible to it", .{ pipeline.label.slice(), module.label.slice(), b.name.slice(), b.group, b.binding, if (missing_vertex) "vertex" else if (missing_fragment) "fragment" else "compute", bgl.label.slice(), b.binding });
            }
        }
    }
    return ok;
}

/// A render or compute pipeline was created: records its relations.
pub noinline fn pipelineCreated(
    kind: Kind,
    ptr: *const anyopaque,
    label: ?[*:0]const u8,
    layout: ?*const sysgpu.PipelineLayout,
    stages: []const ?*const sysgpu.ShaderModule,
) void {
    if (!enabled) return;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    var p: Detail.Pipeline = .{ .auto_layout = layout == null };
    if (liveObject(layout)) |l| switch (l.detail) {
        .pipeline_layout => |pl| {
            p.groups = pl.groups;
            p.count = pl.count;
        },
        else => {},
    };
    acquiredLocked(kind, @intFromPtr(ptr), Name.initZ(label), if (kind == .compute_pipeline) .{ .compute_pipeline = p } else .{ .render_pipeline = p }, trace);
    const id = idOf(ptr);
    adoptProblems(id, trace);
    addEdgeLocked(id, idOf(layout), .layout, 0);
    for (stages, 0..) |stage, i| {
        addEdgeLocked(id, idOf(stage), .shader, @intCast(i));
    }
}

pub noinline fn passBegan(kind: Kind, pass: *const anyopaque, encoder: *const anyopaque, label: ?[*:0]const u8, attachments: []const ?*const anyopaque) void {
    if (!enabled) return;
    const trace = captureTrace(@returnAddress());
    lock();
    defer unlock();
    acquiredLocked(kind, @intFromPtr(pass), Name.initZ(label), .{ .pass = .{} }, trace);
    const id = idOf(pass);
    useLocked(encoder, "beginPass", trace[0]);
    addEdgeLocked(id, idOf(encoder), .encoder, 0);
    for (attachments, 0..) |a, i| {
        useLocked(a, "render pass attachment", trace[0]);
        addEdgeLocked(id, idOf(a), .attachment, @intCast(if (i == attachments.len - 1 and kind == .render_pass_encoder) 255 else i));
    }
}

pub noinline fn passSetPipeline(pass: *const anyopaque, pipeline: *const anyopaque) void {
    if (!enabled) return;
    const first = @returnAddress();
    lock();
    defer unlock();
    useLocked(pipeline, "setPipeline", first);
    const p = liveObject(pass) orelse return;
    switch (p.detail) {
        .pass => |*s| s.pipeline = idOf(pipeline),
        else => {},
    }
}

pub noinline fn passSetBindGroup(pass: *const anyopaque, index: u32, group: *const anyopaque) void {
    if (!enabled) return;
    const first = @returnAddress();
    lock();
    defer unlock();
    useLocked(group, "setBindGroup", first);
    const p = liveObject(pass) orelse return;
    switch (p.detail) {
        .pass => |*s| if (index < max_groups) {
            s.groups[index] = idOf(group);
        },
        else => {},
    }
}

pub noinline fn passSetBuffer(pass: *const anyopaque, buffer: *const anyopaque, kind: RefKind, slot: u32) void {
    if (!enabled) return;
    const first = @returnAddress();
    lock();
    defer unlock();
    useLocked(buffer, "set vertex/index buffer", first);
    const p = liveObject(pass) orelse return;
    switch (p.detail) {
        .pass => |s| addEdgeLocked(s.pipeline, idOf(buffer), kind, @intCast(slot)),
        else => {},
    }
}

/// A draw or dispatch: checks the bound bind groups against the pipeline's layout.
pub noinline fn passDraw(pass: *const anyopaque) void {
    if (!enabled) return;
    const first = @returnAddress();
    lock();
    defer unlock();
    const p = liveObject(pass) orelse return;
    const s = switch (p.detail) {
        .pass => |*s| s,
        else => return,
    };
    const pipeline = objectById(s.pipeline) orelse return;
    pipeline.uses += 1;
    pipeline.last_used_frame = state.frame;
    const pl = switch (pipeline.detail) {
        .render_pipeline, .compute_pipeline => |pl| pl,
        else => return,
    };
    for (0..pl.count) |i| {
        const group = objectById(s.groups[i]) orelse {
            if (s.problems < 4) {
                s.problems += 1;
                problemLocked(.missing_bind_group, pipeline.*, captureTrace(first), "draw with pipeline '{s}' without a bind group at @group({d}), which its layout declares", .{ pipeline.label.slice(), i });
            }
            continue;
        };
        group.uses += 1;
        group.last_used_frame = state.frame;
        addEdgeLocked(pipeline.id, group.id, .draws_with, @intCast(i));
        const have = switch (group.detail) {
            .bind_group => |g| g.layout,
            else => continue,
        };
        const want = pl.groups[i];
        if (have == want or have == none or want == none) continue;
        const have_layout = objectById(have) orelse continue;
        const want_layout = objectById(want) orelse continue;
        const same = switch (have_layout.detail) {
            .bind_group_layout => |h| switch (want_layout.detail) {
                .bind_group_layout => |w| h.hash == w.hash,
                else => true,
            },
            else => true,
        };
        if (!same and s.problems < 4) {
            s.problems += 1;
            problemLocked(.incompatible_bind_group, group.*, captureTrace(first), "draw with pipeline '{s}': bind group '{s}' at @group({d}) has layout '{s}', but the pipeline expects layout '{s}', and their entries differ", .{ pipeline.label.slice(), group.label.slice(), i, have_layout.label.slice(), want_layout.label.slice() });
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Problems

fn problemLocked(kind: ProblemKind, object: Object, trace: Trace, comptime fmt: []const u8, args: anytype) void {
    // One problem per kind and call site.
    var p: Problem = .{ .kind = kind, .object = object.id, .frame = state.frame, .trace = trace };
    var w: std.Io.Writer = .fixed(&p.message);
    w.print(fmt, args) catch {};
    p.message_len = @intCast(w.end);
    p.hash = std.hash.Wyhash.hash(trace[0], p.text());
    // One problem per call site and message.
    for (state.problems.items) |*existing| {
        if (existing.kind == kind and existing.hash == p.hash) {
            existing.count += 1;
            existing.frame = state.frame;
            return;
        }
    }
    if (state.problems.items.len >= max_problems) return;
    state.problems.append(allocator, p) catch return;

    // Log it with the source locations involved.
    const at = symbolizeLocked(trace);
    const created = symbolizeLocked(object.create_trace);
    if (kind == .over_release or kind == .use_after_release) {
        const rel = symbolizeLocked(object.release_trace);
        log.err("{s}: {s}\n  at {s}\n  created at {s}\n  released at {s}", .{ @tagName(kind), p.text(), at, created, rel });
    } else if (kind == .leak) {
        log.err("{s}: {s}\n  created at {s}", .{ @tagName(kind), p.text(), created });
    } else if (object.id == none) {
        log.err("{s}: {s}\n  at {s}", .{ @tagName(kind), p.text(), at });
    } else {
        log.err("{s}: {s}\n  at {s}\n  ({s} created at {s})", .{ @tagName(kind), p.text(), at, @tagName(object.kind), created });
    }
}

/// Logs objects which are still alive, grouped by the code which created them. Called when a
/// device's last app reference is released, and at any time to find leaks.
pub fn report() void {
    if (!enabled) return;
    lock();
    defer unlock();
    reportLocked();
}

fn reportLocked() void {
    var leaked: u64 = 0;
    for (state.sites.values()) |site| {
        if (site.live == 0) continue;
        switch (site.kind) {
            .instance, .adapter, .device, .queue, .surface, .swap_chain => continue,
            else => {},
        }
        leaked += site.live;
        const o = for (state.live.values()) |o| {
            if (o.create_trace[0] == site.trace[0]) break o;
        } else continue;
        problemLocked(.leak, o, site.trace, "{d} {s}(s) never released, e.g. '{s}' (created {d}, released {d} at this site)", .{ site.live, @tagName(site.kind), o.label.slice(), site.created, site.released });
    }
    if (leaked > 0) log.err("{d} GPU object(s) leaked, see above", .{leaked});
}

pub noinline fn deviceReleased(ptr: *const anyopaque) bool {
    if (!enabled) return true;
    lock();
    const o = state.live.get(@intFromPtr(ptr));
    unlock();
    const last = if (o) |d| d.refs <= 1 else false;
    const forward = released(ptr);
    if (last) report();
    return forward;
}

// ---------------------------------------------------------------------------------------------
// Symbols

/// Resolves the first frame of `trace` outside of sysgpu to "file:line: function", followed by
/// its caller, cached.
fn symbolizeLocked(trace: Trace) []const u8 {
    if (trace[0] == 0) return "(unknown)";
    const key = trace[0] ^ (trace[1] *% 0x9e3779b97f4a7c15);
    if (state.symbols.get(key)) |s| return s;
    const site = symbolizeAddr(trace[0]);
    const s = if (trace[1] != 0)
        std.fmt.allocPrint(allocator, "{s} (from {s})", .{ site, symbolizeAddr(trace[1]) }) catch site
    else
        site;
    state.symbols.put(allocator, key, s) catch {};
    return s;
}

fn inSysgpu(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "sysgpu" ++ std.fs.path.sep_str) != null;
}

fn inStd(s: []const u8) bool {
    return std.mem.indexOf(u8, s, std.fs.path.sep_str ++ "std" ++ std.fs.path.sep_str) != null;
}

fn symbolizeAddr(addr: usize) []const u8 {
    if (state.addr_symbols.get(addr)) |s| return s;
    // A hook's return address is inside sysgpu's inline API wrappers, which the debug info only
    // resolves to their innermost frame. Look around it for the caller's code: first before the
    // wrapper (evaluating its arguments, the same statement), else after it returns (best effort).
    var s = resolveAddr(addr -| 1) catch "(unknown)";
    if (inSysgpu(s) or inStd(s)) {
        const inside = s;
        var offset: usize = 4;
        while (offset <= 16 * 1024) : (offset += 4) {
            const before = resolveAddr(addr -| offset) catch break;
            if (!inSysgpu(before) and !inStd(before)) {
                s = before;
                break;
            }
        }
        if (s.ptr == inside.ptr) {
            offset = 0;
            while ((inSysgpu(s) or inStd(s)) and offset <= 16 * 1024) : (offset += 4) {
                s = resolveAddr(addr + offset) catch break;
            }
        }
    }
    state.addr_symbols.put(allocator, addr, s) catch {};
    return s;
}

fn resolveAddr(addr: usize) ![]const u8 {
    const di = std.debug.getSelfDebugInfo() catch return error.Unavailable;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    di.getSymbols(std.Options.debug_io, arena.allocator(), arena.allocator(), addr -| 1, true, &symbols) catch return error.Unavailable;
    // Inline frames come innermost first: skip those in sysgpu's API wrappers.
    var best: ?std.debug.Symbol = null;
    for (symbols.items) |sym| {
        const loc = sym.source_location orelse continue;
        best = sym;
        if (std.mem.indexOf(u8, loc.file_name, "sysgpu" ++ std.fs.path.sep_str) == null) break;
    }
    const sym = best orelse return error.Unavailable;
    const loc = sym.source_location.?;
    return std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ relativePath(loc.file_name), loc.line, sym.name orelse "?" });
}

fn relativePath(path: []const u8) []const u8 {
    // Shorten absolute paths to start at src/, examples/, etc. when possible.
    inline for (.{ "/src/", "/examples/", "/editor/", "/tools/" }) |marker| {
        if (std.mem.lastIndexOf(u8, path, marker)) |i| return path[i + 1 ..];
    }
    return path;
}

fn textureBytes(width: u32, height: u32, depth: u32, format: sysgpu.Texture.Format, mips: u32) u64 {
    const bpp: u64 = switch (format) {
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint, .stencil8 => 1,
        .r16_uint, .r16_sint, .r16_float, .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint, .depth16_unorm => 2,
        .rgba16_uint, .rgba16_sint, .rgba16_float, .rg32_float, .rg32_uint, .rg32_sint => 8,
        .rgba32_float, .rgba32_uint, .rgba32_sint => 16,
        else => 4,
    };
    const base = @as(u64, width) * height * @max(depth, 1) * bpp;
    // A full mip chain adds about a third.
    return if (mips > 1) base + base / 3 else base;
}

// ---------------------------------------------------------------------------------------------
// Shader reflection from sysgpu's shader IR

fn reflectAir(air: *const shader.Air) []ShaderBinding {
    var out: std.ArrayList(ShaderBinding) = .empty;
    const globals = air.refToList(air.globals_index);
    for (globals) |inst_idx| {
        const v = switch (air.getInst(inst_idx)) {
            .@"var" => |v| v,
            else => continue,
        };
        if (v.group == .none or v.binding == .none) continue;
        const group = air.resolveInt(v.group) orelse continue;
        const binding = air.resolveInt(v.binding) orelse continue;
        const kind: BindingKind = switch (v.addr_space) {
            .uniform => .uniform_buffer,
            .storage => if (v.access_mode == .read) .read_only_storage_buffer else .storage_buffer,
            else => switch (air.getInst(v.type)) {
                .sampler_type => .sampler,
                .comparison_sampler_type => .comparison_sampler,
                .external_texture_type => .external_texture,
                .texture_type => |t| switch (t.kind) {
                    .storage_1d, .storage_2d, .storage_2d_array, .storage_3d => .storage_texture,
                    .depth_2d, .depth_2d_array, .depth_cube, .depth_cube_array, .multisampled_depth_2d => .depth_texture,
                    else => .texture,
                },
                else => .unknown,
            },
        };
        var vis: Stages = .{};
        for (globals) |fn_idx| {
            const f = switch (air.getInst(fn_idx)) {
                .@"fn" => |f| f,
                else => continue,
            };
            if (f.stage == .none) continue;
            const uses = for (air.refToList(f.global_var_refs)) |r| {
                if (r == inst_idx) break true;
            } else false;
            if (!uses) continue;
            switch (f.stage) {
                .vertex => vis.vertex = true,
                .fragment => vis.fragment = true,
                .compute => vis.compute = true,
                .none => {},
            }
        }
        out.append(allocator, .{
            .group = @intCast(group),
            .binding = @intCast(binding),
            .kind = kind,
            .visibility = vis,
            .name = Name.init(air.getStr(v.name)),
        }) catch break;
    }
    return out.toOwnedSlice(allocator) catch &.{};
}

// ---------------------------------------------------------------------------------------------
// Export

/// Writes the tracked objects, relations, call sites and problems as JSON (an object with
/// `frame`, `objects`, `edges`, `sites` and `problems`), for the inspector.
pub fn writeJson(w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!enabled) return w.writeAll("{\"enabled\":false}");
    lock();
    defer unlock();
    try w.print("{{\"enabled\":true,\"frame\":{d},\"created_total\":{d},\"released_total\":{d},\"objects\":[", .{ state.frame, state.created_total, state.released_total });
    var first = true;
    for (state.live.values()) |*o| {
        try writeObject(w, o, &first);
    }
    for (0..state.history.len) |i| try writeObject(w, state.history.get(i), &first);
    for (0..state.transient_history.len) |i| try writeObject(w, state.transient_history.get(i), &first);
    try w.writeAll("],\"edges\":[");
    first = true;
    for (state.edges.keys(), state.edges.values()) |e, s| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"from\":{d},\"to\":{d},\"kind\":\"{s}\",\"slot\":{d},\"count\":{d},\"last_frame\":{d}}}", .{ e.from, e.to, @tagName(e.kind), e.slot, s.count, s.last_frame });
    }
    try w.writeAll("],\"sites\":[");
    first = true;
    for (state.sites.values()) |s| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"kind\":\"{s}\",\"created\":{d},\"released\":{d},\"live\":{d},\"at\":", .{ @tagName(s.kind), s.created, s.released, s.live });
        try writeString(w, symbolizeLocked(s.trace));
        try w.writeAll("}");
    }
    try w.writeAll("],\"problems\":[");
    first = true;
    for (state.problems.items) |*p| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"kind\":\"{s}\",\"object\":{d},\"count\":{d},\"frame\":{d},\"message\":", .{ @tagName(p.kind), p.object, p.count, p.frame });
        try writeString(w, p.text());
        try w.writeAll(",\"at\":");
        try writeString(w, symbolizeLocked(p.trace));
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeObject(w: *std.Io.Writer, o: *const Object, first: *bool) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.print("{{\"id\":{d},\"ptr\":{d},\"kind\":\"{s}\",\"label\":", .{ o.id, o.ptr, @tagName(o.kind) });
    try writeString(w, o.label.slice());
    try w.print(",\"refs\":{d},\"created_frame\":{d},\"released_frame\":", .{ o.refs, o.created_frame });
    if (o.released_frame) |f| try w.print("{d}", .{f}) else try w.writeAll("null");
    try w.print(",\"bytes\":{d},\"uploads\":{d},\"upload_bytes\":{d},\"uses\":{d},\"last_used_frame\":{d},\"created_at\":", .{ o.bytes, o.uploads, o.upload_bytes, o.uses, o.last_used_frame });
    try writeString(w, symbolizeLocked(o.create_trace));
    try w.writeAll(",\"released_at\":");
    if (o.released_frame != null) try writeString(w, symbolizeLocked(o.release_trace)) else try w.writeAll("null");
    try w.writeAll(",\"detail\":");
    switch (o.detail) {
        .none, .pass => try w.writeAll("null"),
        .buffer => |b| try w.print("{{\"usage\":{d}}}", .{@as(u32, @bitCast(b.usage))}),
        .texture => |t| try w.print("{{\"width\":{d},\"height\":{d},\"depth\":{d},\"format\":\"{s}\",\"mips\":{d}}}", .{ t.width, t.height, t.depth, @tagName(t.format), t.mips }),
        .bind_group_layout => |l| {
            try w.writeAll("{\"entries\":[");
            for (l.entries, 0..) |e, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"binding\":{d},\"kind\":\"{s}\",\"vertex\":{},\"fragment\":{},\"compute\":{}}}", .{ e.binding, @tagName(e.kind), e.visibility.vertex, e.visibility.fragment, e.visibility.compute });
            }
            try w.writeAll("]}");
        },
        .shader_module => |s| {
            try w.writeAll("{\"bindings\":[");
            for (s.bindings, 0..) |b, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"group\":{d},\"binding\":{d},\"kind\":\"{s}\",\"vertex\":{},\"fragment\":{},\"compute\":{},\"name\":", .{ b.group, b.binding, @tagName(b.kind), b.visibility.vertex, b.visibility.fragment, b.visibility.compute });
                try writeString(w, b.name.slice());
                try w.writeAll("}");
            }
            try w.writeAll("]}");
        },
        .pipeline_layout => |pl| try w.print("{{\"groups\":{d}}}", .{pl.count}),
        .render_pipeline, .compute_pipeline => |p| try w.print("{{\"groups\":{d},\"auto_layout\":{}}}", .{ p.count, p.auto_layout }),
        .bind_group => |g| try w.print("{{\"layout\":{d}}}", .{g.layout}),
    }
    try w.writeAll("}");
}

pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
