const std = @import("std");
const Core = @import("Core.zig");
const StringTable = @import("StringTable.zig");
const Graph = @import("graph.zig").Graph;
const PoolAllocator = @import("PoolAllocator.zig");
const dvx_metrics = @import("dvx/metrics.zig");
const MeteredAllocator = dvx_metrics.MeteredAllocator;
const tracy = @import("tracy");
const build_options = @import("build-options");

pub const Context = @import("module/Context.zig");
pub const ModuleMemory = Context.ModuleMemory;
pub const ScheduleContext = @import("module/ScheduleContext.zig");

const objects = @import("module/objects.zig");
pub const ObjectID = objects.ObjectID;
pub const ObjectsOptions = objects.ObjectsOptions;
pub const Objects = objects.Objects;

const schedules = @import("module/schedule.zig");
pub const schedule = schedules.schedule;
pub const scheduleWith = schedules.scheduleWith;
pub const Require = ScheduleContext.Require;
const isScheduleDecl = schedules.isScheduleDecl;
const keysRequiredAfter = schedules.keysRequiredAfter;
const ScheduleParamsOf = schedules.ScheduleParamsOf;

const trace = @import("module/trace.zig");
const SystemTrace = trace.SystemTrace;
const MemoryPlot = trace.MemoryPlot;

const log = @import("module/log.zig");
pub const dataflow = @import("module/dataflow.zig");
pub const threads = @import("module/threads.zig");
const inspect = @import("module/inspect.zig");
pub const logFn = log.logFn;
const ContextLog = log.ContextLog;

/// A handle to a spawned thread.
pub const Thread = struct {
    thread: std.Thread,

    pub fn join(self: Thread) void {
        self.thread.join();
    }
};

/// Spawn a thread that runs the given function in a loop until the application exits.
pub fn startThread(
    core: *Core,
    on_tick: FunctionID,
    core_mod: Mod(Core),
    comptime kind: anytype,
) error{ThreadSpawnFailed}!Thread {
    // TODO(thread): use kind for measured preallocations, etc.
    const run = struct {
        fn run(c: *Core, f: FunctionID, m: Mod(Core)) void {
            tracy.setThreadName(@tagName(kind));
            threads.setName(@tagName(kind));
            while (c.state.load(.acquire) == .running) {
                m.run(f);
            }
        }
    }.run;
    return .{
        .thread = std.Thread.spawn(.{}, run, .{ core, on_tick, core_mod }) catch
            return error.ThreadSpawnFailed,
    };
}

/// Initialize a graph with default preallocations for the given kind.
pub fn initGraph(graph: *Graph, allocator: std.mem.Allocator, io: std.Io, comptime kind: anytype) !void {
    // TODO(object): measured preallocations
    _ = kind;
    try graph.init(allocator, io, .{
        .queue_size = 32,
        .nodes_size = 32,
        .num_result_lists = 8,
        .result_list_size = 8,
    });
}

/// Unique identifier for every module in the program, including those only known at runtime.
pub const ModuleID = u32;

/// Unique identifier for a function within a single module, including those only known at runtime.
pub const ModuleFunctionID = u16;

/// Unique identifier for a function within a module, including those only known at runtime.
pub const FunctionID = struct { module_id: ModuleID, fn_id: ModuleFunctionID };

/// The usage of a module that isn't metered, because metrics are disabled.
const no_usage: dvx_metrics.AllocatorMetrics = .{};

pub fn Mod(comptime M: type) type {
    return struct {
        pub const IsMachMod = void;

        pub const module_name = M.mach_module;
        pub const Module = M;

        id: ModFunctionIDs(M),
        _ctx: *anyopaque,
        _run: *const fn (ctx: *anyopaque, fn_id: FunctionID) void,
        _schedule_params: *const fn (ctx: *anyopaque, fn_id: FunctionID) *anyopaque,

        pub fn run(r: *const @This(), fn_id: FunctionID) void {
            r._run(r._ctx, fn_id);
        }

        /// Returns the params of this module's schedule `f` (declared with `mach.scheduleWith`),
        /// e.g. to set its conditions from outside of it. They are the same params its systems
        /// get from `ctx.schedule.params()` while it runs.
        ///
        /// Schedules may run on other threads (e.g. the render thread): fields written from a
        /// thread other than the one running the schedule must be `std.atomic.Value(bool)`.
        pub fn scheduleParams(r: *const @This(), comptime f: ModuleFunctionName(M)) *ScheduleParamsOf(M, @tagName(f)) {
            return @ptrCast(@alignCast(r._schedule_params(r._ctx, @field(r.id, @tagName(f)))));
        }

        pub fn call(r: *const @This(), comptime f: ModuleFunctionName(M)) void {
            const fn_id = @field(r.id, @tagName(f));
            r.run(fn_id);
        }
    };
}

pub fn ModFunctionIDs(comptime Module: type) type {
    var field_names: []const []const u8 = &.{};
    var field_types: []const type = &.{};
    var field_attrs: []const std.builtin.Type.Struct.FieldAttributes = &.{};
    for (Module.mach_systems) |fn_name| {
        field_names = field_names ++ [_][]const u8{@tagName(fn_name)};
        field_types = field_types ++ [_]type{FunctionID};
        field_attrs = field_attrs ++ [_]std.builtin.Type.Struct.FieldAttributes{.{
            .default_value_ptr = null,
            .@"comptime" = false,
            .@"align" = null,
        }};
    }
    return @Struct(.auto, null, field_names[0..field_names.len], field_types[0..field_types.len], field_attrs[0..field_attrs.len]);
}

/// Enum describing all declarations for a given comptime-known module.
pub fn ModuleFunctionName(comptime M: type) type {
    @setEvalBranchQuota(10_000);
    validate(M);
    var enum_names: []const []const u8 = &.{};
    inline for (M.mach_systems) |fn_tag| {
        enum_names = enum_names ++ [_][]const u8{@tagName(fn_tag)};
    }
    const TagType = if (enum_names.len > 0) std.math.IntFittingRange(0, enum_names.len - 1) else u0;
    return @Enum(TagType, .exhaustive, enum_names, &std.simd.iota(TagType, enum_names.len));
}

