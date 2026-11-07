//! Tracy zones and plots of modules, systems and schedules (with `-Dtracy`).
const std = @import("std");
const tracy = @import("tracy");
const build_options = @import("build-options");
const module = @import("../module.zig");
const schedule = @import("schedule.zig").schedule;
const isScheduleDecl = @import("schedule.zig").isScheduleDecl;

/// Tracy zone colors (with `-Dtracy`), to tell schedules and their parts apart from systems.
pub const colors = struct {
    pub const schedule = 0x4a7fb5;
    pub const finalize = 0x9a6a2e;
    pub const finalizer = 0xc89a5a;
};

/// Name of the Tracy plot of a module's pool usage. A type, so the name has one address: Tracy
/// identifies plots by pointer.
pub fn MemoryPlot(comptime module_name: []const u8) type {
    return struct {
        pub const name: [:0]const u8 = std.fmt.comptimePrint("mem {s}", .{module_name});
    };
}

/// The Tracy zone of a system or schedule. Its source location is the system's (or the schedule's
/// declaration), so that Tracy's source view shows its code, rather than where it's called from.
/// Resolved from debug info the first time it runs, see `resolveTraceLocation`.
pub fn SystemTrace(comptime M: type, comptime fn_name: []const u8, comptime debug_name: [:0]const u8) type {
    return struct {
        const is_schedule = isScheduleDecl(@TypeOf(@field(M, fn_name)));

        /// Without file and line until resolved, or if there is no debug info.
        var src_loc: tracy.SourceLocation = .{
            .name = debug_name.ptr,
            .function = @typeName(M) ++ "." ++ fn_name,
            .file = null,
            .line = 0,
            .color = if (is_schedule) colors.schedule else 0,
        };
        var resolved: std.atomic.Value(bool) = .init(false);

        pub inline fn begin() @TypeOf(tracy.initZoneAt(&src_loc, .{})) {
            if (!build_options.tracy) return tracy.initZoneAt(&src_loc, .{});
            if (!resolved.load(.acquire)) resolve();
            return tracy.initZoneAt(&src_loc, .{});
        }

        fn resolve() void {
            @branchHint(.cold);
            trace_resolve_lock.lock();
            defer trace_resolve_lock.unlock();
            if (resolved.load(.monotonic)) return;
            defer resolved.store(true, .release);

            // A schedule has no code: find a function of its module for the file, and then its
            // declaration in there.
            const address = @intFromPtr(&@field(M, if (is_schedule) anyModuleFunction(M) orelse return else fn_name));
            const location = resolveTraceLocation(address, if (is_schedule) fn_name else null) orelse return;
            src_loc.file = location.file;
            src_loc.line = location.line;
        }
    };
}

/// The name of any function of the module, or null if it has none.
fn anyModuleFunction(comptime M: type) ?[]const u8 {
    for (M.mach_systems) |system| {
        if (@typeInfo(@TypeOf(@field(M, @tagName(system)))) == .@"fn") return @tagName(system);
    }
    return null;
}

/// Serializes resolving trace locations, since `std.debug.SelfInfo` isn't thread-safe.
var trace_resolve_lock: struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(l: *@This()) void {
        while (l.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(l: *@This()) void {
        l.locked.store(false, .release);
    }
} = .{};

/// Looks up the source file and line of the function at `address` in the debug info. With
/// `decl_name`, finds the line of `const <decl_name> =` in that file instead. Results live forever,
/// since Tracy may read them at any time. Only used with `-Dtracy`, once per system.
fn resolveTraceLocation(address: usize, decl_name: ?[]const u8) ?struct { file: [*:0]const u8, line: u32 } {
    const S = struct {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    };
    const allocator = S.arena.allocator();
    const io = std.Options.debug_io;
    const debug_info = std.debug.getSelfDebugInfo() catch return null;
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    debug_info.getSymbols(io, allocator, allocator, address, false, &symbols) catch return null;
    if (symbols.items.len == 0) return null;
    const location = symbols.items[0].source_location orelse return null;
    const file = allocator.dupeSentinel(u8, location.file_name, 0) catch return null;

    const name = decl_name orelse return .{ .file = file, .line = @intCast(location.line) };
    const source = std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(16 * 1024 * 1024)) catch return null;
    // The file may declare several of that name (e.g. in different structs): take the one closest
    // to the module's function.
    const fn_line: u32 = @intCast(location.line);
    var best: ?u32 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line: u32 = 1;
    while (lines.next()) |text| : (line += 1) {
        const trimmed = std.mem.trimStart(u8, text, " ");
        const decl = if (std.mem.startsWith(u8, trimmed, "pub ")) trimmed["pub ".len..] else trimmed;
        if (!std.mem.startsWith(u8, decl, "const ")) continue;
        const rest = decl["const ".len..];
        if (!std.mem.startsWith(u8, rest, name) or !std.mem.startsWith(u8, std.mem.trimStart(u8, rest[name.len..], " "), "=")) continue;
        if (best == null or @abs(@as(i64, line) - fn_line) < @abs(@as(i64, best.?) - fn_line)) best = line;
    }
    return .{ .file = file, .line = best orelse fn_line };
}

test "Trace locations resolve to systems and schedule declarations" {
    if (std.debug.SelfInfo == void) return error.SkipZigTest;
    const m = struct {
        const M = @This();
        pub const mach_module = .m;
        pub const mach_systems = .{ .tick, .system };

        pub const tick = schedule(.{
            .{ M, .system },
        });

        pub fn system() std.builtin.SourceLocation {
            return @src();
        }
    };

    const src = m.system();
    const fn_location = resolveTraceLocation(@intFromPtr(&m.system), null) orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.endsWith(u8, std.mem.span(fn_location.file), "trace.zig"));
    // The line of `pub fn system`, just above the @src() in its body.
    try std.testing.expectEqual(src.line - 1, fn_location.line);

    const schedule_location = resolveTraceLocation(@intFromPtr(&m.system), "tick") orelse return error.SkipZigTest;
    try std.testing.expectEqual(src.line - 5, schedule_location.line);
}
