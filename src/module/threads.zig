//! Records what each thread does, for the inspector's thread views: which systems it runs (and
//! when), which `mach.Objects` lists those systems access, and which locks were held meanwhile (the
//! list's own lock, and `mach.Core`'s render lock which the app thread holds while it snapshots a
//! frame and the render thread while it renders). A list accessed by several threads without a
//! lock common to all accesses is a likely data race.
//!
//! Only with `-Dinspector`, once recording was started (see `dataflow.start`).
const std = @import("std");
const build_options = @import("build-options");
const dataflow = @import("dataflow.zig");

pub const enabled = build_options.inspector;

const max_threads = 16;
/// (system, list) pairs recorded per thread.
const max_accesses = 256;
/// System runs kept per thread, for the timeline.
const max_spans = 2048;

pub const Access = struct {
    system: []const u8 = "",
    /// The list's address: render copies share their original's type ID.
    list: usize = 0,
    used: bool = false,
    reads: u64 = 0,
    writes: u64 = 0,
    /// Accesses with the list's own lock held (by this thread).
    own_lock: u64 = 0,
    /// Accesses with `mach.Core`'s render lock held (by this thread).
    render_lock: u64 = 0,
    /// Writes with the list's own lock, or the render lock, held.
    write_own_lock: u64 = 0,
    write_render_lock: u64 = 0,
    /// When the first and last of these accesses happened (the start of the system run they
    /// happened in), or 0 outside of systems: accesses which never overlap in time can't race.
    first_ns: i96 = 0,
    last_ns: i96 = 0,
};

pub const Span = struct {
    system: []const u8,
    start_ns: i96,
    end_ns: i96,
    depth: u8,
};

const Thread = struct {
    id: std.Thread.Id,
    name_buf: [24]u8 = undefined,
    name_len: u8 = 0,
    accesses: [max_accesses]Access = @splat(.{}),
    dropped_accesses: u64 = 0,
    spans: [max_spans]Span = undefined,
    span_next: usize = 0,
    span_count: usize = 0,
};

var threads: [max_threads]Thread = undefined;
var num_threads: std.atomic.Value(usize) = .init(0);
var register_mutex: std.atomic.Mutex = .unlocked;

threadlocal var me: ?*Thread = null;
/// The lists whose lock this thread holds (a list appears once per lock depth).
threadlocal var held: [32]usize = @splat(0);
threadlocal var held_len: u8 = 0;
threadlocal var render_lock_depth: u8 = 0;
threadlocal var span_depth: u8 = 0;
/// The start of the system run on this thread, 0 outside of systems.
threadlocal var span_start_ns: i96 = 0;
/// The latest start of a system run on any thread: the approximate time of accesses outside of
/// systems (e.g. by mach.Core's render loop), without reading the clock on every access.
var latest_span_ns: std.atomic.Value(i64) = .init(0);

fn current() ?*Thread {
    if (me) |t| return t;
    while (!register_mutex.tryLock()) std.atomic.spinLoopHint();
    defer register_mutex.unlock();
    const n = num_threads.load(.acquire);
    if (n == max_threads) return null;
    threads[n] = .{ .id = std.Thread.getCurrentId() };
    const t = &threads[n];
    const name = std.fmt.bufPrint(&t.name_buf, "thread {d}", .{n}) catch "";
    t.name_len = @intCast(name.len);
    num_threads.store(n + 1, .release);
    me = t;
    return t;
}

/// Names the calling thread, e.g. "app" or "render".
pub fn setName(name: []const u8) void {
    if (!enabled) return;
    const t = current() orelse return;
    const len = @min(name.len, t.name_buf.len);
    @memcpy(t.name_buf[0..len], name[0..len]);
    t.name_len = @intCast(len);
}

/// A `mach.Objects` list was read or written by the calling thread.
pub fn listAccess(list: *const anyopaque, write: bool) void {
    if (!enabled or !dataflow.isRecording()) return;
    const t = current() orelse return;
    const system = dataflow.current_system;
    // Open addressing on (system, list); system names are comptime strings, so their pointers
    // identify them.
    const list_addr = @intFromPtr(list);
    const hash = (@intFromPtr(system.ptr) >> 3) ^ (list_addr *% 0x9e3779b1);
    var i = hash % max_accesses;
    var probes: usize = 0;
    while (probes < max_accesses) : (probes += 1) {
        const a = &t.accesses[i];
        if (!a.used) {
            a.* = .{ .system = system, .list = list_addr, .used = true };
        }
        if (a.system.ptr == system.ptr and a.list == list_addr) {
            if (write) a.writes += 1 else a.reads += 1;
            const when: i96 = if (span_start_ns != 0) span_start_ns else latest_span_ns.load(.monotonic);
            if (a.first_ns == 0) a.first_ns = when;
            a.last_ns = when;
            const own = std.mem.indexOfScalar(usize, held[0..held_len], list_addr) != null;
            if (own) a.own_lock += 1;
            if (render_lock_depth > 0) a.render_lock += 1;
            if (write and own) a.write_own_lock += 1;
            if (write and render_lock_depth > 0) a.write_render_lock += 1;
            return;
        }
        i = (i + 1) % max_accesses;
    }
    t.dropped_accesses += 1;
}