/// Validates that every entry in `M.mach_systems` has a corresponding `pub fn <name>` or
/// `pub const <name> = mach.schedule(...)` decl.
///
/// Do not call this in the path of mach.schedule() because it could result in circular evaluation
/// of self-referential schedule decls.
fn validateModuleSystemDecls(comptime M: type) void {
    if (!@hasDecl(M, "mach_systems")) return;
    inline for (M.mach_systems) |fn_tag| {
        const name = @tagName(fn_tag);
        if (!@hasDecl(M, name)) {
            @compileError("Module ." ++ @tagName(M.mach_module) ++ " declares mach_systems entry ." ++ name ++ " but has no `pub fn " ++ name ++ "` or `pub const " ++ name ++ " = mach.schedule(...)` decl");
        }
        const F = @TypeOf(@field(M, name));
        const f_info = @typeInfo(F);
        const is_fn = f_info == .@"fn";
        const is_schedule = isScheduleDecl(F);
        if (!is_fn and !is_schedule) {
            @compileError("Module ." ++ @tagName(M.mach_module) ++ " mach_systems entry ." ++ name ++ " must be a `pub fn` or `pub const " ++ name ++ " = mach.schedule(...)`, found: " ++ @typeName(F));
        }
    }
}

/// Enum describing all mach_tags for a given comptime-known module.
pub fn ModuleTagEnum(comptime M: type) type {
    // TODO(object): handle duplicate enum field case in mach_tags with a more clear error?
    // TODO(object): improve validation error messages here
    validate(M);
    if (@typeInfo(@TypeOf(M.mach_tags)) != .@"struct") {
        @compileError("mach: invalid module, `pub const mach_tags must be `.{ .is_monster, .{ .renderer, mach.Renderer.objects } }`, found: " ++ @typeName(@TypeOf(M.mach_tags)));
    }
    var enum_names: []const []const u8 = &.{};
    inline for (@typeInfo(@TypeOf(M.mach_tags)).@"struct".field_types, 0..) |field_type, field_index| {
        const f = M.mach_tags[field_index];
        if (@typeInfo(field_type) == .enum_literal) {
            enum_names = enum_names ++ [_][]const u8{@tagName(f)};
        } else {
            if (@typeInfo(field_type) != .@"struct") {
                @compileError("mach: invalid module, mach_tags entry is not an enum literal or struct, found: " ++ @typeName(field_type));
            }
            // TODO(objects): validate length of struct
            const tag = f.@"0";
            const M2 = f.@"1";
            const object_list_tag = f.@"2";
            _ = object_list_tag; // autofix
            validate(M2);
            // TODO: validate that M2.object_list_tag is a mach objects list
            enum_names = enum_names ++ [_][]const u8{@tagName(tag)};
        }
    }
    const TagType = if (enum_names.len > 0) std.math.IntFittingRange(0, enum_names.len - 1) else u0;
    return @Enum(TagType, .exhaustive, enum_names, &std.simd.iota(TagType, enum_names.len));
}

