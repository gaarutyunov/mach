//! Schedule declarations: `mach.schedule` and `mach.scheduleWith`.
const std = @import("std");
const module = @import("../module.zig");
const ScheduleContext = @import("ScheduleContext.zig");
const Context = @import("Context.zig");
const Modules = module.Modules;
const Mod = module.Mod;

/// Validate that the given tuple is a valid schedule, returning true if so.
fn validateSchedule(comptime Params: type, comptime entries: anytype) bool {
    if (Params != void and @typeInfo(Params) != .@"struct") {
        @compileError("mach.scheduleWith() expects a struct type for its params, found: " ++ @typeName(Params));
    }

    const Entries = @TypeOf(entries);
    const entries_info = @typeInfo(Entries);
    if (entries_info != .@"struct" or !entries_info.@"struct".is_tuple) {
        @compileError("mach.schedule() expects a tuple of .{ Module, .fn_name, condition? } entries, found: " ++ @typeName(Entries));
    }
    inline for (entries) |tuple| {
        const tuple_info = @typeInfo(@TypeOf(tuple));
        // Check it's a 2 or 3-field tuple before accessing fields
        if (tuple_info != .@"struct" or !tuple_info.@"struct".is_tuple or
            (tuple_info.@"struct".field_names.len != 2 and tuple_info.@"struct".field_names.len != 3))
        {
            @compileError("mach.schedule() entry expected tuple .{ Module, .fn_name, condition? }, found: " ++ @typeName(@TypeOf(tuple)));
        }
        const Module: type = tuple.@"0";
        const fn_name = tuple.@"1";

        // Validate first field is a valid module type
        if (!module.isValid(Module)) {
            @compileError("mach.schedule() entry first field must be a valid Mach module (has `pub const mach_module = .foo_name`), found: " ++ @typeName(Module));
        }
        if (!@hasDecl(Module, "mach_systems")) {
            @compileError("mach.schedule() entry first field must have a `pub const mach_systems` declaration, found: " ++ @typeName(Module));
        }

        // Validate second field is an enum literal
        if (@typeInfo(@TypeOf(fn_name)) != .enum_literal) {
            @compileError("mach.schedule() entry expected tuple .{ Module, .fn_name }, second value not an enum literal, found: " ++ @typeName(@TypeOf(fn_name)));
        }

        // Validate function name exists in module's mach_systems
        if (!@hasField(module.ModuleFunctionName(Module), @tagName(fn_name))) {
            @compileError("mach.schedule() entry references ." ++ @tagName(fn_name) ++ " but module " ++ @typeName(Module) ++ " has no such entry in `mach_systems`");
        }

        if (tuple_info.@"struct".field_names.len == 3) validateCondition(Params, tuple.@"2");
    }

    return true;
}

/// Validates the optional third field of a schedule entry: the name of a bool or
/// `std.atomic.Value(bool)` field of its params.
fn validateCondition(comptime Params: type, comptime condition: anytype) void {
    if (@typeInfo(@TypeOf(condition)) != .enum_literal) {
        @compileError("mach.schedule() entry condition must name a bool or std.atomic.Value(bool) field of the schedule's params, found: " ++ @typeName(@TypeOf(condition)));
    }
    const name = @tagName(condition);
    if (Params == void) {
        @compileError("mach.schedule() entry condition ." ++ name ++ " needs a params struct with that field, see mach.scheduleWith()");
    }
    if (!@hasField(Params, name)) {
        @compileError("mach.schedule() entry condition ." ++ name ++ " is not a field of " ++ @typeName(Params));
    }
    const T = @FieldType(Params, name);
    if (T != bool and T != std.atomic.Value(bool)) {
        @compileError("mach.schedule() entry condition ." ++ name ++ " must be a bool or std.atomic.Value(bool), found: " ++ @typeName(T));
    }
}

/// The value of a schedule declaration, as returned by `schedule` and `scheduleWith`.
fn ScheduleDecl(comptime P: type, comptime schedule_entries: anytype) type {
    return struct {
        pub const IsMachSchedule = void;
        pub const Params = P;
        pub const entries = schedule_entries;
    };
}

pub fn isScheduleDecl(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "IsMachSchedule");
}

/// When a schedule is called, the list of module functions described within are executed in order.
///
/// Example:
/// ```
/// pub const foo = mach.schedule(.{
///     .{ App, .init },
///     .{ Physics, .init },
///     .{ App, .main },
/// });
/// ...
/// my_mod.call(.foo); // runs App.init, Physics.init, App.main in order
/// ```
///
/// An entry may name a schedule of any module, which runs as a nested schedule.
///
/// Each run of a schedule has its own `ScheduleContext`, available to its systems as
/// `ctx.schedule`, for sharing values between them and releasing them when the schedule ends.
///
/// Use `scheduleWith` to give a schedule parameters, and to run entries conditionally.
pub fn schedule(comptime entries: anytype) ScheduleDecl(void, entries) {
    _ = comptime validateSchedule(void, entries);
    return .{};
}