pub fn listLocked(list: *const anyopaque) void {
    if (!enabled or held_len == held.len) return;
    held[held_len] = @intFromPtr(list);
    held_len += 1;
}

pub fn listUnlocked(list: *const anyopaque) void {
    if (!enabled) return;
    const i = std.mem.lastIndexOfScalar(usize, held[0..held_len], @intFromPtr(list)) orelse return;
    held[i] = held[held_len - 1];
    held_len -= 1;
}

/// `mach.Core`'s render lock was acquired (true) or released (false) by the calling thread.
pub fn renderLock(acquired: bool) void {
    if (!enabled) return;
    if (acquired) render_lock_depth +|= 1 else render_lock_depth -|= 1;
}

/// Begins a system's run on the calling thread, returning its start time, see `systemEnd`.
pub fn systemBegin(io: std.Io) SystemRun {
    if (!enabled or !dataflow.isRecording()) return .{};
    span_depth +|= 1;
    const run: SystemRun = .{ .start_ns = std.Io.Timestamp.now(io, .awake).nanoseconds, .outer_start_ns = span_start_ns };
    span_start_ns = run.start_ns;
    _ = latest_span_ns.fetchMax(@intCast(run.start_ns), .monotonic);
    return run;
}

pub const SystemRun = struct { start_ns: i96 = 0, outer_start_ns: i96 = 0 };

pub fn systemEnd(io: std.Io, system: []const u8, run: SystemRun) void {
    if (!enabled or run.start_ns == 0) return;
    const start_ns = run.start_ns;
    span_start_ns = run.outer_start_ns;
    span_depth -|= 1;
    const t = current() orelse return;
    t.spans[t.span_next] = .{
        .system = system,
        .start_ns = start_ns,
        .end_ns = std.Io.Timestamp.now(io, .awake).nanoseconds,
        .depth = span_depth,
    };
    t.span_next = (t.span_next + 1) % max_spans;
    t.span_count = @min(t.span_count + 1, max_spans);
}

/// Writes the recorded threads as a JSON array. Counters are read without synchronization: they
/// are statistics, slightly stale values are fine.
pub fn writeJson(w: *std.Io.Writer, writeString: anytype, io: std.Io) std.Io.Writer.Error!void {
    if (!enabled) return w.writeAll("[]");
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    try w.writeAll("[");
    const n = num_threads.load(.acquire);
    for (threads[0..n], 0..) |*t, ti| {
        if (ti > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeString(w, t.name_buf[0..t.name_len]);
        try w.print(",\"dropped_accesses\":{d},\"accesses\":[", .{t.dropped_accesses});
        var first = true;
        for (&t.accesses) |*a| {
            if (!a.used) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"system\":");
            try writeString(w, a.system);
            const first_us: i96 = if (a.first_ns == 0) -1 else @divTrunc(now - a.first_ns, 1000);
            const last_us: i96 = if (a.last_ns == 0) -1 else @divTrunc(now - a.last_ns, 1000);
            try w.print(",\"list\":{d},\"reads\":{d},\"writes\":{d},\"own_lock\":{d},\"render_lock\":{d}", .{ a.list, a.reads, a.writes, a.own_lock, a.render_lock });
            try w.print(",\"write_own_lock\":{d},\"write_render_lock\":{d},\"first_us\":{d},\"last_us\":{d}}}", .{ a.write_own_lock, a.write_render_lock, first_us, last_us });
        }
        try w.writeAll("],\"spans\":[");
        // Oldest first, times in microseconds before the snapshot.
        const start = (t.span_next + max_spans - t.span_count) % max_spans;
        for (0..t.span_count) |k| {
            const s = t.spans[(start + k) % max_spans];
            if (k > 0) try w.writeAll(",");
            try w.writeAll("{\"system\":");
            try writeString(w, s.system);
            try w.print(",\"start_us\":{d},\"end_us\":{d},\"depth\":{d}}}", .{
                @divTrunc(now - s.start_ns, 1000), @divTrunc(now - s.end_ns, 1000), s.depth,
            });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}