pub fn Modules(module_lists: anytype) type {
    inline for (moduleTuple(module_lists)) |module| {
        validate(module);
        validateModuleSystemDecls(module);
    }
    return struct {
        /// All modules.
        // These already pass validate()
        pub const modules = moduleTuple(module_lists);

        /// Enum describing every module name compiled into the program.
        pub const ModuleName = NameEnum(modules);

        /// A struct whose comptime field of name `<module_name>` is the module type.
        // This is hoisted up here, not written inline, to avoid expending needless comptime eval
        // branches.
        const module_types_by_name = ModuleTypesByName(modules){};

        mods: ModulesByName(modules),
        io: std.Io,

        /// The global allocator passed to `init()`. Used by the object graph, and by every module
        /// which has no allocator override in `InitOptions.allocators`.
        allocator: std.mem.Allocator = undefined,

        /// The resolved allocator for each module, by module name. Use `allocatorFor()`.
        allocators: ModuleAllocators(modules) = undefined,

        /// Each module's memory pool, if it was given a budget in `InitOptions.budgets`.
        pools: ModulePools(modules) = .{},

        /// With `-Dmetrics`, wraps the allocator of each module without a pool to record its usage.
        metered_allocators: ModuleMeteredAllocators(modules) = .{},

        /// With `-Dtracy`, each module's allocator wrapped to report to Tracy as a named pool.
        tracing_allocators: ModuleTracingAllocators(modules) = undefined,

        /// The block reserved up front for all pools, split according to the budgets.
        pool_block: []u8 = &.{},

        module_names: StringTable = .{},
        object_names: StringTable = .{},
        name_ids: std.MultiArrayList(struct {
            module_name_id: u32,
            object_name_id: u32,
        }) = .{},
        graph: Graph,

        /// The params of each schedule declared with `scheduleWith`, by "module.schedule" name.
        schedule_params: ModuleScheduleParams(modules) = .{},

        pub const InitOptions = struct {
            /// Per-module allocator overrides, by module name, e.g.:
            ///
            /// ```
            /// .allocators = .{ .mach_gfx_sprite = sprite_pool.allocator() },
            /// ```
            ///
            /// A module's allocator backs its `mach.Objects` lists and is `ctx.allocator` in the
            /// `mach.Context` its systems receive. Modules left `null` use the global allocator
            /// passed to `init()`.
            allocators: ModuleAllocatorOptions(modules) = .{},

            /// Per-module memory budgets in bytes, by module name, e.g.:
            ///
            /// ```
            /// .budgets = .{ .app = 32 * mib, .mach_audio = 128 * mib },
            /// ```
            ///
            /// One block covering all budgets is reserved up front from the OS (pages are only
            /// committed as they are first used, so unused budget costs address space, not RAM).
            /// Each listed module gets its own `mach.PoolAllocator` over its slice of the block,
            /// and allocating past the budget fails with `error.OutOfMemory`. Use
            /// `reportMemory()` to log usage and high-water marks for sizing budgets.
            ///
            /// A module can't have both a budget and an allocator override.
            budgets: ModuleBudgets(modules) = .{},
        };

        pub fn init(m: *@This(), allocator: std.mem.Allocator, io: std.Io) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
            return m.initOptions(allocator, io, .{});
        }

        pub fn initOptions(m: *@This(), allocator: std.mem.Allocator, io: std.Io, options: InitOptions) (std.mem.Allocator.Error || std.Thread.SpawnError)!void {
            m.* = .{
                .mods = undefined,
                .graph = undefined,
                .io = io,
                .allocator = allocator,
            };
            try m.initPools(io, options);
            inline for (@typeInfo(@TypeOf(m.allocators)).@"struct".field_names) |name| {
                const base = if (@field(m.pools, name)) |*pool| pool.allocator() else blk: {
                    const unmetered = @field(options.allocators, name) orelse allocator;
                    if (!dvx_metrics.enabled) break :blk unmetered;
                    const metered = &@field(m.metered_allocators, name);
                    metered.* = .{ .parent = unmetered };
                    break :blk metered.*.?.allocator();
                };
                @field(m.allocators, name) = if (build_options.tracy) blk: {
                    const tracing = &@field(m.tracing_allocators, name);
                    tracing.* = .initNamed(std.fmt.comptimePrint("{s}", .{name}), base);
                    break :blk tracing.allocator();
                } else base;
            }
            try initGraph(&m.graph, allocator, io, .global);

            // TODO(object): errdefer release allocations made in this loop
            inline for (@typeInfo(@TypeOf(m.mods)).@"struct".field_names) |field_name| {
                // TODO(objects): module-state-init
                const Mod2 = @TypeOf(@field(m.mods, field_name));
                var mod: Mod2 = undefined;
                const module_name_id = try m.module_names.indexOrPut(allocator, @tagName(Mod2.mach_module));
                const mod_info = @typeInfo(@TypeOf(mod)).@"struct";
                try m.name_ids.ensureUnusedCapacity(allocator, mod_info.field_names.len);
                inline for (mod_info.field_names, mod_info.field_types) |mod_field_name, mod_field_type| {
                    if (@typeInfo(mod_field_type) == .@"struct" and @hasDecl(mod_field_type, "IsMachObjects")) {
                        const object_name_id = try m.object_names.indexOrPut(allocator, mod_field_name);

                        const object_type_id = m.name_ids.addOneAssumeCapacity();
                        m.name_ids.set(object_type_id, .{
                            .module_name_id = module_name_id,
                            .object_name_id = object_name_id,
                        });

                        @field(mod, mod_field_name).internal = .{
                            .allocator = @field(m.allocators, field_name),
                            .io = io,
                            .type_id = @intCast(object_type_id),
                            .graph = &m.graph,
                        };
                    }
                }
                @field(m.mods, field_name) = mod;

                // Register each Objects pool's pending_delete bitset and mutex with the graph
                // so that delete() can cascade across pools via cascadeDelete().
                inline for (mod_info.field_names, mod_info.field_types) |mod_field_name, mod_field_type| {
                    if (@typeInfo(mod_field_type) == .@"struct" and @hasDecl(mod_field_type, "IsMachObjects")) {
                        const objs = &@field(@field(m.mods, field_name), mod_field_name);
                        try m.graph.registerDeletePool(allocator, objs.internal.type_id, &objs.internal.pending_delete, &objs.internal.mu);
                    }
                }
            }
        }

        fn initPools(m: *@This(), io: std.Io, options: InitOptions) std.mem.Allocator.Error!void {
            const names = @typeInfo(@TypeOf(m.pools)).@"struct".field_names;
            var total: usize = 0;
            inline for (names) |name| {
                if (@field(options.budgets, name)) |budget| {
                    if (@field(options.allocators, name) != null) {
                        @panic("mach: module ." ++ name ++ " has both a budget and an allocator override");
                    }
                    total += budget;
                }
            }
            if (total == 0) return;

            m.pool_block = try std.heap.page_allocator.alloc(u8, total);
            var offset: usize = 0;
            inline for (names) |name| {
                if (@field(options.budgets, name)) |budget| {
                    @field(m.pools, name) = PoolAllocator.init(name, m.pool_block[offset..][0..budget], io);
                    offset += budget;
                    tracy.plotConfig(MemoryPlot(name).name, .{ .plot_type = .Memory, .step = 1, .fill = 1, .color = 0 });
                }
            }
        }

        /// Logs usage and high-water mark of every module's memory pool (see
        /// `InitOptions.budgets`).
        pub fn reportMemory(m: *@This()) void {
            inline for (@typeInfo(@TypeOf(m.pools)).@"struct".field_names) |name| {
                if (@field(m.pools, name)) |*pool| pool.report();
            }
        }

        /// Fills `out` with a memory snapshot of every module (up to `out.len` of them) and
        /// returns the filled part.
        pub fn memoryStats(m: *@This(), out: []ModuleMemory) []ModuleMemory {
            var n: usize = 0;
            inline for (@typeInfo(@TypeOf(m.pools)).@"struct".field_names) |name| {
                if (n == out.len) return out;
                out[n] = .{
                    .name = name,
                    .usage = if (@field(m.pools, name)) |*pool|
                        &pool.metrics
                    else if (@field(m.metered_allocators, name)) |*metered|
                        &metered.metrics
                    else
                        &no_usage,
                    .pool = if (@field(m.pools, name)) |*pool| pool else null,
                };
                n += 1;
            }
            return out[0..n];
        }

        /// With `-Dtracy` and `-Dmetrics`, plots the module's pool usage (called after each of its
        /// systems runs).
        fn plotMemory(m: *@This(), comptime name: []const u8) void {
            if (!build_options.tracy or !dvx_metrics.enabled) return;
            if (@field(m.pools, name)) |*pool| {
                tracy.plot(i64, MemoryPlot(name).name, pool.metrics.used_bytes.load());
            }
        }

        /// Frees memory owned by the module system: every module's `mach.Objects` lists, the object
        /// graph, internal name tables, and memory pools.
        ///
        /// This does not run any module's `deinit` system; resources a module allocated itself must
        /// be released by that module (typically via its own `.deinit` system) beforehand.
        pub fn deinit(m: *@This(), allocator: std.mem.Allocator) void {
            inline for (@typeInfo(@TypeOf(m.mods)).@"struct".field_names) |field_name| {
                const mod = &@field(m.mods, field_name);
                const mod_info = @typeInfo(@TypeOf(mod.*)).@"struct";
                inline for (mod_info.field_names, mod_info.field_types) |mod_field_name, mod_field_type| {
                    if (@typeInfo(mod_field_type) == .@"struct" and @hasDecl(mod_field_type, "IsMachObjects")) {
                        @field(mod, mod_field_name).deinit();
                    }
                }
            }
            m.graph.deinit(allocator);
            m.name_ids.deinit(allocator);
            m.module_names.deinit(allocator);
            m.object_names.deinit(allocator);
            if (m.pool_block.len > 0) std.heap.page_allocator.free(m.pool_block);
        }

        pub fn Module(module_tag_or_type: anytype) type {
            const module_name: ModuleName = blk: {
                if (@typeInfo(@TypeOf(module_tag_or_type)) == .enum_literal or @typeInfo(@TypeOf(module_tag_or_type)) == .@"enum") break :blk @as(ModuleName, module_tag_or_type);
                validate(module_tag_or_type);
                break :blk module_tag_or_type.mach_module;
            };

            // Note: no need to validate(module) here because it is derived from `modules`.
            const module = @field(module_types_by_name, @tagName(module_name));

            return struct {
                mods: *ModulesByName(modules),
                modules: *Modules(module_lists),

                pub const mod_name: ModuleName = module_name;

                pub fn getFunction(fn_name: ModuleFunctionName(module)) FunctionID {
                    return .{
                        .module_id = @backingInt(mod_name),
                        .fn_id = @backingInt(fn_name),
                    };
                }

                pub fn run(
                    m: *const @This(),
                    comptime fn_name: ModuleFunctionName(module),
                ) void {
                    const debug_name = @tagName(module_name) ++ "." ++ @tagName(fn_name);
                    if (!@hasField(module, @tagName(fn_name)) and !@hasDecl(module, @tagName(fn_name))) {
                        @compileError("Module ." ++ @tagName(module_name) ++ " declares mach_systems entry ." ++ @tagName(fn_name) ++ " but no pub fn or schedule with that name exists.");
                    }
                    const f = @field(module, @tagName(fn_name));
                    const F = @TypeOf(f);

                    // Every system and schedule gets a zone, so a schedule's zone contains a zone
                    // for each part that ran. Its zone text lists the parts which didn't.
                    const zone = SystemTrace(module, @tagName(fn_name), debug_name).begin();
                    defer zone.deinit();
                    defer m.modules.plotMemory(@tagName(module_name));

                    if (comptime isScheduleDecl(F)) {
                        // Run a list of functions instead of a single function
                        var frame: ScheduleContext.Frame = .{ .parent = ScheduleContext.current_frame };
                        if (F.Params != void) {
                            frame.params = &@field(m.modules.schedule_params, @tagName(module_name) ++ "." ++ @tagName(fn_name));
                            frame.params_type = &ScheduleContext.TypeTag(F.Params).tag;
                        }
                        ScheduleContext.current_frame = &frame;
                        defer {
                            ScheduleContext.current_frame = frame.parent;
                            if (frame.len > 0) {
                                const finalize_zone = tracy.initZone(@src(), .{
                                    .name = debug_name ++ " finalize",
                                    .color = trace.colors.finalize,
                                });
                                defer finalize_zone.deinit();
                                frame.end();
                            }
                        }

                        inline for (F.entries, 0..) |schedule_entry, entry_index| {
                            // TODO: unify with Modules(modules).get(M)
                            const callMod: Module(schedule_entry.@"0") = .{ .mods = m.mods, .modules = m.modules };
                            if (!@hasField(ModuleFunctionName(schedule_entry.@"0"), @tagName(schedule_entry.@"1"))) {
                                @compileError("Module ." ++ @tagName(@TypeOf(callMod).mod_name) ++ " has no mach_systems entry '." ++ @tagName(schedule_entry.@"1") ++ "'");
                            }
                            const callFn = @as(ModuleFunctionName(schedule_entry.@"0"), schedule_entry.@"1");
                            const entry_name = @tagName(@TypeOf(callMod).mod_name) ++ "." ++ @tagName(callFn);
                            const skipped_by_condition = comptime if (@typeInfo(@TypeOf(schedule_entry)).@"struct".field_names.len < 3)
                                ""
                            else
                                "skipped " ++ entry_name ++ " (." ++ @tagName(schedule_entry.@"2") ++ " is false)";
                            frame.keep = comptime keysRequiredAfter(F.entries, entry_index);
                            if (frame.stopped) {
                                zone.text("skipped " ++ entry_name ++ " (stopped)");
                            } else if (!m.scheduleEntryEnabled(@tagName(fn_name), schedule_entry)) {
                                zone.text(skipped_by_condition);
                            } else {
                                callMod.run(callFn);
                                if (frame.stopped) zone.text("stopped by " ++ entry_name);
                            }
                        }
                        return;
                    }

                    var args: std.meta.ArgsTuple(F) = undefined;
                    outer: inline for (@typeInfo(std.meta.ArgsTuple(F)).@"struct".field_names, @typeInfo(std.meta.ArgsTuple(F)).@"struct".field_types) |arg_name, arg_type| {
                        if (@typeInfo(arg_type) == .pointer and
                            @typeInfo(std.meta.Child(arg_type)) == .@"struct" and
                            comptime isValid(std.meta.Child(arg_type)))
                        {
                            // *Module argument
                            // TODO: better error if @field(m.mods, ...) fails ("module not registered")
                            @field(args, arg_name) = &@field(m.mods, @tagName(std.meta.Child(arg_type).mach_module));
                            continue :outer;
                        }
                        if (arg_type == std.Io) {
                            @field(args, arg_name) = m.modules.io;
                            continue :outer;
                        }
                        if (arg_type == Context) {
                            var ctx = m.modules.context(module_name);
                            ctx.system_name = @tagName(fn_name);
                            ctx.schedule = .{ .frame = ScheduleContext.current_frame };
                            @field(args, arg_name) = ctx;
                            continue :outer;
                        }
                        if (comptime ScheduleContext.isRequire(arg_type)) {
                            @field(args, arg_name) = .init(.{ .frame = ScheduleContext.current_frame });
                            continue :outer;
                        }
                        if (@typeInfo(arg_type) == .@"struct" and @hasDecl(arg_type, "IsMachMod")) {
                            const M = arg_type.Module;
                            var mv: Mod(M) = .{
                                .id = undefined,
                                ._ctx = m.modules,
                                ._run = (struct {
                                    pub fn run(ctx: *anyopaque, fn_id: FunctionID) void {
                                        const modules2: *Modules(module_lists) = @ptrCast(@alignCast(ctx));
                                        modules2.callDynamic(fn_id);
                                    }
                                }).run,
                                ._schedule_params = (struct {
                                    pub fn get(ctx: *anyopaque, fn_id: FunctionID) *anyopaque {
                                        const modules2: *Modules(module_lists) = @ptrCast(@alignCast(ctx));
                                        return modules2.scheduleParamsDynamic(fn_id);
                                    }
                                }).get,
                            };
                            inline for (M.mach_systems) |m_fn_name| {
                                @field(mv.id, @tagName(m_fn_name)) = Module(M).getFunction(m_fn_name);
                            }
                            @field(args, arg_name) = mv;
                            continue :outer;
                        }
                        @compileError("mach: function " ++ debug_name ++ " has an invalid argument(" ++ arg_name ++ ") type: " ++ @typeName(arg_type));
                    }

                    const prev_system = dataflow.current_system;
                    dataflow.current_system = debug_name;
                    defer dataflow.current_system = prev_system;
                    const span_start = threads.systemBegin(m.modules.io);
                    defer threads.systemEnd(m.modules.io, debug_name, span_start);

                    const Ret = @typeInfo(F).@"fn".return_type orelse void;
                    switch (@typeInfo(Ret)) {
                        // TODO: define error handling of runnable functions
                        .error_union => @call(.auto, f, args) catch |err| std.debug.panic("error: {s}", .{@errorName(err)}),
                        else => @call(.auto, f, args),
                    }
                }

                /// Whether a schedule entry of this module should run, according to its condition.
                fn scheduleEntryEnabled(
                    m: *const @This(),
                    comptime schedule_name: []const u8,
                    comptime schedule_entry: anytype,
                ) bool {
                    if (@typeInfo(@TypeOf(schedule_entry)).@"struct".field_names.len < 3) return true;
                    const params = &@field(m.modules.schedule_params, @tagName(module_name) ++ "." ++ schedule_name);
                    const condition = &@field(params, @tagName(schedule_entry.@"2"));
                    return if (@TypeOf(condition.*) == bool) condition.* else condition.load(.acquire);
                }
            };
        }

        pub fn get(m: *@This(), module_tag_or_type: anytype) Module(module_tag_or_type) {
            return .{ .mods = &m.mods, .modules = m };
        }

        /// Returns the `mach.Context` for the given module, as given to its systems.
        pub fn context(m: *@This(), module_name: ModuleName) Context {
            switch (module_name) {
                inline else => |name| return .{
                    .allocator = @field(m.allocators, @tagName(name)),
                    .io = m.io,
                    .pool = if (@field(m.pools, @tagName(name))) |*pool| pool else null,
                    .module_name = @tagName(name),
                    ._modules = m,
                    ._log = ContextLog(@field(module_types_by_name, @tagName(name)).mach_module).log,
                    ._log_enabled = ContextLog(@field(module_types_by_name, @tagName(name)).mach_module).enabled,
                    ._report_memory = (struct {
                        fn reportMemory(modules_ptr: *anyopaque) void {
                            const m2: *Modules(module_lists) = @ptrCast(@alignCast(modules_ptr));
                            m2.reportMemory();
                        }
                    }).reportMemory,
                    ._memory_stats = (struct {
                        fn memoryStats(modules_ptr: *anyopaque, out: []ModuleMemory) []ModuleMemory {
                            const m2: *Modules(module_lists) = @ptrCast(@alignCast(modules_ptr));
                            return m2.memoryStats(out);
                        }
                    }).memoryStats,
                    ._set_schedule_param = (struct {
                        fn set(modules_ptr: *anyopaque, schedule_name: []const u8, field: []const u8, value: bool) bool {
                            const m2: *Modules(module_lists) = @ptrCast(@alignCast(modules_ptr));
                            return inspect.setScheduleParam(m2, schedule_name, field, value);
                        }
                    }).set,
                    ._inspect = (struct {
                        fn inspectFn(modules_ptr: *anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void {
                            const m2: *Modules(module_lists) = @ptrCast(@alignCast(modules_ptr));
                            return inspect.write(m2, w);
                        }
                    }).inspectFn,
                },
            }
        }

        /// Writes the modules' structure and state as JSON object members (`"modules":[...]`, ...)
        /// for the inspector, see `mach.dvx.Inspector`.
        pub fn writeInspect(m: *@This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            return inspect.write(m, w);
        }

        /// Returns the allocator for the given module (its override, or the global allocator).
        pub fn allocatorFor(m: *@This(), module_tag_or_type: anytype) std.mem.Allocator {
            return @field(m.allocators, @tagName(Module(module_tag_or_type).mod_name));
        }

        /// The params of the schedule `f`, which must have been declared with `mach.scheduleWith`.
        fn scheduleParamsDynamic(m: *@This(), f: FunctionID) *anyopaque {
            if (comptime modules.len == 0) unreachable;
            const module_name: ModuleName = @fromBackingInt(@intCast(f.module_id));
            switch (module_name) {
                inline else => |mod_name| {
                    const M = @field(module_types_by_name, @tagName(mod_name));
                    const module_fn_name: ModuleFunctionName(M) = @fromBackingInt(@intCast(f.fn_id));
                    switch (module_fn_name) {
                        inline else => |fn_name| {
                            const F = @TypeOf(@field(M, @tagName(fn_name)));
                            if (comptime !isScheduleDecl(F) or F.Params == void) unreachable;
                            return &@field(m.schedule_params, @tagName(mod_name) ++ "." ++ @tagName(fn_name));
                        },
                    }
                },
            }
        }

        pub fn callDynamic(m: *@This(), f: FunctionID) void {
            if (comptime modules.len == 0) return;
            const module_name: ModuleName = @fromBackingInt(@intCast(f.module_id));
            switch (module_name) {
                inline else => |mod_name| {
                    const M = @field(module_types_by_name, @tagName(mod_name));
                    const module_fn_name: ModuleFunctionName(M) = @fromBackingInt(@intCast(f.fn_id));
                    const mod: Module(mod_name) = .{ .mods = &m.mods, .modules = m };
                    // Note: we don't need to validate the module here because it is derived from
                    // `modules`.

                    switch (module_fn_name) {
                        inline else => |fn_name| mod.run(fn_name),
                    }
                },
            }
        }
    };
}

