//! Per-module context given to systems which declare a `mach.Context` parameter:
//!
//! ```
//! pub fn init(app: *App, ctx: mach.Context) !void {
//!     app.items = try std.ArrayList(Item).initCapacity(ctx.allocator, 64);
//!     ctx.info("reserved {d} items", .{app.items.capacity});
//! }
//! ```
//!
//! Logging through the context uses the module name as the `std.log` scope (so it can be
//! filtered per module with `std_options.log_scope_levels`) and prefixes the running system:
//!
//! ```
//! info(app): [init] reserved 64 items
//! ```
//!
//! When built with `-Dtracy`, every system run is a Tracy zone named `module.system`, each
//! module's allocator is tracked as a named Tracy memory pool, and context log messages are
//! also sent to Tracy (colored by level).
const std = @import("std");
const module = @import("../module.zig");
const PoolAllocator = @import("../PoolAllocator.zig");
const dvx_metrics = @import("../dvx/metrics.zig");
const ScheduleContext = @import("ScheduleContext.zig");

const Context = @This();

/// This module's allocator: its pool if it has a budget (`InitOptions.budgets`), its override
/// (`InitOptions.allocators`), or else the global allocator passed to `Modules.init`.
/// With `-Dtracy`, wrapped in a `tracy.TracingAllocator` named after the module.
allocator: std.mem.Allocator,

io: std.Io,

/// This module's memory pool, if it was given a budget in `InitOptions.budgets`.
pool: ?*PoolAllocator,

/// The name of the module whose system is running, e.g. "mach_gfx_sprite".
module_name: []const u8,

/// The name of the system being run, e.g. "init". Empty for a context obtained outside of a
/// system via `Modules.context()`.
system_name: []const u8 = "",

/// Values shared between the systems of the running schedule. See `ScheduleContext`.
schedule: ScheduleContext = .{},

_modules: *anyopaque,
_report_memory: *const fn (modules: *anyopaque) void,
_memory_stats: *const fn (modules: *anyopaque, out: []ModuleMemory) []ModuleMemory,
_log: *const fn (level: std.log.Level, system_name: []const u8, msg: []const u8) void,
_log_enabled: *const fn (level: std.log.Level) bool,

/// Logs usage and high-water mark of every module's memory pool.
pub fn reportMemory(ctx: Context) void {
    ctx._report_memory(ctx._modules);
}

/// Fills `out` with a memory snapshot of every module (up to `out.len` of them) and returns
/// the filled part. Lock-free, so it can be called from any thread, e.g. every frame.
pub fn memoryStats(ctx: Context, out: []ModuleMemory) []ModuleMemory {
    return ctx._memory_stats(ctx._modules, out);
}

/// Messages longer than this are truncated.
pub const max_log_len = 1024;

/// Logs a message scoped to this module and prefixed with the running system's name.
pub fn log(ctx: Context, comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
    if (!ctx._log_enabled(level)) return;
    var buf: [max_log_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(format, args) catch {};
    ctx._log(level, ctx.system_name, w.buffered());
}

pub fn err(ctx: Context, comptime format: []const u8, args: anytype) void {
    ctx.log(.err, format, args);
}

pub fn warn(ctx: Context, comptime format: []const u8, args: anytype) void {
    ctx.log(.warn, format, args);
}

pub fn info(ctx: Context, comptime format: []const u8, args: anytype) void {
    ctx.log(.info, format, args);
}

pub fn debug(ctx: Context, comptime format: []const u8, args: anytype) void {
    ctx.log(.debug, format, args);
}

/// A module's memory usage, see `Context.memoryStats`. Usage reads as zero without `-Dmetrics`.
pub const ModuleMemory = struct {
    /// The module's name, e.g. "mach_gfx_sprite".
    name: []const u8,
    /// What the module allocated: from its pool, or from its override or the global allocator.
    /// In the latter case, allocations made by others from the same allocator aren't included.
    usage: *const dvx_metrics.AllocatorMetrics,
    /// The module's pool, or null if it has no budget (`InitOptions.budgets`).
    pool: ?*const PoolAllocator,
};
