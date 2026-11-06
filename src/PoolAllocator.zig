//! A fixed-budget, thread-safe allocator over a preallocated buffer.
//!
//! - Small allocations (<= 64 KiB) are rounded up to a power-of-two size class and bump-allocated
//!   from the bottom of the buffer. Freed blocks go on a per-class free list for reuse.
//! - Large allocations are rounded up to 64 KiB and allocated first-fit from the top of the
//!   buffer, growing down. Freed large blocks are coalesced with free neighbors, so space from
//!   e.g. a freed music track can be reused by a differently sized one.
//!
//! Nothing is returned to the OS, and allocating past the budget fails with `error.OutOfMemory`
//! instead of growing. Size the budget from `report()`'s high-water mark.
//!
//! Usually you don't create these directly: give modules budgets via `Modules.initOptions` and
//! Mach creates a pool per module from one block reserved up front:
//!
//! ```
//! try mods.initOptions(gpa, io, .{ .budgets = .{ .app = 32 * mib, .mach_audio = 128 * mib } });
//! // ... later, e.g. on exit: log each pool's usage and high-water mark.
//! mods.reportMemory();
//! ```
const PoolAllocator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const dvx_metrics = @import("dvx/metrics.zig");

name: []const u8,
buffer: []u8,
io: std.Io,
mutex: std.Io.Mutex = .init,

/// Small allocations: everything below `bottom` has been handed out at some point.
bottom: usize = 0,
free_lists: [num_classes]?*FreeNode = @splat(null),

/// Large allocations: everything at or above `top` has been handed out at some point (or is
/// alignment padding at the very end of the buffer).
top: usize,
/// Free large extents within [top, buffer.len), sorted by offset, never adjacent (coalesced).
free_extents: [max_free_extents]Extent = undefined,
num_free_extents: usize = 0,

/// Usage of the pool, readable from any thread without taking `mutex`.
metrics: Metrics,
/// Set once the first allocation fails, so we only log it once.
exhausted: bool = false,

const min_class_log2 = 4;
const large_granularity = 64 * 1024;
const num_classes = std.math.log2_int(usize, large_granularity) - min_class_log2 + 1;
const max_free_extents = 64;

const FreeNode = struct { next: ?*FreeNode };
const Extent = struct { offset: usize, len: usize };

const log = std.log.scoped(.mach_pool_allocator);

pub fn init(name: []const u8, buffer: []u8, io: std.Io) PoolAllocator {
    return .{
        .name = name,
        .buffer = buffer,
        .io = io,
        .top = buffer.len,
        .metrics = .{ .budget_bytes = .init(@intCast(buffer.len)) },
    };
}