/// Validates that the given struct is a Mach module.
fn validate(comptime module: anytype) void {
    if (!@hasDecl(module, "mach_module")) @compileError("mach: invalid module, missing `pub const mach_module = .foo_name;` declaration: " ++ @typeName(@TypeOf(module)));
    if (@typeInfo(@TypeOf(module.mach_module)) != .enum_literal) @compileError("mach: invalid module, expected `pub const mach_module = .foo_name;` declaration, found: " ++ @typeName(@TypeOf(module.mach_module)));
}

pub fn isValid(comptime module: anytype) bool {
    if (!@hasDecl(module, "mach_module")) return false;
    if (@typeInfo(@TypeOf(module.mach_module)) != .enum_literal) return false;
    return true;
}

/// Given a tuple of Mach module structs, returns an enum which has every possible comptime-known
/// module name.
fn NameEnum(comptime mods: anytype) type {
    var enum_names: []const []const u8 = &.{};
    for (mods) |module| {
        validate(module);
        enum_names = enum_names ++ [_][]const u8{@tagName(module.mach_module)};
    }
    const TagType = if (enum_names.len > 0) std.math.IntFittingRange(0, enum_names.len - 1) else u0;
    return @Enum(TagType, .exhaustive, enum_names, &std.simd.iota(TagType, enum_names.len));
}

