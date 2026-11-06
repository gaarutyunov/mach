//! Minimal metrics: counters, gauges and histograms in the Prometheus data model.
//!
//! A metric is a plain value you embed in your own struct, with no registry, allocation or locks.
//! Every operation is a few relaxed atomic operations, so metrics can be updated from hot paths
//! and read from any thread:
//!
//! ```
//! const Metrics = struct {
//!     requests_total: metrics.Counter = .{},
//!     queue_depth: metrics.Gauge = .{},
//!     latency_ns: metrics.Histogram(&.{ 1_000, 10_000, 100_000 }) = .{},
//! };
//! var m: Metrics = .{};
//! m.requests_total.inc();
//! m.latency_ns.observe(4_200);
//! try metrics.write(writer, "app_", &m);
//! ```
//!
//! Each metric is individually consistent, but they are not synchronized with each other or with
//! surrounding memory: a reader may see one metric updated before another. Don't use them to
//! coordinate threads.
const std = @import("std");

/// A value that only goes up, e.g. the number of allocations so far.
pub const Counter = struct {
    value: std.atomic.Value(u64) = .init(0),

    pub fn inc(c: *Counter) void {
        c.add(1);
    }

    pub fn add(c: *Counter, n: u64) void {
        _ = c.value.fetchAdd(n, .monotonic);
    }

    pub fn load(c: *const Counter) u64 {
        return c.value.load(.monotonic);
    }

    fn writeTo(c: *const Counter, w: *std.Io.Writer, prefix: []const u8, name: []const u8) std.Io.Writer.Error!void {
        try w.print("# TYPE {s}{s} counter\n{s}{s} {d}\n", .{ prefix, name, prefix, name, c.load() });
    }
};

/// A value that goes up and down, e.g. bytes currently in use.
pub const Gauge = struct {
    value: std.atomic.Value(i64) = .init(0),

    pub fn init(value: i64) Gauge {
        return .{ .value = .init(value) };
    }

    pub fn set(g: *Gauge, value: i64) void {
        g.value.store(value, .monotonic);
    }

    pub fn add(g: *Gauge, n: i64) void {
        _ = g.value.fetchAdd(n, .monotonic);
    }

    pub fn sub(g: *Gauge, n: i64) void {
        _ = g.value.fetchSub(n, .monotonic);
    }

    /// Raises the gauge to `value` if it is lower, e.g. to track a peak.
    pub fn setMax(g: *Gauge, value: i64) void {
        _ = g.value.fetchMax(value, .monotonic);
    }

    pub fn load(g: *const Gauge) i64 {
        return g.value.load(.monotonic);
    }

    /// Loads a gauge that is never negative, e.g. a size in bytes.
    pub fn loadUsize(g: *const Gauge) usize {
        return @intCast(g.load());
    }

    fn writeTo(g: *const Gauge, w: *std.Io.Writer, prefix: []const u8, name: []const u8) std.Io.Writer.Error!void {
        try w.print("# TYPE {s}{s} gauge\n{s}{s} {d}\n", .{ prefix, name, prefix, name, g.load() });
    }
};