pub fn allocator(pool: *PoolAllocator) Allocator {
    return .{ .ptr = pool, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

/// A pool's usage, see `mach.dvx.metrics`.
pub const Metrics = struct {
    /// Bytes currently allocated (including rounding).
    used_bytes: dvx_metrics.Gauge = .{},
    /// Peak value of `used_bytes`.
    peak_bytes: dvx_metrics.Gauge = .{},
    /// Size of the pool.
    budget_bytes: dvx_metrics.Gauge,
    /// Bytes of the pool ever handed out (and so possibly committed by the OS), including blocks
    /// since freed and alignment padding. `used_bytes` can't exceed this; budget beyond it is
    /// unused.
    touched_bytes: dvx_metrics.Gauge = .{},
    /// Number of successful allocations and frees so far.
    allocs_total: dvx_metrics.Counter = .{},
    frees_total: dvx_metrics.Counter = .{},
    /// Number of allocations that failed for lack of space.
    failed_allocs_total: dvx_metrics.Counter = .{},
};

/// Updates `metrics.touched_bytes` after `bottom` or `top` may have moved.
fn updateTouched(pool: *PoolAllocator) void {
    pool.metrics.touched_bytes.set(@intCast(pool.bottom + (pool.buffer.len - pool.top)));
}

/// Logs current usage, high-water mark and budget.
pub fn report(pool: *PoolAllocator) void {
    log.info("{s}: used {Bi:.1}, high-water {Bi:.1} of {Bi:.1} budget", .{
        pool.name, pool.metrics.used_bytes.loadUsize(), pool.metrics.peak_bytes.loadUsize(), pool.buffer.len,
    });
}

/// The rounded size of an allocation, which determines whether it is small or large.
fn blockSize(len: usize, alignment: Alignment) usize {
    const size = @max(len, alignment.toByteUnits(), 1 << min_class_log2);
    if (size <= large_granularity) return std.math.ceilPowerOfTwoAssert(usize, size);
    return std.mem.alignForward(usize, size, large_granularity);
}

fn classIndex(size: usize) usize {
    return std.math.log2_int(usize, size) - min_class_log2;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    _ = ra;
    const pool: *PoolAllocator = @ptrCast(@alignCast(ctx));
    // Blocks are aligned to min(size, large_granularity).
    if (alignment.toByteUnits() > large_granularity) return null;

    pool.mutex.lockUncancelable(pool.io);
    defer pool.mutex.unlock(pool.io);

    // Checked before blockSize, which would overflow rounding up a huge len.
    if (len > pool.buffer.len) return pool.outOfMemory(len);
    const size = blockSize(len, alignment);

    const offset = (if (size <= large_granularity) pool.allocSmall(size) else pool.allocLarge(size)) orelse
        return pool.outOfMemory(size);
    pool.metrics.used_bytes.add(@intCast(size));
    pool.metrics.peak_bytes.setMax(pool.metrics.used_bytes.load());
    pool.metrics.allocs_total.inc();
    pool.updateTouched();
    return pool.buffer.ptr + offset;
}

fn allocSmall(pool: *PoolAllocator, size: usize) ?usize {
    const index = classIndex(size);
    if (pool.free_lists[index]) |node| {
        pool.free_lists[index] = node.next;
        return @intFromPtr(node) - @intFromPtr(pool.buffer.ptr);
    }
    const base = @intFromPtr(pool.buffer.ptr);
    const start = std.mem.alignForward(usize, base + pool.bottom, size) - base;
    if (start + size > pool.top) return null;
    pool.bottom = start + size;
    return start;
}

fn allocLarge(pool: *PoolAllocator, size: usize) ?usize {
    // First fit among freed extents, taking from the extent's start.
    for (pool.free_extents[0..pool.num_free_extents], 0..) |*extent, i| {
        if (extent.len < size) continue;
        const offset = extent.offset;
        extent.offset += size;
        extent.len -= size;
        if (extent.len == 0) pool.removeExtent(i);
        return offset;
    }
    // Otherwise grow the large region down, keeping blocks large_granularity-aligned.
    const base = @intFromPtr(pool.buffer.ptr);
    if (pool.top < size) return null;
    const start = std.mem.alignBackward(usize, base + pool.top - size, large_granularity);
    if (start < base + pool.bottom) return null;
    pool.top = start - base;
    return pool.top;
}

fn outOfMemory(pool: *PoolAllocator, size: usize) ?[*]u8 {
    pool.metrics.failed_allocs_total.inc();
    if (!pool.exhausted) {
        pool.exhausted = true;
        log.warn("{s}: out of memory allocating {Bi:.1} (used {Bi:.1} of {Bi:.1} budget)", .{
            pool.name, size, pool.metrics.used_bytes.loadUsize(), pool.buffer.len,
        });
    }
    return null;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
    _ = ctx;
    _ = ra;
    // In place only if the rounded block size doesn't change.
    return blockSize(new_len, alignment) == blockSize(memory.len, alignment);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
    _ = ra;
    const pool: *PoolAllocator = @ptrCast(@alignCast(ctx));
    const size = blockSize(memory.len, alignment);
    const offset = @intFromPtr(memory.ptr) - @intFromPtr(pool.buffer.ptr);

    pool.mutex.lockUncancelable(pool.io);
    defer pool.mutex.unlock(pool.io);

    pool.metrics.used_bytes.sub(@intCast(size));
    pool.metrics.frees_total.inc();
    if (size <= large_granularity) {
        const index = classIndex(size);
        const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
        node.* = .{ .next = pool.free_lists[index] };
        pool.free_lists[index] = node;
    } else {
        pool.freeLarge(.{ .offset = offset, .len = size });
        pool.updateTouched();
    }
}

fn freeLarge(pool: *PoolAllocator, freed: Extent) void {
    var extent = freed;
    const extents = pool.free_extents[0..pool.num_free_extents];

    // Find the insertion point, keeping extents sorted by offset.
    var i: usize = 0;
    while (i < extents.len and extents[i].offset < extent.offset) i += 1;

    // Coalesce with the following extent.
    if (i < pool.num_free_extents and extent.offset + extent.len == pool.free_extents[i].offset) {
        extent.len += pool.free_extents[i].len;
        pool.removeExtent(i);
    }
    // Coalesce with the preceding extent.
    if (i > 0 and pool.free_extents[i - 1].offset + pool.free_extents[i - 1].len == extent.offset) {
        i -= 1;
        extent.offset = pool.free_extents[i].offset;
        extent.len += pool.free_extents[i].len;
        pool.removeExtent(i);
    }
    // If it borders the top of the large region, give it back to the region instead.
    if (extent.offset == pool.top) {
        pool.top += extent.len;
        return;
    }
    if (pool.num_free_extents == max_free_extents) {
        log.warn("{s}: too many free extents, leaking {Bi:.1} of budget", .{ pool.name, extent.len });
        return;
    }
    std.mem.copyBackwards(Extent, pool.free_extents[i + 1 .. pool.num_free_extents + 1], pool.free_extents[i..pool.num_free_extents]);
    pool.free_extents[i] = extent;
    pool.num_free_extents += 1;
}

fn removeExtent(pool: *PoolAllocator, i: usize) void {
    std.mem.copyForwards(Extent, pool.free_extents[i .. pool.num_free_extents - 1], pool.free_extents[i + 1 .. pool.num_free_extents]);
    pool.num_free_extents -= 1;
}

test "small allocations reuse freed blocks of the same class" {
    var buffer: [4096]u8 align(16) = undefined;
    var pool = PoolAllocator.init("test", &buffer, std.testing.io);
    const a = pool.allocator();

    const x = try a.alloc(u8, 100); // 128-byte class
    const y = try a.alloc(u64, 3); // 32-byte class
    try std.testing.expectEqual(@as(usize, 160), pool.metrics.used_bytes.loadUsize());

    a.free(x);
    const z = try a.alloc(u8, 120); // same class, reuses x's block
    try std.testing.expectEqual(x.ptr, z.ptr);
    try std.testing.expectEqual(@as(usize, 160), pool.metrics.peak_bytes.loadUsize());

    // Growing within the size class happens in place.
    try std.testing.expect(a.resize(z, 128));
    try std.testing.expect(!a.resize(z, 129));

    pool.exhausted = true; // silence the expected out-of-memory warning
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 8192));
    a.free(z);
    a.free(y);
    try std.testing.expectEqual(@as(usize, 0), pool.metrics.used_bytes.loadUsize());
}