/// Given a tuple of module structs or module struct tuples:
///
/// ```
/// .{
///     .{ Baz, .{ Bar, Foo, .{ Fam } }, Bar },
///     Foo,
///     Bam,
///     .{ Foo, Bam },
/// }
/// ```
///
/// Returns a flat tuple, deduplicated:
///
/// .{ Baz, Bar, Foo, Fam, Bar, Bam }
///
fn moduleTuple(comptime tuple: anytype) []const type {
    return moduleTupleCollect(tuple);
}

fn moduleTupleCollect(comptime tuple: anytype) []const type {
    if (@typeInfo(@TypeOf(tuple)) != .@"struct" or !@typeInfo(@TypeOf(tuple)).@"struct".is_tuple) {
        @compileError("Expected to find a tuple, found: " ++ @typeName(@TypeOf(tuple)));
    }

    var types: []const type = &.{};
    for (tuple) |elem| {
        if (@typeInfo(@TypeOf(elem)) == .type and @typeInfo(elem) == .@"struct") {
            // Struct type
            validate(elem);
            for (types) |t| if (t == elem) continue;
            types = types ++ [_]type{elem};
        } else if (@typeInfo(@TypeOf(elem)) == .@"struct" and @typeInfo(@TypeOf(elem)).@"struct".is_tuple) {
            // Nested tuple
            for (moduleTupleCollect(elem)) |nested| {
                validate(nested);
                for (types) |t| if (t == nested) continue;
                types = types ++ [_]type{nested};
            }
        } else {
            @compileError("Expected to find a tuple or struct type, found: " ++ @typeName(@TypeOf(elem)));
        }
    }
    return types;
}