/// A distribution of values over fixed buckets, given by their ascending inclusive upper bounds.
/// Values above the last bound go in an implicit overflow bucket (`+Inf`).
pub fn Histogram(comptime bounds: []const u64) type {
    comptime {
        std.debug.assert(bounds.len > 0);
        for (bounds[1..], bounds[0 .. bounds.len - 1]) |bound, previous| std.debug.assert(bound > previous);
    }
    const num_buckets = bounds.len + 1;

    return struct {
        const Self = @This();

        /// Per-bucket (not cumulative) counts.
        counts: [num_buckets]std.atomic.Value(u64) = @splat(.init(0)),
        sum: std.atomic.Value(u64) = .init(0),

        /// A copy of a histogram's values, see `snapshot`.
        pub const Snapshot = struct {
            counts: [num_buckets]u64 = @splat(0),
            sum: u64 = 0,

            /// The number of observed values.
            pub fn count(s: Snapshot) u64 {
                var total: u64 = 0;
                for (s.counts) |c| total += c;
                return total;
            }

            /// What was observed after `earlier`, a snapshot of the same histogram, to look at a
            /// recent window rather than the whole lifetime.
            pub fn since(s: Snapshot, earlier: Snapshot) Snapshot {
                var result: Snapshot = .{ .sum = s.sum -% earlier.sum };
                for (&result.counts, s.counts, earlier.counts) |*r, now, then| r.* = now -% then;
                return result;
            }

            /// An upper bound for the `q` quantile (0 to 1), which is as precise as the buckets
            /// are. Null if there are no values. As in Prometheus, if the quantile falls in the
            /// overflow bucket this returns the highest bound, the most that is known.
            pub fn quantile(s: Snapshot, q: f64) ?u64 {
                const total = s.count();
                if (total == 0) return null;
                const rank: u64 = @intFromFloat(@ceil(std.math.clamp(q, 0, 1) * @as(f64, @floatFromInt(total))));
                var cumulative: u64 = 0;
                for (s.counts[0..bounds.len], bounds) |c, bound| {
                    cumulative += c;
                    if (cumulative >= @max(rank, 1)) return bound;
                }
                return bounds[bounds.len - 1];
            }
        };

        pub fn observe(h: *Self, value: u64) void {
            _ = h.sum.fetchAdd(value, .monotonic);
            _ = h.counts[bucketIndex(value)].fetchAdd(1, .monotonic);
        }

        pub fn snapshot(h: *const Self) Snapshot {
            var result: Snapshot = .{ .sum = h.sum.load(.monotonic) };
            for (&result.counts, &h.counts) |*r, *c| r.* = c.load(.monotonic);
            return result;
        }

        fn bucketIndex(value: u64) usize {
            for (bounds, 0..) |bound, i| {
                if (value <= bound) return i;
            }
            return bounds.len;
        }

        fn writeTo(h: *const Self, w: *std.Io.Writer, prefix: []const u8, name: []const u8) std.Io.Writer.Error!void {
            const s = h.snapshot();
            try w.print("# TYPE {s}{s} histogram\n", .{ prefix, name });
            var cumulative: u64 = 0;
            for (s.counts[0..bounds.len], bounds) |c, bound| {
                cumulative += c;
                try w.print("{s}{s}_bucket{{le=\"{d}\"}} {d}\n", .{ prefix, name, bound, cumulative });
            }
            cumulative += s.counts[bounds.len];
            try w.print("{s}{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ prefix, name, cumulative });
            try w.print("{s}{s}_sum {d}\n", .{ prefix, name, s.sum });
            try w.print("{s}{s}_count {d}\n", .{ prefix, name, cumulative });
        }
    };
}

/// Wraps an allocator, recording what goes through it. Only allocations made through the wrapper
/// are counted. Must not be moved once `allocator()` has been called.
pub const MeteredAllocator = struct {
    parent: std.mem.Allocator,
    metrics: Metrics = .{},

    pub const Metrics = struct {
        /// Bytes currently allocated, as requested by callers.
        used_bytes: Gauge = .{},
        /// Peak value of `used_bytes`.
        peak_bytes: Gauge = .{},
        /// Number of successful allocations and frees so far.
        allocs_total: Counter = .{},
        frees_total: Counter = .{},
        /// Number of allocations the parent allocator failed.
        failed_allocs_total: Counter = .{},
    };

    pub const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn allocator(m: *MeteredAllocator) std.mem.Allocator {
        return .{ .ptr = m, .vtable = &vtable };
    }

    /// Records a change in size. Raises the peak from this thread's own result, so concurrent
    /// updates can't make it miss a value.
    fn addUsed(m: *MeteredAllocator, delta: i64) void {
        const used = m.metrics.used_bytes.value.fetchAdd(delta, .monotonic) + delta;
        m.metrics.peak_bytes.setMax(used);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const m: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        const result = m.parent.rawAlloc(len, alignment, ra) orelse {
            m.metrics.failed_allocs_total.inc();
            return null;
        };
        m.addUsed(@intCast(len));
        m.metrics.allocs_total.inc();
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const m: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        if (!m.parent.rawResize(memory, alignment, new_len, ra)) return false;
        m.addUsed(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const m: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        const result = m.parent.rawRemap(memory, alignment, new_len, ra) orelse return null;
        m.addUsed(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const m: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        m.parent.rawFree(memory, alignment, ra);
        m.metrics.used_bytes.sub(@intCast(memory.len));
        m.metrics.frees_total.inc();
    }
};

/// Writes every metric in `set`, a pointer to a struct whose fields are all metrics, in the
/// Prometheus text format. Each metric is named `prefix` followed by its field's name, so together
/// they must form valid and unique Prometheus metric names.
pub fn write(w: *std.Io.Writer, prefix: []const u8, set: anytype) std.Io.Writer.Error!void {
    const Set = @typeInfo(@TypeOf(set)).pointer.child;
    inline for (@typeInfo(Set).@"struct".field_names) |name| {
        try @field(set, name).writeTo(w, prefix, name);
    }
}

test "counter and gauge" {
    var c: Counter = .{};
    c.inc();
    c.add(2);
    try std.testing.expectEqual(3, c.load());

    var g: Gauge = .init(5);
    g.add(10);
    g.sub(20);
    try std.testing.expectEqual(-5, g.load());
    g.setMax(7);
    g.setMax(3);
    try std.testing.expectEqual(7, g.load());
    g.set(1);
    try std.testing.expectEqual(1, g.load());
}

test "histogram buckets are inclusive, with an overflow bucket" {
    var h: Histogram(&.{ 10, 100 }) = .{};
    h.observe(0);
    h.observe(10);
    h.observe(11);
    h.observe(101);
    const s = h.snapshot();
    try std.testing.expectEqualSlices(u64, &.{ 2, 1, 1 }, &s.counts);
    try std.testing.expectEqual(122, s.sum);
    try std.testing.expectEqual(4, s.count());
}

test "histogram quantile" {
    var h: Histogram(&.{ 10, 100, 1000 }) = .{};
    try std.testing.expectEqual(null, h.snapshot().quantile(0.5));

    for (0..90) |_| h.observe(5);
    for (0..9) |_| h.observe(50);
    h.observe(500);
    const s = h.snapshot();
    try std.testing.expectEqual(10, s.quantile(0).?);
    try std.testing.expectEqual(10, s.quantile(0.5).?);
    try std.testing.expectEqual(10, s.quantile(0.9).?);
    try std.testing.expectEqual(100, s.quantile(0.95).?);
    try std.testing.expectEqual(1000, s.quantile(1).?);

    // The overflow bucket reports the highest bound.
    for (0..1000) |_| h.observe(5000);
    try std.testing.expectEqual(1000, h.snapshot().quantile(0.99).?);
}

test "histogram snapshot since an earlier one" {
    var h: Histogram(&.{ 10, 100 }) = .{};
    h.observe(5);
    const earlier = h.snapshot();
    h.observe(50);
    h.observe(60);
    const window = h.snapshot().since(earlier);
    try std.testing.expectEqualSlices(u64, &.{ 0, 2, 0 }, &window.counts);
    try std.testing.expectEqual(110, window.sum);
    try std.testing.expectEqual(100, window.quantile(0.5).?);
}

test "write uses the Prometheus text format" {
    var set: struct {
        allocs_total: Counter = .{},
        used_bytes: Gauge = .{},
        time_ns: Histogram(&.{ 10, 100 }) = .{},
    } = .{};
    set.allocs_total.add(3);
    set.used_bytes.set(-4);
    set.time_ns.observe(5);
    set.time_ns.observe(50);
    set.time_ns.observe(500);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, "app_", &set);
    try std.testing.expectEqualStrings(
        \\# TYPE app_allocs_total counter
        \\app_allocs_total 3
        \\# TYPE app_used_bytes gauge
        \\app_used_bytes -4
        \\# TYPE app_time_ns histogram
        \\app_time_ns_bucket{le="10"} 1
        \\app_time_ns_bucket{le="100"} 2
        \\app_time_ns_bucket{le="+Inf"} 3
        \\app_time_ns_sum 555
        \\app_time_ns_count 3
        \\
    , w.buffered());
}

test "MeteredAllocator records usage" {
    var metered: MeteredAllocator = .{ .parent = std.testing.allocator };
    const a = metered.allocator();

    const x = try a.alloc(u8, 100);
    const y = try a.alloc(u8, 50);
    try std.testing.expectEqual(150, metered.metrics.used_bytes.load());
    a.free(x);
    try std.testing.expectEqual(50, metered.metrics.used_bytes.load());
    try std.testing.expectEqual(150, metered.metrics.peak_bytes.load());
    try std.testing.expectEqual(2, metered.metrics.allocs_total.load());
    try std.testing.expectEqual(1, metered.metrics.frees_total.load());
    a.free(y);
    try std.testing.expectEqual(0, metered.metrics.used_bytes.load());

    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var metered_failing: MeteredAllocator = .{ .parent = failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, metered_failing.allocator().alloc(u8, 1));
    try std.testing.expectEqual(1, metered_failing.metrics.failed_allocs_total.load());
    try std.testing.expectEqual(0, metered_failing.metrics.used_bytes.load());
}

test "MeteredAllocator conformance" {
    var metered: MeteredAllocator = .{ .parent = std.testing.allocator };
    try std.heap.testAllocator(metered.allocator());
    try std.heap.testAllocatorAligned(metered.allocator());
    try std.heap.testAllocatorLargeAlignment(metered.allocator());
    try std.heap.testAllocatorAlignedShrink(metered.allocator());
    try std.testing.expectEqual(0, metered.metrics.used_bytes.load());
}

test "concurrent updates are not lost" {
    const num_threads = 8;
    const num_updates = 100_000;
    const Set = struct {
        counter: Counter = .{},
        gauge: Gauge = .{},
        peak: Gauge = .{},
        histogram: Histogram(&.{ 1, 2 }) = .{},

        fn run(set: *@This(), thread: usize) void {
            for (0..num_updates) |i| {
                set.counter.inc();
                // Each thread's increments and decrements cancel out.
                if (i % 2 == 0) set.gauge.add(3) else set.gauge.sub(3);
                set.peak.setMax(@intCast(thread * num_updates + i));
                set.histogram.observe(thread % 3);
            }
        }
    };
    var set: Set = .{};
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Set.run, .{ &set, i });
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(num_threads * num_updates, set.counter.load());
    try std.testing.expectEqual(0, set.gauge.load());
    try std.testing.expectEqual((num_threads - 1) * num_updates + num_updates - 1, set.peak.load());
    const s = set.histogram.snapshot();
    try std.testing.expectEqual(num_threads * num_updates, s.count());
    // Threads observe 0,1,2,0,1,2,0,1: 3 of value 0 (bucket 0) and 3 of 1 (bucket 0), 2 of 2.
    try std.testing.expectEqualSlices(u64, &.{ 6 * num_updates, 2 * num_updates, 0 }, &s.counts);
    try std.testing.expectEqual((3 + 2 * 2) * num_updates, s.sum);
}