test "large allocations coalesce and are reused across sizes" {
    const mib = 1024 * 1024;
    const buffer = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(large_granularity), 8 * mib);
    defer std.testing.allocator.free(buffer);
    var pool = PoolAllocator.init("test", buffer, std.testing.io);
    const a = pool.allocator();

    const x = try a.alloc(u8, 3 * mib);
    const y = try a.alloc(u8, 3 * mib);
    pool.exhausted = true; // silence the expected out-of-memory warning
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 3 * mib));

    // Freeing two adjacent blocks yields one extent big enough for a larger allocation.
    a.free(x);
    a.free(y);
    try std.testing.expectEqual(@as(usize, 0), pool.metrics.used_bytes.loadUsize());
    const z = try a.alloc(u8, 6 * mib);
    const small = try a.alloc(u8, 100);
    a.free(small);
    a.free(z);
    try std.testing.expectEqual(@as(usize, 0), pool.metrics.used_bytes.loadUsize());
    try std.testing.expectEqual(@as(usize, 0), pool.num_free_extents);

    // Out-of-order frees in the middle coalesce too.
    const p = try a.alloc(u8, 1 * mib);
    const q = try a.alloc(u8, 1 * mib);
    const r = try a.alloc(u8, 1 * mib);
    a.free(q);
    try std.testing.expectEqual(@as(usize, 1), pool.num_free_extents);
    a.free(r); // r is lowest (top of region), so q+r return to the region
    try std.testing.expectEqual(@as(usize, 0), pool.num_free_extents);
    a.free(p);
    try std.testing.expectEqual(@as(usize, 0), pool.metrics.used_bytes.loadUsize());
}

test "std.heap.testAllocator conformance" {
    const buffer = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(buffer);
    var pool = PoolAllocator.init("test", buffer, std.testing.io);
    try std.heap.testAllocator(pool.allocator());
    try std.heap.testAllocatorAligned(pool.allocator());
    try std.heap.testAllocatorLargeAlignment(pool.allocator());
}