/// Given .{Foo, Bar, Baz} Mach modules, returns .{.foo = Foo, .bar = Bar, .baz = Baz} with field
/// names corresponding to each module's `pub const mach_module = .foo;` name.
fn ModuleTypesByName(comptime modules: anytype) type {
    var field_names: []const []const u8 = &.{};
    var field_types: []const type = &.{};
    var field_attrs: []const std.builtin.Type.Struct.FieldAttributes = &.{};
    for (modules) |M| {
        field_names = field_names ++ [_][]const u8{@tagName(M.mach_module)};
        field_types = field_types ++ [_]type{type};
        field_attrs = field_attrs ++ [_]std.builtin.Type.Struct.FieldAttributes{.{
            .default_value_ptr = @ptrCast(&M),
            .@"comptime" = true,
            .@"align" = null,
        }};
    }
    return @Struct(.auto, null, field_names[0..field_names.len], field_types[0..field_types.len], field_attrs[0..field_attrs.len]);
}

/// Given .{Foo, Bar, Baz} Mach modules, returns a struct with one field per schedule declared with
/// `scheduleWith`, named "module.schedule", holding its params with their default values.
fn ModuleScheduleParams(comptime modules: anytype) type {
    var field_names: []const []const u8 = &.{};
    var field_types: []const type = &.{};
    var field_attrs: []const std.builtin.Type.Struct.FieldAttributes = &.{};
    for (modules) |M| {
        if (!@hasDecl(M, "mach_systems")) continue;
        for (M.mach_systems) |system| {
            const F = @TypeOf(@field(M, @tagName(system)));
            if (!isScheduleDecl(F) or F.Params == void) continue;
            const default: F.Params = .{};
            field_names = field_names ++ [_][]const u8{@tagName(M.mach_module) ++ "." ++ @tagName(system)};
            field_types = field_types ++ [_]type{F.Params};
            field_attrs = field_attrs ++ [_]std.builtin.Type.Struct.FieldAttributes{.{
                .default_value_ptr = @ptrCast(&default),
                .@"comptime" = false,
                .@"align" = null,
            }};
        }
    }
    return @Struct(.auto, null, field_names[0..field_names.len], field_types[0..field_types.len], field_attrs[0..field_attrs.len]);
}

/// Given .{Foo, Bar, Baz} Mach modules, returns a struct with one `?std.mem.Allocator = null`
/// field per module name.
fn ModuleAllocatorOptions(comptime modules: anytype) type {
    return ModuleFieldsOf(modules, ?std.mem.Allocator, &@as(?std.mem.Allocator, null));
}

/// Given .{Foo, Bar, Baz} Mach modules, returns a struct with one `std.mem.Allocator` field per
/// module name.
fn ModuleAllocators(comptime modules: anytype) type {
    return ModuleFieldsOf(modules, std.mem.Allocator, null);
}

/// Given .{Foo, Bar, Baz} Mach modules, returns a struct with one `?usize = null` field per module
/// name.
fn ModuleBudgets(comptime modules: anytype) type {
    return ModuleFieldsOf(modules, ?usize, &@as(?usize, null));
}