/// Same as `schedule`, for a schedule with parameters: an instance of the given struct, whose
/// fields must all have default values. There is one instance per schedule per `mach.Modules`, so
/// it keeps its values between runs. Systems access it with `ctx.schedule.params(Params)`.
///
/// An entry may have the name of a bool field of the params as its third field, in which case it
/// only runs if that field is true when the entry is reached:
///
/// ```
/// pub const RenderParams = struct {
///     needs_setup: bool = true,
///     show_overlay: bool = false,
/// };
///
/// pub const render = mach.scheduleWith(RenderParams, .{
///     .{ App, .setupGpu, .needs_setup },
///     .{ App, .beginFrame },
///     .{ gfx.Sprite, .render },
///     .{ Overlay, .render, .show_overlay },
///     .{ App, .endFrame },
/// });
///
/// pub fn setupGpu(ctx: mach.Context) void {
///     ...
///     ctx.schedule.params(RenderParams).needs_setup = false;
/// }
/// ```
///
/// A condition may also be a `std.atomic.Value(bool)` (read with `.acquire`), for one set from
/// another thread, e.g. by the render thread through `Mod(M).scheduleParams()`:
///
/// ```
/// pub const TickParams = struct {
///     gpu_ready: std.atomic.Value(bool) = .init(false),
/// };
///
/// pub const tick = mach.scheduleWith(TickParams, .{
///     .{ App, .setupPipelines, .gpu_ready },
///     ...
/// });
///
/// // On the render thread:
/// pub fn setupGpu(app_mod: mach.Mod(App)) void {
///     ...
///     app_mod.scheduleParams(.tick).gpu_ready.store(true, .release);
/// }
/// ```
pub fn scheduleWith(comptime Params: type, comptime entries: anytype) ScheduleDecl(Params, entries) {
    _ = comptime validateSchedule(Params, entries);
    return .{};
}

pub fn ScheduleParamsOf(comptime M: type, comptime name: []const u8) type {
    const F = @TypeOf(@field(M, name));
    if (!isScheduleDecl(F) or F.Params == void) {
        @compileError("mach: ." ++ @tagName(M.mach_module) ++ "." ++ name ++ " is not a schedule with params, see mach.scheduleWith()");
    }
    return F.Params;
}

test "Schedule params and conditions" {
    const Params = struct {
        needs_setup: bool = true,
        gated: bool = false,
        count: u32 = 10,
    };
    const m = struct {
        const M = @This();
        pub const mach_module = .m;
        pub const mach_systems = .{ .main, .nested, .setup, .always, .gated, .readFromNested };

        pub const main = scheduleWith(Params, .{
            .{ M, .setup, .needs_setup },
            .{ M, .always },
            .{ M, .gated, .gated },
            .{ M, .nested },
        });

        pub const nested = schedule(.{
            .{ M, .readFromNested },
        });

        setups: u32,
        always_runs: u32,
        gated_runs: u32,
        count_seen: u32,

        pub fn setup(m_: *M, ctx: Context) void {
            m_.setups += 1;
            ctx.schedule.params(Params).needs_setup = false;
        }

        pub fn always(m_: *M, ctx: Context) void {
            m_.always_runs += 1;
            // Takes effect for the entries after this one.
            ctx.schedule.params(Params).gated = m_.always_runs >= 3;
            ctx.schedule.params(Params).count += 1;
        }

        pub fn gated(m_: *M) void {
            m_.gated_runs += 1;
        }

        pub fn readFromNested(m_: *M, ctx: Context) void {
            m_.count_seen = ctx.schedule.params(Params).count;
        }
    };
    const zero: m = .{ .setups = 0, .always_runs = 0, .gated_runs = 0, .count_seen = 0 };

    const allocator = std.testing.allocator;
    var modules: Modules(.{m}) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);
    modules.mods.m = zero;

    modules.get(.m).run(.main);
    modules.get(.m).run(.main);
    modules.get(.m).run(.main);

    try std.testing.expectEqual(1, modules.mods.m.setups);
    try std.testing.expectEqual(3, modules.mods.m.always_runs);
    try std.testing.expectEqual(1, modules.mods.m.gated_runs);
    // Params are kept between runs, and visible to nested schedules.
    try std.testing.expectEqual(13, modules.mods.m.count_seen);

    // Params are per Modules instance.
    var other: Modules(.{m}) = undefined;
    try other.init(allocator, std.Options.debug_io);
    defer other.deinit(allocator);
    other.mods.m = zero;
    other.get(.m).run(.main);
    try std.testing.expectEqual(1, other.mods.m.setups);
    try std.testing.expectEqual(11, other.mods.m.count_seen);
}

test "Schedule atomic conditions, set from another schedule" {
    const Params = struct {
        ready: std.atomic.Value(bool) = .init(false),
    };
    const m = struct {
        const M = @This();
        pub const mach_module = .m;
        pub const mach_systems = .{ .tick, .onReady, .publish };

        pub const tick = scheduleWith(Params, .{
            .{ M, .onReady, .ready },
        });

        ready_runs: u32 = 0,

        pub fn onReady(m_: *M, ctx: Context) void {
            m_.ready_runs += 1;
            ctx.schedule.params(Params).ready.store(false, .release);
        }

        /// Not part of `tick`, e.g. running on another thread.
        pub fn publish(m_mod: Mod(M)) void {
            m_mod.scheduleParams(.tick).ready.store(true, .release);
        }
    };

    const allocator = std.testing.allocator;
    var modules: Modules(.{m}) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);
    modules.mods.m = .{};

    modules.get(.m).run(.tick);
    try std.testing.expectEqual(0, modules.mods.m.ready_runs);
    modules.get(.m).run(.publish);
    modules.get(.m).run(.tick);
    modules.get(.m).run(.tick);
    try std.testing.expectEqual(1, modules.mods.m.ready_runs);
}