/// Given .{Foo, Bar, Baz} Mach modules, returns a struct with one `?PoolAllocator = null` field per
/// module name.
fn ModulePools(comptime modules: anytype) type {
    return ModuleFieldsOf(modules, ?PoolAllocator, &@as(?PoolAllocator, null));
}

/// Given .{Foo, Bar, Baz} Mach modules, returns a struct with one `?MeteredAllocator = null` field
/// per module name.
fn ModuleMeteredAllocators(comptime modules: anytype) type {
    return ModuleFieldsOf(modules, ?MeteredAllocator, &@as(?MeteredAllocator, null));
}

fn ModuleTracingAllocators(comptime modules: anytype) type {
    return ModuleFieldsOf(modules, if (build_options.tracy) tracy.TracingAllocator else void, null);
}

fn ModuleFieldsOf(comptime modules: anytype, comptime T: type, comptime default: ?*const T) type {
    var field_names: []const []const u8 = &.{};
    var field_types: []const type = &.{};
    var field_attrs: []const std.builtin.Type.Struct.FieldAttributes = &.{};
    for (modules) |M| {
        field_names = field_names ++ [_][]const u8{@tagName(M.mach_module)};
        field_types = field_types ++ [_]type{T};
        field_attrs = field_attrs ++ [_]std.builtin.Type.Struct.FieldAttributes{.{
            .default_value_ptr = if (default) |d| @ptrCast(d) else null,
            .@"comptime" = false,
            .@"align" = null,
        }};
    }
    return @Struct(.auto, null, field_names[0..field_names.len], field_types[0..field_types.len], field_attrs[0..field_attrs.len]);
}

/// Given .{Foo, Bar, Baz} Mach modules, returns .{.foo: Foo = undefined, .bar: Bar = undefined, .baz: Baz = undefined}
/// with field names corresponding to each module's `pub const mach_module = .foo;` name, and each Foo type.
fn ModulesByName(comptime modules: anytype) type {
    var field_names: []const []const u8 = &.{};
    var field_types: []const type = &.{};
    var field_attrs: []const std.builtin.Type.Struct.FieldAttributes = &.{};
    for (modules) |M| {
        field_names = field_names ++ [_][]const u8{@tagName(M.mach_module)};
        field_types = field_types ++ [_]type{M};
        field_attrs = field_attrs ++ [_]std.builtin.Type.Struct.FieldAttributes{.{
            .default_value_ptr = @ptrCast(&@as(M, undefined)),
            .@"comptime" = false,
            .@"align" = null,
        }};
    }
    return @Struct(.auto, null, field_names[0..field_names.len], field_types[0..field_types.len], field_attrs[0..field_attrs.len]);
}

test "Long field name" {
    const test_module = struct {
        pub const mach_module = .test_module;
        really_really_really_really_really_really_really_long_field_name: Objects(.{}, struct {}),
        another_field: Objects(.{}, struct {}),
    };

    const allocator = std.testing.allocator;

    const io = std.Options.debug_io;
    var modules = Modules(.{test_module}){
        .mods = undefined,
        .graph = undefined,
        .io = io,
    };
    try modules.init(allocator, io);
    modules.deinit(allocator);
}

test "Many fields, same module" {
    const test_module = struct {
        pub const mach_module = .test_module;
        field0: Objects(.{}, struct {}),
        field1: Objects(.{}, struct {}),
        field2: Objects(.{}, struct {}),
        field3: Objects(.{}, struct {}),
        field4: Objects(.{}, struct {}),
        field5: Objects(.{}, struct {}),
        field6: Objects(.{}, struct {}),
        field7: Objects(.{}, struct {}),
        field8: Objects(.{}, struct {}),
        field9: Objects(.{}, struct {}),
    };

    const allocator = std.testing.allocator;

    const io = std.Options.debug_io;
    var modules = Modules(.{test_module}){
        .mods = undefined,
        .graph = undefined,
        .io = io,
    };
    try modules.init(allocator, io);
    modules.deinit(allocator);
}

test "Many fields, Many modules" {
    const test_module0 = struct {
        pub const mach_module = .test_module0;
        field0: Objects(.{}, struct {}),
        field1: Objects(.{}, struct {}),
        field2: Objects(.{}, struct {}),
        field3: Objects(.{}, struct {}),
    };
    const test_module1 = struct {
        pub const mach_module = .test_module1;
        field4: Objects(.{}, struct {}),
        field5: Objects(.{}, struct {}),
        field6: Objects(.{}, struct {}),
        field7: Objects(.{}, struct {}),
    };
    const test_module2 = struct {
        pub const mach_module = .test_module2;
        field8: Objects(.{}, struct {}),
        field9: Objects(.{}, struct {}),
    };

    const allocator = std.testing.allocator;

    const io = std.Options.debug_io;
    var modules = Modules(.{ test_module0, test_module1, test_module2 }){
        .mods = undefined,
        .graph = undefined,
        .io = io,
    };
    try modules.init(allocator, io);
    modules.deinit(allocator);
}

/// Returns the allocator a module's allocator wraps, without the Tracy and metrics wrappers.
fn testBaseAllocator(a: std.mem.Allocator) std.mem.Allocator {
    const untraced = if (build_options.tracy) blk: {
        const tracing: *tracy.TracingAllocator = @ptrCast(@alignCast(a.ptr));
        break :blk tracing.parent_allocator;
    } else a;
    if (untraced.vtable != &MeteredAllocator.vtable) return untraced;
    const metered: *MeteredAllocator = @ptrCast(@alignCast(untraced.ptr));
    return metered.parent;
}

test "Per-module allocators" {
    const pooled = struct {
        pub const mach_module = .pooled;
        pub const mach_systems = .{.init};
        things: Objects(.{}, struct { a: u32 }),
        seen: std.mem.Allocator,
        pub fn init(m: *@This(), ctx: Context) void {
            m.seen = ctx.allocator;
        }
    };
    const global = struct {
        pub const mach_module = .global;
        pub const mach_systems = .{.init};
        things: Objects(.{}, struct { a: u32 }),
        seen: std.mem.Allocator,
        pub fn init(m: *@This(), ctx: Context) void {
            m.seen = ctx.allocator;
        }
    };

    const allocator = std.testing.allocator;

    var pool = std.testing.FailingAllocator.init(allocator, .{});
    const pool_allocator = pool.allocator();

    const io = std.Options.debug_io;
    var modules: Modules(.{ pooled, global }) = undefined;
    try modules.initOptions(allocator, io, .{ .allocators = .{ .pooled = pool_allocator } });
    defer modules.deinit(allocator);

    // Overrides are resolved, and Objects lists use their module's allocator.
    try std.testing.expectEqual(pool_allocator.ptr, testBaseAllocator(modules.allocatorFor(.pooled)).ptr);
    try std.testing.expectEqual(allocator.ptr, testBaseAllocator(modules.allocatorFor(.global)).ptr);
    try std.testing.expectEqual(pool_allocator.ptr, testBaseAllocator(modules.mods.pooled.things.internal.allocator).ptr);
    try std.testing.expectEqual(allocator.ptr, testBaseAllocator(modules.mods.global.things.internal.allocator).ptr);

    // Systems receive their module's allocator.
    modules.get(.pooled).run(.init);
    modules.get(.global).run(.init);
    try std.testing.expectEqual(pool_allocator.ptr, testBaseAllocator(modules.mods.pooled.seen).ptr);
    try std.testing.expectEqual(allocator.ptr, testBaseAllocator(modules.mods.global.seen).ptr);

    // After preallocating, new() and free() do not allocate until capacity is exceeded.
    const things = &modules.mods.pooled.things;
    try things.ensureTotalCapacity(16);
    pool.fail_index = pool.alloc_index;
    const capacity = things.internal.data.capacity;
    try std.testing.expect(capacity >= 16);
    var ids: [64]ObjectID = undefined;
    for (ids[0..capacity], 0..) |*id, i| id.* = try things.new(.{ .a = @intCast(i) });
    for (ids[0..8]) |id| things.free(id);
    for (ids[0..8]) |*id| id.* = try things.new(.{ .a = 0 });
    // Growing past the reserved capacity hits the allocator again.
    try std.testing.expectError(error.OutOfMemory, things.new(.{ .a = 0 }));
}

test "Context logging" {
    const logger = struct {
        pub const mach_module = .logger;
        pub const mach_systems = .{.init};
        system_name: []const u8,
        pub fn init(m: *@This(), ctx: Context) void {
            m.system_name = ctx.system_name;
            ctx.info("hello {d}", .{42});
            const long: [Context.max_log_len + 16]u8 = @splat('x');
            ctx.debug("{s}", .{&long}); // truncated, not an error
        }
    };

    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    var modules: Modules(.{logger}) = undefined;
    try modules.init(allocator, io);
    defer modules.deinit(allocator);

    modules.get(.logger).run(.init);
    try std.testing.expectEqualStrings("init", modules.mods.logger.system_name);

    const ctx = modules.context(.logger);
    try std.testing.expectEqualStrings("logger", ctx.module_name);
    try std.testing.expectEqualStrings("", ctx.system_name);
    ctx.info("outside a system", .{});
}

test "Per-module budgets" {
    const pooled = struct {
        pub const mach_module = .pooled;
        things: Objects(.{}, struct { a: u32 }),
    };
    const global = struct {
        pub const mach_module = .global;
        things: Objects(.{}, struct { a: u32 }),
    };

    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    var modules: Modules(.{ pooled, global }) = undefined;
    try modules.initOptions(allocator, io, .{ .budgets = .{ .pooled = 1024 * 1024 } });
    defer modules.deinit(allocator);

    // The budgeted module gets a pool; the other uses the global allocator.
    const pool = &modules.pools.pooled.?;
    try std.testing.expect(modules.pools.global == null);
    try std.testing.expectEqual(@as(*anyopaque, pool), testBaseAllocator(modules.allocatorFor(.pooled)).ptr);
    try std.testing.expectEqual(pool.buffer.len, 1024 * 1024);
    try std.testing.expectEqual(allocator.ptr, testBaseAllocator(modules.allocatorFor(.global)).ptr);

    // Systems' context exposes the module's pool.
    const ctx = modules.context(.pooled);
    try std.testing.expectEqual(pool, ctx.pool.?);
    try std.testing.expectEqualStrings("pooled", ctx.module_name);
    try std.testing.expect(modules.context(.global).pool == null);

    // Objects lists allocate from the pool, and are limited by its budget.
    _ = try modules.mods.pooled.things.new(.{ .a = 1 });
    if (dvx_metrics.enabled) try std.testing.expect(pool.metrics.used_bytes.load() > 0);
    pool.exhausted = true; // silence the expected out-of-memory warning
    try std.testing.expectError(error.OutOfMemory, modules.mods.pooled.things.ensureTotalCapacity(1024 * 1024));

    // memoryStats reports every module, with pool metrics for budgeted ones.
    var buf: [4]ModuleMemory = undefined;
    const stats = ctx.memoryStats(&buf);
    try std.testing.expectEqual(2, stats.len);
    try std.testing.expectEqualStrings("pooled", stats[0].name);
    try std.testing.expectEqual(@as(?*const PoolAllocator, pool), stats[0].pool);
    try std.testing.expectEqual(&pool.metrics, stats[0].usage);
    if (dvx_metrics.enabled) {
        const usage = stats[0].usage;
        try std.testing.expect(usage.allocs_total.load() > 0);
        try std.testing.expectEqual(1, usage.failed_allocs_total.load());
        try std.testing.expect(pool.touched_bytes.load() >= usage.used_bytes.load());
    }
    try std.testing.expectEqualStrings("global", stats[1].name);
    try std.testing.expect(stats[1].pool == null);

    // Modules without a budget are metered instead.
    if (dvx_metrics.enabled) {
        const usage = stats[1].usage;
        const used_before = usage.used_bytes.load();
        _ = try modules.mods.global.things.new(.{ .a = 1 });
        try std.testing.expect(usage.used_bytes.load() > used_before);
        try std.testing.expect(usage.allocs_total.load() > 0);
    }
    try std.testing.expectEqual(1, ctx.memoryStats(buf[0..1]).len);
}

test {
    _ = @import("module/ScheduleContext.zig");
    _ = @import("module/schedule.zig");
    _ = @import("module/objects.zig");
    _ = @import("module/trace.zig");
    _ = @import("module/inspect.zig");
    _ = @import("module/dataflow.zig");
    _ = @import("module/threads.zig");
}
