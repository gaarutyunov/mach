const std = @import("std");
const mach = @import("main.zig");
const Core = @import("Core.zig");
const StringTable = @import("StringTable.zig");
const Graph = @import("graph.zig").Graph;
const PoolAllocator = @import("PoolAllocator.zig");
const dvx_metrics = @import("dvx/metrics.zig");
const MeteredAllocator = dvx_metrics.MeteredAllocator;
const tracy = @import("tracy");
const build_options = @import("build-options");

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
        if (!isValid(Module)) {
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
        if (!@hasField(ModuleFunctionName(Module), @tagName(fn_name))) {
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

fn isScheduleDecl(comptime T: type) bool {
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

/// An ID representing a mach object. This is an opaque identifier which effectively encodes:
///
/// * An array index that can be used to O(1) lookup the actual data / struct fields of the object.
/// * The generation (or 'version') of the object, enabling detecting use-after-free in
///   many (but not all) cases.
/// * Which module the object came from, allowing looking up type information or the module name
///   from ID alone.
/// * Which list of objects in a module the object came from, allowing looking up type information
///   or the object type name - which enables debugging and type safety when passing opaque IDs
///   around.
///
pub const ObjectID = u64;

const ObjectTypeID = u16;

pub const ObjectsOptions = struct {
    /// If set to true, Mach will track when fields are set using the setField/setAll
    /// methods using a bitset with one bit per field to indicate 'the field was set'.
    /// You can get this information by calling `.updated(.field_name)`
    /// Note that calling `.updated(.field_name) will also set the flag back to false.
    track_fields: bool = false,

    /// When true, delete() will result in a panic indicating that objects in this list must be
    /// explicitly free()'d instead.
    require_free: bool = false,
};

pub fn Objects(options: ObjectsOptions, comptime T: type) type {
    // MultiArrayList doesn't support zero-field structs, so add a dummy field to make it work.
    // TODO(object): avoid constructing MultiArrayList entirely in this case?
    const has_fields = @typeInfo(T).@"struct".field_names.len > 0;
    const StorageT = if (has_fields) T else struct { _padding: u0 = 0 };

    return struct {
        internal: struct {
            allocator: std.mem.Allocator,
            io: std.Io,

            /// Mutex to be held when operating on these objects.
            mu: std.Io.RwLock = .init,

            /// A registered ID indicating the type of objects being represented. This can be
            /// thought of as a hash of the module name + field name where this objects list is
            /// stored.
            type_id: ObjectTypeID,

            /// The actual object data
            data: std.MultiArrayList(StorageT) = .empty,

            /// Whether a given slot in data[i] has been freed or not
            freed: std.bit_set.DynamicBitSetUnmanaged = .{},

            /// Whether a given slot in data[i] is marked for pending deletion
            pending_delete: std.bit_set.DynamicBitSetUnmanaged = .{},

            /// The current generation number of data[i], when data[i] becomes freed and then alive
            /// again, this number is incremented by one.
            generation: std.ArrayList(Generation) = .empty,

            /// The recycling bin which tells which data indices are freed and can be reused.
            recycling_bin: std.ArrayList(Index) = .empty,

            /// The number of objects that could not fit in the recycling bin and hence were thrown
            /// on the floor and forgotten about. This means there are freed items recorded by freed.set(index)
            /// which aren't in the recycling_bin, and the next call to new() may consider cleaning up.
            thrown_on_the_floor: u32 = 0,

            /// Global pointer to object relations graph
            graph: *Graph,

            /// A bitset used to track per-field changes. Only used if options.track_fields == true.
            updated: ?std.bit_set.DynamicBitSetUnmanaged = if (options.track_fields) .{} else null,

            /// Tags storage
            tags: std.AutoHashMapUnmanaged(TaggedObject, ?ObjectID) = .{},
        },

        pub const IsMachObjects = void;

        fn toStorage(value: T) StorageT {
            if (has_fields) return value else return .{};
        }

        fn fromStorage(value: StorageT) T {
            if (has_fields) return value else return .{};
        }

        const Generation = u16;
        const Index = u32;

        const TaggedObject = struct {
            object_id: ObjectID,
            tag_hash: u64,
        };

        const PackedID = packed struct(u64) {
            type_id: ObjectTypeID,
            generation: Generation,
            index: Index,
        };

        pub const Slice = struct {
            index: Index,
            objs: *Objects(options, T),

            pub fn next(s: *Slice) ?ObjectID {
                const freed = &s.objs.internal.freed;
                const generation = &s.objs.internal.generation;
                const num_objects = generation.items.len;

                while (true) {
                    if (s.index == num_objects) {
                        s.index = 0;
                        return null;
                    }
                    defer s.index += 1;

                    if (!freed.isSet(s.index) and !s.objs.internal.pending_delete.isSet(s.index)) return @bitCast(PackedID{
                        .type_id = s.objs.internal.type_id,
                        .generation = generation.items[s.index],
                        .index = s.index,
                    });
                }
            }
        };

        /// Tries to acquire the mutex without blocking the caller's thread.
        /// Returns `false` if the calling thread would have to block to acquire it.
        /// Otherwise, returns `true` and the caller should `unlock()` the Mutex to release it.
        pub fn tryLock(objs: *@This()) bool {
            return objs.internal.mu.tryLock(objs.internal.io);
        }

        /// Acquires the mutex, blocking the caller's thread until it can.
        /// It is undefined behavior if the mutex is already held by the caller's thread.
        /// Once acquired, call `unlock()` on the Mutex to release it.
        pub fn lock(objs: *@This()) void {
            objs.internal.mu.lockUncancelable(objs.internal.io);
        }

        /// Releases the mutex which was previously acquired with `lock()` or `tryLock()`.
        /// It is undefined behavior if the mutex is unlocked from a different thread that it was locked from.
        pub fn unlock(objs: *@This()) void {
            objs.internal.mu.unlock(objs.internal.io);
        }

        /// Tries to acquire a shared (read) lock without blocking the caller's thread.
        ///
        /// Returns `false` if the calling thread would have to block to acquire it.
        /// Otherwise, returns `true` and the caller should call `unlockShared()` to release it.
        pub fn tryLockShared(objs: *@This()) bool {
            return objs.internal.mu.tryLockShared(objs.internal.io);
        }

        /// Acquires a shared (read) lock, blocking the caller's thread until it can.
        /// Multiple readers may hold the lock concurrently, but no writer may hold it while readers
        /// do.
        /// Once acquired, call `unlockShared()` on the Mutex to release it.
        pub fn lockShared(objs: *@This()) void {
            objs.internal.mu.lockSharedUncancelable(objs.internal.io);
        }

        /// Releases the shared (reader) lock which was previously acquired with `lockShared()` or
        /// `tryLockShared()`.
        pub fn unlockShared(objs: *@This()) void {
            objs.internal.mu.unlockShared(objs.internal.io);
        }

        pub fn new(objs: *@This(), value: T) std.mem.Allocator.Error!ObjectID {
            const allocator = objs.internal.allocator;
            const data = &objs.internal.data;
            const freed = &objs.internal.freed;
            const pending_delete = &objs.internal.pending_delete;
            const generation = &objs.internal.generation;
            const recycling_bin = &objs.internal.recycling_bin;

            // The recycling bin should always be big enough, but we check at this point if 10% of
            // all objects have been thrown on the floor. If they have, we find them and grow the
            // recycling bin to fit them.
            if (objs.internal.thrown_on_the_floor >= (data.len / 10)) {
                var iter = freed.iterator(.{ .kind = .set });
                freed_object_loop: while (iter.next()) |index| {
                    // We need to check if this index is already in the recycling bin since
                    // if it is, it could get recycled a second time while still
                    // in use.
                    for (recycling_bin.items) |recycled_index| {
                        if (index == recycled_index) continue :freed_object_loop;
                    }

                    // freed bitset contains data.capacity number of entries, we only care about ones that are in data.len range.
                    if (index > data.len - 1) break;
                    try recycling_bin.append(allocator, @intCast(index));
                }
                objs.internal.thrown_on_the_floor = 0;
            }

            if (recycling_bin.pop()) |index| {
                // Reuse a free slot from the recycling bin.
                freed.unset(index);
                pending_delete.unset(index);
                const gen = generation.items[index] + 1;
                generation.items[index] = gen;
                data.set(index, toStorage(value));
                return @bitCast(PackedID{
                    .type_id = objs.internal.type_id,
                    .generation = gen,
                    .index = index,
                });
            }

            // Ensure we have space for the new object
            try data.ensureUnusedCapacity(allocator, 1);
            try freed.resize(allocator, data.capacity, false);
            try pending_delete.resize(allocator, data.capacity, false);
            try generation.ensureUnusedCapacity(allocator, 1);

            // If we are tracking fields, we need to resize the bitset to hold another object's fields
            if (objs.internal.updated) |*updated_fields| {
                try updated_fields.resize(allocator, data.capacity * @typeInfo(T).@"struct".field_names.len, true);
            }

            const index = data.len;
            data.appendAssumeCapacity(toStorage(value));
            freed.unset(index);
            generation.appendAssumeCapacity(0);

            return @bitCast(PackedID{
                .type_id = objs.internal.type_id,
                .generation = 0,
                .index = @intCast(index),
            });
        }

        /// Frees all memory owned by this list. Called by `Modules.deinit()`; object IDs from this
        /// list are invalid afterwards.
        pub fn deinit(objs: *@This()) void {
            const allocator = objs.internal.allocator;
            objs.internal.data.deinit(allocator);
            objs.internal.freed.deinit(allocator);
            objs.internal.pending_delete.deinit(allocator);
            objs.internal.generation.deinit(allocator);
            objs.internal.recycling_bin.deinit(allocator);
            if (objs.internal.updated) |*updated_fields| updated_fields.deinit(allocator);
            objs.internal.tags.deinit(allocator);
        }

        /// Preallocates storage for at least `new_capacity` objects (live or freed), so that
        /// `new()` and `free()` do not allocate until that many slots are in use.
        pub fn ensureTotalCapacity(objs: *@This(), new_capacity: usize) std.mem.Allocator.Error!void {
            const allocator = objs.internal.allocator;
            const data = &objs.internal.data;

            try data.ensureTotalCapacity(allocator, new_capacity);
            try objs.internal.freed.resize(allocator, data.capacity, false);
            try objs.internal.pending_delete.resize(allocator, data.capacity, false);
            try objs.internal.generation.ensureTotalCapacity(allocator, data.capacity);
            try objs.internal.recycling_bin.ensureTotalCapacity(allocator, data.capacity);
            if (objs.internal.updated) |*updated_fields| {
                try updated_fields.resize(allocator, data.capacity * @typeInfo(T).@"struct".field_names.len, true);
            }
        }

        /// Sets all fields of the given object to the given value.
        ///
        /// Unlike setAll(), this method does not respect any mach.Objects tracking
        /// options, so changes made to an object through this method will not be tracked.
        pub fn setValueRaw(objs: *@This(), id: ObjectID, value: T) void {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "setValueRaw");
            data.set(unpacked.index, toStorage(value));
        }

        /// Sets all fields of the given object to the given value.
        ///
        /// Unlike setAllRaw, this method respects mach.Objects tracking
        /// and changes made to an object through this method will be tracked.
        pub fn setValue(objs: *@This(), id: ObjectID, value: T) void {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "setValue");
            data.set(unpacked.index, toStorage(value));

            if (objs.internal.updated) |*updated_fields| {
                const updated_start = unpacked.index * @typeInfo(T).@"struct".field_names.len;
                const updated_end = updated_start + @typeInfo(T).@"struct".field_names.len;
                updated_fields.setRangeValue(.{ .start = @intCast(updated_start), .end = @intCast(updated_end) }, true);
            }
        }

        /// Sets a single field of the given object to the given value.
        ///
        /// Unlike set(), this method does not respect any mach.Objects tracking
        /// options, so changes made to an object through this method will not be tracked.
        pub fn setRaw(objs: *@This(), id: ObjectID, comptime field_name: std.meta.FieldEnum(T), value: @FieldType(T, @tagName(field_name))) void {
            const data = &objs.internal.data;
            const unpacked = objs.validateAndUnpack(id, "setRaw");

            data.items(field_name)[unpacked.index] = value;
        }

        /// Sets a single field of the given object to the given value.
        ///
        /// Unlike setAllRaw, this method respects mach.Objects tracking
        /// and changes made to an object through this method will be tracked.
        pub fn set(objs: *@This(), id: ObjectID, comptime field_name: std.meta.FieldEnum(T), value: @FieldType(T, @tagName(field_name))) void {
            const data = &objs.internal.data;
            const unpacked = objs.validateAndUnpack(id, "set");

            data.items(field_name)[unpacked.index] = value;

            if (options.track_fields)
                if (std.meta.fieldIndex(T, @tagName(field_name))) |field_index|
                    if (objs.internal.updated) |*updated_fields|
                        updated_fields.set(unpacked.index * @typeInfo(T).@"struct".field_names.len + field_index);
        }

        /// Get a single field.
        pub fn get(objs: *@This(), id: ObjectID, comptime field_name: std.meta.FieldEnum(T)) @FieldType(T, @tagName(field_name)) {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "get");
            return data.items(field_name)[unpacked.index];
        }

        /// Get all fields.
        pub fn getValue(objs: *@This(), id: ObjectID) T {
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "getValue");
            return fromStorage(data.get(unpacked.index));
        }

        /// Returns an iterator over a single field of every live object, in the same order that
        /// `slice()` yields their IDs. Excludes any objects which have been freed or marked for
        /// deletion.
        pub fn sliceField(objs: *@This(), comptime field_name: std.meta.FieldEnum(T)) SliceField(field_name) {
            // Sync any cascaded deletions that may have occurred prior to this so our
            // pending_delete bits are up to date.
            objs.internal.graph.sync(objs.internal.allocator) catch {};

            return .{ .index = 0, .objs = objs };
        }

        pub fn SliceField(comptime field_name: std.meta.FieldEnum(T)) type {
            return struct {
                index: Index,
                objs: *Objects(options, T),

                pub fn next(s: *@This()) ?@FieldType(T, @tagName(field_name)) {
                    const freed = &s.objs.internal.freed;
                    const pending_delete = &s.objs.internal.pending_delete;
                    const num_objects = s.objs.internal.generation.items.len;

                    while (true) {
                        if (s.index == num_objects) {
                            s.index = 0;
                            return null;
                        }
                        defer s.index += 1;

                        if (!freed.isSet(s.index) and !pending_delete.isSet(s.index)) {
                            // Re-fetched each call: new() may reallocate the column mid-iteration.
                            return s.objs.internal.data.items(field_name)[s.index];
                        }
                    }
                }
            };
        }

        /// Marks an object for deletion. The object is flagged for deletion, it remains alive and
        /// readable until someone, usually the owning module that knows how to cleanup its
        /// resources, invokes `free()` on it.
        ///
        /// Deletion is cascaded to all descendants in the object graph, marking them as deleted too
        ///
        /// Use `isDeleted()` to check if an object has been deleted but not yet freed, or
        /// `sliceDeleted()` to iterate all deleted objects from the set.
        ///
        /// If `require_free = true`, it is a @compileError to invoke this method on the set and
        /// free() must be used instead.
        pub fn delete(objs: *@This(), id: ObjectID) void {
            if (options.require_free) @compileError("delete() cannot be used when require_free is set; use free() instead");
            const unpacked = objs.validateAndUnpack(id, "delete");
            objs.internal.pending_delete.set(unpacked.index);

            // Enqueue the cascaded delete to all descendants in the graph.
            // TODO(object): better error handling here
            objs.internal.graph.cascadeDelete(objs.internal.allocator, id) catch {};
        }

        /// Immediately removes an object from the pool, freeing its slot for reuse.
        ///
        /// Freeing an object also removes its parent object in the graph, if any.
        ///
        /// In order to free an object, you must know how to release its resources - including graph
        /// resources. If `require_free = true`, then an object is declared as requiring manual
        /// `free()`.
        ///
        /// If `require_free = false`, you should use `delete()` instead which doesn't require
        /// knowing how to free the objects resources - by allowing the module that owns the object
        /// to release them later (by ultimately calling `free()` itself) instead.
        ///
        /// In debug builds, calling free() on an object which has children in the graph results in
        /// a panic.
        pub fn free(objs: *@This(), id: ObjectID) void {
            const unpacked = objs.validateAndUnpack(id, "free");
            const data = &objs.internal.data;
            const freed = &objs.internal.freed;
            const recycling_bin = &objs.internal.recycling_bin;
            if (recycling_bin.items.len < recycling_bin.capacity) {
                recycling_bin.appendAssumeCapacity(unpacked.index);
            } else objs.internal.thrown_on_the_floor += 1;

            freed.set(unpacked.index);
            objs.internal.pending_delete.unset(unpacked.index);

            // Enqueue our parents' removal from the graph
            objs.internal.graph.removeParent(objs.internal.allocator, id) catch {};

            if (mach.is_debug) {
                const undef: StorageT = undefined;
                data.set(unpacked.index, undef);
            }
        }

        /// Returns an iterator over objects marked for deletion.
        ///
        /// Used by modules to find objects that need to cleanup resources on objects before
        /// ultimately calling free() on each object.
        pub fn sliceDeleted(objs: *@This()) SliceDeleted {
            // Sync any cascaded deletions that may have occurred prior to this so our
            // pending_delete bits are up to date.
            objs.internal.graph.sync(objs.internal.allocator) catch {};

            return .{ .index = 0, .objs = objs };
        }

        pub const SliceDeleted = struct {
            index: Index,
            objs: *Objects(options, T),

            pub fn next(s: *SliceDeleted) ?ObjectID {
                const pending = &s.objs.internal.pending_delete;
                const generation = &s.objs.internal.generation;
                const num_objects = generation.items.len;

                while (true) {
                    if (s.index == num_objects) {
                        s.index = 0;
                        return null;
                    }
                    defer s.index += 1;

                    if (pending.isSet(s.index)) return @bitCast(PackedID{
                        .type_id = s.objs.internal.type_id,
                        .generation = generation.items[s.index],
                        .index = s.index,
                    });
                }
            }
        };

        /// Returns true if the object has been marked for deferred deletion.
        ///
        /// Calling this on an object which has been free()'d already is illegal and will result in
        /// undefined behavior in production builds, and a safety-check panic in debug builds.
        pub fn isDeleted(objs: *const @This(), id: ObjectID) bool {
            const unpacked = objs.validateAndUnpack(id, "isDeleted");

            // Sync any cascaded deletions that may have occurred prior to this so our
            // pending_delete bits are up to date.
            objs.internal.graph.sync(objs.internal.allocator) catch {};

            return objs.internal.pending_delete.isSet(unpacked.index);
        }

        /// Returns the number of objects currently marked for deferred deletion.
        pub fn numDeleted(objs: *const @This()) u32 {
            // Sync any cascaded deletions that may have occurred prior to this so our
            // pending_delete bits are up to date.
            objs.internal.graph.sync(objs.internal.allocator) catch {};

            return @intCast(objs.internal.pending_delete.count());
        }

        // TODO(objects): evaluate whether tag operations should ever return an error

        /// Sets a tag on an object
        pub fn setTag(objs: *@This(), id: ObjectID, comptime M: type, tag: ModuleTagEnum(M), value_id: ?ObjectID) !void {
            _ = objs.validateAndUnpack(id, "setTag");

            // TODO: validate that value_id is an object coming from the mach.Objects(T) list indicated by the tag value in M.mach_tags.
            //const value_mach_objects = moduleTagValueObjects(M, tag);

            const tagged = TaggedObject{
                .object_id = id,
                .tag_hash = std.hash.Wyhash.hash(0, @tagName(tag)),
            };
            try objs.internal.tags.put(objs.internal.allocator, tagged, value_id);
        }

        /// Removes a tag on an object
        pub fn removeTag(objs: *@This(), id: ObjectID, comptime M: type, tag: ModuleTagEnum(M)) void {
            _ = objs.validateAndUnpack(id, "removeTag");
            const tagged = TaggedObject{
                .object_id = id,
                .tag_hash = std.hash.Wyhash.hash(0, @tagName(tag)),
            };
            _ = objs.internal.tags.remove(tagged);
        }

        /// Whether an object has a tag
        pub fn hasTag(objs: *@This(), id: ObjectID, comptime M: type, tag: ModuleTagEnum(M)) bool {
            _ = objs.validateAndUnpack(id, "hasTag");
            const tagged = TaggedObject{
                .object_id = id,
                .tag_hash = std.hash.Wyhash.hash(0, @tagName(tag)),
            };
            return objs.internal.tags.contains(tagged);
        }

        /// Get an object's tag value, or null.
        pub fn getTag(objs: *@This(), id: ObjectID, comptime M: type, tag: ModuleTagEnum(M)) ?mach.ObjectID {
            _ = objs.validateAndUnpack(id, "getTag");
            const tagged = TaggedObject{
                .object_id = id,
                .tag_hash = std.hash.Wyhash.hash(0, @tagName(tag)),
            };
            return objs.internal.tags.get(tagged) orelse null;
        }

        /// Returns an iterator over all live objects. Excludes any objects which have been freed
        /// or marked for deletion.
        pub fn slice(objs: *@This()) Slice {
            // Sync any cascaded deletions that may have occurred prior to this so our
            // pending_delete bits are up to date.
            objs.internal.graph.sync(objs.internal.allocator) catch {};

            return Slice{
                .index = 0,
                .objs = objs,
            };
        }

        /// Validates the given object is from this list (type check) and alive (not a use after free
        /// situation.)
        fn validateAndUnpack(objs: *const @This(), id: ObjectID, comptime fn_name: []const u8) PackedID {
            const freed = &objs.internal.freed;
            const generation = &objs.internal.generation;

            // TODO(object): decide whether to disable safety checks like this in some conditions,
            // e.g. in release builds
            const unpacked: PackedID = @bitCast(id);
            if (unpacked.type_id != objs.internal.type_id) {
                @panic("mach: " ++ fn_name ++ "() called with object not from this list");
            }
            if (unpacked.generation != generation.items[unpacked.index]) {
                @panic("mach: " ++ fn_name ++ "() called with a freed object (use after free, recycled slot)");
            }
            if (freed.isSet(unpacked.index)) {
                @panic("mach: " ++ fn_name ++ "() called with a freed object (use after free)");
            }
            return unpacked;
        }

        /// If options have tracking enabled, this returns true when the given field has been set
        /// using the set() or setAll() methods. A subsequent call to .updated(), .anyUpdated(), etc.
        /// will return false until another set() or setAll() call is made.
        pub fn updated(objs: *@This(), id: ObjectID, field_name: anytype) bool {
            return objs.updatedOptions(id, field_name, false);
        }

        /// Same as updated(), but doesn't alter the behavior of subsequent .updated(), .anyUpdated(),
        /// etc. calls
        pub fn peekUpdated(objs: *@This(), id: ObjectID, field_name: anytype) bool {
            return objs.updatedOptions(id, field_name, true);
        }

        inline fn updatedOptions(objs: *@This(), id: ObjectID, field_name: anytype, comptime peek: bool) bool {
            if (!options.track_fields) return false;
            const unpacked = objs.validateAndUnpack(id, "updated");
            const field_index = std.meta.fieldIndex(T, @tagName(field_name)).?;
            const updated_fields = &(objs.internal.updated orelse return false);
            const updated_index = unpacked.index * @typeInfo(T).@"struct".field_names.len + field_index;
            const updated_value = updated_fields.isSet(updated_index);
            if (!peek) updated_fields.unset(updated_index);
            return updated_value;
        }

        /// If options have tracking enabled, this returns true when any field has been set using
        /// the set() or setAll() methods. A subsequent call to .updated(), .anyUpdated(), etc. will
        /// return false until another set() or setAll() call is made.
        pub fn anyUpdated(objs: *@This(), id: ObjectID) bool {
            return objs.anyUpdatedOptions(id, false);
        }

        /// Same as anyUpdated(), but doesn't alter the behavior of subsequent .updated(), .anyUpdated(),
        /// etc. calls
        pub fn peekAnyUpdated(objs: *@This(), id: ObjectID) bool {
            return objs.anyUpdatedOptions(id, true);
        }

        inline fn anyUpdatedOptions(objs: *@This(), id: ObjectID, comptime peek: bool) bool {
            if (!options.track_fields) return false;
            const unpacked = objs.validateAndUnpack(id, "updated");
            const updated_fields = &(objs.internal.updated orelse return false);
            var any_updated = false;
            inline for (0..@typeInfo(T).@"struct".field_names.len) |field_index| {
                const updated_index = unpacked.index * @typeInfo(T).@"struct".field_names.len + field_index;
                const updated_value = updated_fields.isSet(updated_index);
                if (!peek) updated_fields.unset(updated_index);
                if (updated_value) any_updated = true;
            }
            return any_updated;
        }

        /// Tells if the given object is from this pool of objects. If it is, then it must also be
        /// alive/valid or else a panic will occur.
        pub fn is(objs: *const @This(), id: ObjectID) bool {
            const unpacked: PackedID = @bitCast(id);
            if (unpacked.type_id != objs.internal.type_id) return false;
            _ = objs.validateAndUnpack(id, "is");
            return true;
        }

        /// Get the parent of the child, or null.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn getParent(objs: *@This(), id: ObjectID) !?ObjectID {
            return objs.internal.graph.getParent(objs.internal.allocator, id);
        }

        /// Set the parent of the child, or no-op if already the case.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn setParent(objs: *@This(), id: ObjectID, parent: ?ObjectID) !void {
            try objs.internal.graph.setParent(objs.internal.allocator, id, parent orelse return objs.internal.graph.removeParent(objs.internal.allocator, id));
        }

        /// Get the children of the parent; returning a results.items slice which is read-only.
        /// Call results.deinit() when you are done to return memory to the graph's memory pool for
        /// reuse later.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn getChildren(objs: *@This(), id: ObjectID) !Graph.Results {
            return objs.internal.graph.getChildren(objs.internal.allocator, id);
        }

        /// Add the given child to the parent, or no-op if already the case.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn addChild(objs: *@This(), id: ObjectID, child: ObjectID) !void {
            return objs.internal.graph.addChild(objs.internal.allocator, id, child);
        }

        /// Remove the given child from the parent, or no-op if not the case.
        ///
        /// Object relations may cross the object-pool boundary; for example the parent or child of
        /// an object in this pool may not itself be in this pool. It might be from a different
        /// pool and a different type of object.
        pub fn removeChild(objs: *@This(), id: ObjectID, child: ObjectID) !void {
            return objs.internal.graph.removeChild(objs.internal.allocator, id, child);
        }

        /// Copies all object data from src into this Objects instance.
        ///
        /// All objects' fields are copied (not a deep copy, so beware of pointer fields!)
        ///
        /// src.graph is not copied, and dst.graph is not modified. Tags are copied. Note that
        /// tags and the graph store object IDs, effectively array indices, not object pointers
        /// or values. The pending_delete bitset is copied (which objects are deleted but not freed)
        /// but is not registered with src.graph or dst.graph for future cascading deletes.
        ///
        /// The copy is optimized for speed rather than memory efficiency, operating under the
        /// assumption that the objects to be copied may be frequently copied from src to dst.
        /// For example, freed to-be-recycled objects are copied too rather than being garbage
        /// collected during the copy process. Additional capacity in arrays is also mirrored
        /// rather than resizing to fit only what is needed, under the assumption that capacity
        /// may be needed in the next copy.
        pub fn copyFrom(dst: *@This(), src: *const @This()) std.mem.Allocator.Error!void {
            // allocator, io, and mu fields are not copied.
            const allocator = dst.internal.allocator;

            // copy type_id
            dst.internal.type_id = src.internal.type_id;

            // copy data
            const src_len = src.internal.data.len;
            try dst.internal.data.ensureTotalCapacity(allocator, src.internal.data.capacity);
            dst.internal.data.len = src_len;
            if (has_fields) {
                const src_slice = src.internal.data.slice();
                const dst_slice = dst.internal.data.slice();
                inline for (0..@typeInfo(StorageT).@"struct".field_names.len) |i| {
                    const field_tag: std.meta.FieldEnum(StorageT) = @fromBackingInt(@intCast(i));
                    @memcpy(dst_slice.items(field_tag)[0..src_len], src_slice.items(field_tag)[0..src_len]);
                }
            }

            // copy freed
            try dst.internal.freed.resize(allocator, src.internal.freed.bit_length, false);
            const MaskInt = std.bit_set.DynamicBitSetUnmanaged.MaskInt;
            const freed_masks = (src.internal.freed.bit_length + @bitSizeOf(MaskInt) - 1) / @bitSizeOf(MaskInt);
            if (freed_masks > 0) {
                @memcpy(dst.internal.freed.masks[0..freed_masks], src.internal.freed.masks[0..freed_masks]);
            }

            // Sync any cascaded deletions that may have occurred prior to this so our
            // pending_delete bits are up to date.
            src.internal.graph.sync(src.internal.allocator) catch {};

            try dst.internal.pending_delete.resize(allocator, src.internal.pending_delete.bit_length, false);
            const pd_masks = (src.internal.pending_delete.bit_length + @bitSizeOf(MaskInt) - 1) / @bitSizeOf(MaskInt);
            if (pd_masks > 0) {
                @memcpy(dst.internal.pending_delete.masks[0..pd_masks], src.internal.pending_delete.masks[0..pd_masks]);
            }

            // copy generation
            try dst.internal.generation.ensureTotalCapacity(allocator, src.internal.generation.capacity);
            dst.internal.generation.items.len = src_len;
            if (src_len > 0) {
                @memcpy(dst.internal.generation.items[0..src_len], src.internal.generation.items[0..src_len]);
            }

            // copy recycling_bin
            try dst.internal.recycling_bin.ensureTotalCapacity(allocator, src.internal.recycling_bin.capacity);
            dst.internal.recycling_bin.items.len = src.internal.recycling_bin.items.len;
            if (src.internal.recycling_bin.items.len > 0) {
                @memcpy(dst.internal.recycling_bin.items, src.internal.recycling_bin.items);
            }

            // copy thrown_on_the_floor
            dst.internal.thrown_on_the_floor = src.internal.thrown_on_the_floor;

            // copy updated
            if (options.track_fields) {
                if (src.internal.updated) |src_updated| {
                    try dst.internal.updated.?.resize(allocator, src_updated.bit_length, false);
                    const updated_masks = (src_updated.bit_length + @bitSizeOf(MaskInt) - 1) / @bitSizeOf(MaskInt);
                    if (updated_masks > 0) {
                        @memcpy(dst.internal.updated.?.masks[0..updated_masks], src_updated.masks[0..updated_masks]);
                    }
                }
            }

            // copy tags
            dst.internal.tags.clearRetainingCapacity();
            try dst.internal.tags.ensureTotalCapacity(allocator, src.internal.tags.capacity());
            var tag_iter = src.internal.tags.iterator();
            while (tag_iter.next()) |entry| {
                dst.internal.tags.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        /// Queries the children of the given object ID (which may be any object, including one not
        /// in this list of objects - and finds the first child which would be from this list of
        /// objects.
        pub fn getFirstChildOfType(objs: *@This(), id: ObjectID) !?ObjectID {
            var children = try objs.getChildren(id);
            defer children.deinit();
            for (children.items) |child_id| {
                if (objs.is(child_id)) return child_id;
            }
            return null;
        }
    };
}

/// Unique identifier for every module in the program, including those only known at runtime.
pub const ModuleID = u32;

/// Unique identifier for a function within a single module, including those only known at runtime.
pub const ModuleFunctionID = u16;

/// Unique identifier for a function within a module, including those only known at runtime.
pub const FunctionID = struct { module_id: ModuleID, fn_id: ModuleFunctionID };

/// The running schedule's frame on this thread, if any. Systems reach it via `ctx.schedule`.
threadlocal var current_schedule_frame: ?*ScheduleContext.Frame = null;

/// Values shared between the systems of a running schedule, instead of being passed through module
/// fields. Available to systems as `ctx.schedule`:
///
/// ```
/// pub const render = mach.schedule(.{
///     .{ App, .beginPass },
///     .{ gfx.Sprite, .render },
///     .{ App, .endPass },
/// });
///
/// pub fn beginPass(ctx: mach.Context, ...) void {
///     ...
///     ctx.schedule.put(.render_pass, encoder.beginRenderPass(...), .{ .end, .release });
/// }
///
/// pub fn endPass(ctx: mach.Context) void {
///     ctx.schedule.remove(.render_pass); // Runs its finalizers now, or else when the schedule ends.
/// }
/// ```
///
/// Each run of a schedule has its own values, stored on the stack of the thread running it:
///
/// * Reads also search the schedules it is nested in, so a nested schedule can see the values of
///   the schedule which called it. Writes only affect the running schedule.
/// * Systems called with `Mod.call` from within a schedule see it too.
/// * Values aren't shared with other threads, or kept between runs. Only the schedule's params are
///   kept between runs, see `scheduleWith`.
///
/// Outside of a schedule there are no values: `get` returns null, and `stop` does nothing.
pub const ScheduleContext = struct {
    frame: ?*Frame = null,

    /// Tracy zone colors (with `-Dtracy`), to tell schedules and their parts apart from systems.
    const trace_colors = struct {
        const schedule = 0x4a7fb5;
        const finalize = 0x9a6a2e;
        const finalizer = 0xc89a5a;
    };

    /// How many values a single run of a schedule can hold.
    pub const max_values = 16;

    /// The largest value that can be stored; put a pointer to anything larger.
    pub const max_value_size = 32;

    const Slot = struct {
        key_hash: u64,
        key_name: []const u8,
        type_id: *const anyopaque,
        type_name: []const u8,
        finalize: ?*const fn (value: *anyopaque) void,
        value: [max_value_size]u8 align(16),

        fn runFinalizers(slot: *Slot) void {
            if (slot.finalize) |finalize| finalize(&slot.value);
        }
    };

    pub const Frame = struct {
        parent: ?*Frame,
        stopped: bool = false,
        params: ?*anyopaque = null,
        params_type: ?*const anyopaque = null,
        len: u8 = 0,
        slots: [max_values]Slot = undefined,

        fn find(frame: *Frame, key_hash: u64) ?usize {
            var i = frame.len;
            while (i > 0) {
                i -= 1;
                if (frame.slots[i].key_hash == key_hash) return i;
            }
            return null;
        }

        fn removeAt(frame: *Frame, index: usize) void {
            for (index..frame.len - 1) |i| frame.slots[i] = frame.slots[i + 1];
            frame.len -= 1;
        }

        fn finalizeAll(frame: *Frame) void {
            while (frame.len > 0) {
                frame.len -= 1;
                frame.slots[frame.len].runFinalizers();
            }
        }
    };

    /// A unique address per type, to identify the type of a stored value.
    fn TypeTag(comptime T: type) type {
        return struct {
            const Type = T;
            var tag: u8 = 0;
        };
    }

    fn keyHash(comptime key: @EnumLiteral()) u64 {
        return comptime std.hash.Wyhash.hash(0, @tagName(key));
    }

    fn checkValueType(comptime T: type) void {
        if (@sizeOf(T) > max_value_size or @alignOf(T) > @alignOf(Slot)) {
            @compileError("mach: value of type " ++ @typeName(T) ++ " is too large for the schedule context, store a pointer to it instead");
        }
    }

    fn slotValue(comptime T: type, comptime key: @EnumLiteral(), slot: *Slot) *T {
        if (slot.type_id != @as(*const anyopaque, &TypeTag(T).tag)) {
            std.debug.panic("mach: schedule value ." ++ @tagName(key) ++ " is a {s}, not a " ++ @typeName(T), .{slot.type_name});
        }
        return @ptrCast(@alignCast(&slot.value));
    }

    /// Returns a function calling each of the finalizers on a value of type `T`, or null if none.
    fn finalizeFn(comptime T: type, comptime key: @EnumLiteral(), comptime finalizers: anytype) ?*const fn (value: *anyopaque) void {
        const info = @typeInfo(@TypeOf(finalizers));
        if (info != .@"struct" or !info.@"struct".is_tuple) {
            @compileError("mach: schedule value finalizers must be a tuple of method names, e.g. .{ .end, .release }, found: " ++ @typeName(@TypeOf(finalizers)));
        }
        if (finalizers.len == 0) return null;

        // Methods are looked up like in a method call: on the type, or the type it points to.
        const Base = switch (@typeInfo(T)) {
            .pointer => |pointer| if (pointer.size == .one) pointer.child else T,
            else => T,
        };
        for (finalizers) |finalizer| {
            if (@typeInfo(@TypeOf(finalizer)) != .enum_literal) {
                @compileError("mach: schedule value finalizer must be a method name, e.g. .release, found: " ++ @typeName(@TypeOf(finalizer)));
            }
            const name = @tagName(finalizer);
            const has_method = switch (@typeInfo(Base)) {
                .@"struct", .@"opaque", .@"union", .@"enum" => @hasDecl(Base, name),
                else => false,
            };
            if (!has_method) @compileError("mach: schedule value of type " ++ @typeName(T) ++ " has no finalizer method ." ++ name);
            const param_types = @typeInfo(@TypeOf(@field(Base, name))).@"fn".param_types;
            if (param_types.len != 1 or (param_types[0] != T and param_types[0] != *T)) {
                @compileError("mach: method ." ++ name ++ " can't be called as a finalizer on a schedule value of type " ++ @typeName(T));
            }
        }
        return (struct {
            fn finalize(value: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(value));
                inline for (finalizers) |finalizer| {
                    // Traced as e.g. `render_pass.end`.
                    const zone = tracy.initZone(@src(), .{
                        .name = @tagName(key) ++ "." ++ @tagName(finalizer),
                        .color = trace_colors.finalizer,
                    });
                    defer zone.deinit();
                    const method = @field(Base, @tagName(finalizer));
                    const arg = if (@typeInfo(@TypeOf(method)).@"fn".param_types[0] == T) typed.* else typed;
                    const Ret = @typeInfo(@TypeOf(method)).@"fn".return_type orelse void;
                    switch (@typeInfo(Ret)) {
                        .error_union => method(arg) catch |err| std.debug.panic("error: {s}", .{@errorName(err)}),
                        else => method(arg),
                    }
                }
            }
        }).finalize;
    }

    /// Stores a value in the running schedule, replacing any value of this key.
    ///
    /// `finalizers` is a tuple of names of methods to call on the value, in order, when it's replaced
    /// or removed, or else when the schedule which put it ends. Values are finalized in the opposite
    /// order they were put. For example `.{ .end, .release }`, or `.{}` for no finalizers.
    ///
    /// Panics if no schedule is running on this thread.
    pub fn put(s: ScheduleContext, comptime key: @EnumLiteral(), value: anytype, comptime finalizers: anytype) void {
        const T = @TypeOf(value);
        comptime checkValueType(T);
        const frame = s.frame orelse @panic("mach: ctx.schedule.put(." ++ @tagName(key) ++ ") called outside of a schedule");
        const hash = comptime keyHash(key);

        if (frame.find(hash)) |index| {
            // The replaced value is finalized only now, in case `value` was derived from it.
            frame.slots[index].runFinalizers();
            frame.removeAt(index);
        }
        if (frame.len == max_values) {
            @panic("mach: ctx.schedule.put(." ++ @tagName(key) ++ ") exceeds ScheduleContext.max_values");
        }

        const slot = &frame.slots[frame.len];
        slot.* = .{
            .key_hash = hash,
            .key_name = @tagName(key),
            .type_id = &TypeTag(T).tag,
            .type_name = @typeName(T),
            .finalize = comptime finalizeFn(T, key, finalizers),
            .value = undefined,
        };
        @as(*T, @ptrCast(@alignCast(&slot.value))).* = value;
        frame.len += 1;
    }

    /// Returns the value of this key from the innermost schedule having it, or null. Panics if it
    /// has a different type than `T`.
    pub fn get(s: ScheduleContext, comptime key: @EnumLiteral(), comptime T: type) ?T {
        const hash = comptime keyHash(key);
        var maybe_frame = s.frame;
        while (maybe_frame) |frame| : (maybe_frame = frame.parent) {
            if (frame.find(hash)) |index| return slotValue(T, key, &frame.slots[index]).*;
        }
        return null;
    }

    /// Same as `get`, for values which the schedule is required to provide: panics if it's missing.
    pub fn require(s: ScheduleContext, comptime key: @EnumLiteral(), comptime T: type) T {
        return s.get(key, T) orelse @panic("mach: schedule has no value ." ++ @tagName(key) ++ ": is the system providing it scheduled before this one?");
    }

    /// Whether this key has a value in the running schedule or those it is nested in.
    pub fn has(s: ScheduleContext, comptime key: @EnumLiteral()) bool {
        const hash = comptime keyHash(key);
        var maybe_frame = s.frame;
        while (maybe_frame) |frame| : (maybe_frame = frame.parent) {
            if (frame.find(hash) != null) return true;
        }
        return false;
    }

    /// Removes a value of the running schedule, running its finalizers now. Does nothing if the
    /// running schedule has no such value.
    pub fn remove(s: ScheduleContext, comptime key: @EnumLiteral()) void {
        const frame = s.frame orelse return;
        const index = frame.find(comptime keyHash(key)) orelse return;
        frame.slots[index].runFinalizers();
        frame.removeAt(index);
    }

    /// Removes a value of the running schedule and returns it without running its finalizers,
    /// handing ownership to the caller. Returns null if the running schedule has no such value.
    pub fn take(s: ScheduleContext, comptime key: @EnumLiteral(), comptime T: type) ?T {
        const frame = s.frame orelse return null;
        const index = frame.find(comptime keyHash(key)) orelse return null;
        const value = slotValue(T, key, &frame.slots[index]).*;
        frame.removeAt(index);
        return value;
    }

    /// Returns the params of the innermost running schedule having params of this type, see
    /// `mach.scheduleWith`. Panics if there is none.
    ///
    /// Params are shared by all runs of the schedule and aren't synchronized, so a schedule run on
    /// multiple threads at once must synchronize access to them itself.
    pub fn params(s: ScheduleContext, comptime P: type) *P {
        var maybe_frame = s.frame;
        while (maybe_frame) |frame| : (maybe_frame = frame.parent) {
            if (frame.params_type == @as(*const anyopaque, &TypeTag(P).tag)) return @ptrCast(@alignCast(frame.params.?));
        }
        @panic("mach: no running schedule has params of type " ++ @typeName(P));
    }

    /// Skips the remaining entries of the running schedule, e.g. when there's nothing to render.
    /// Its values are still finalized, and any schedule it is nested in carries on.
    pub fn stop(s: ScheduleContext) void {
        if (s.frame) |frame| frame.stopped = true;
    }
};

/// Per-module context given to systems which declare a `mach.Context` parameter:
///
/// ```
/// pub fn init(app: *App, ctx: mach.Context) !void {
///     app.items = try std.ArrayList(Item).initCapacity(ctx.allocator, 64);
///     ctx.info("reserved {d} items", .{app.items.capacity});
/// }
/// ```
///
/// Logging through the context uses the module name as the `std.log` scope (so it can be
/// filtered per module with `std_options.log_scope_levels`) and prefixes the running system:
///
/// ```
/// info(app): [init] reserved 64 items
/// ```
///
/// When built with `-Dtracy`, every system run is a Tracy zone named `module.system`, each
/// module's allocator is tracked as a named Tracy memory pool, and context log messages are
/// also sent to Tracy (colored by level).
pub const Context = struct {
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
};

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

/// The usage of a module that isn't metered, because metrics are disabled.
const no_usage: dvx_metrics.AllocatorMetrics = .{};

/// Name of the Tracy plot of a module's pool usage. A type, so the name has one address: Tracy
/// identifies plots by pointer.
fn MemoryPlot(comptime module_name: []const u8) type {
    return struct {
        const name: [:0]const u8 = std.fmt.comptimePrint("mem {s}", .{module_name});
    };
}

/// The Tracy zone of a system or schedule. Its source location is the system's (or the schedule's
/// declaration), so that Tracy's source view shows its code, rather than where it's called from.
/// Resolved from debug info the first time it runs, see `resolveTraceLocation`.
fn SystemTrace(comptime M: type, comptime fn_name: []const u8, comptime debug_name: [:0]const u8) type {
    return struct {
        const is_schedule = isScheduleDecl(@TypeOf(@field(M, fn_name)));

        /// Without file and line until resolved, or if there is no debug info.
        var src_loc: tracy.SourceLocation = .{
            .name = debug_name.ptr,
            .function = @typeName(M) ++ "." ++ fn_name,
            .file = null,
            .line = 0,
            .color = if (is_schedule) ScheduleContext.trace_colors.schedule else 0,
        };
        var resolved: std.atomic.Value(bool) = .init(false);

        inline fn begin() @TypeOf(tracy.initZoneAt(&src_loc, .{})) {
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

/// A `std.Options.logFn` which logs like the default one, and with `-Dtracy` also sends every
/// message to Tracy as `scope: message`, colored by level. Messages from `ctx.log` are sent once,
/// not twice. Set it in the app's root file to see all `std.log` messages in Tracy, including
/// those of mach's platform code and GPU/audio callbacks, which have no `mach.Context`:
///
/// ```
/// pub const std_options: std.Options = .{ .logFn = mach.logFn };
/// ```
///
/// Apps using mach's entrypoint (`mach.addExecutable`) get it by default.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args);
    if (!build_options.tracy) return;
    var buf: [Context.max_log_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(format, args) catch {};
    traceLog(level, @tagName(scope), w.buffered());
}

fn traceLog(level: std.log.Level, scope: []const u8, msg: []const u8) void {
    tracy.printColor("{s}: {s}", .{ scope, msg }, switch (level) {
        .err => 0xff4040,
        .warn => 0xffc040,
        .info => 0xffffff,
        .debug => 0x909090,
    });
}

/// Returns the `Context._log` / `Context._log_enabled` implementations for a module, whose
/// `mach_module` enum literal is used as the `std.log` scope.
fn ContextLog(comptime scope: @EnumLiteral()) type {
    return struct {
        fn enabled(level: std.log.Level) bool {
            // Tracy receives every message regardless of std.log filtering.
            if (build_options.tracy) return true;
            return switch (level) {
                inline else => |l| std.log.logEnabled(l, scope),
            };
        }

        fn log(level: std.log.Level, system_name: []const u8, msg: []const u8) void {
            switch (level) {
                inline else => |l| {
                    const logged = comptime std.log.logEnabled(l, scope);
                    if (logged) {
                        if (system_name.len == 0) {
                            std.options.logFn(l, scope, "{s}", .{msg});
                        } else {
                            std.options.logFn(l, scope, "[{s}] {s}", .{ system_name, msg });
                        }
                    }
                    // mach.logFn has already sent it to Tracy.
                    if (build_options.tracy and !(logged and comptime std.options.logFn == logFn)) {
                        if (system_name.len == 0) {
                            traceLog(l, @tagName(scope), msg);
                        } else {
                            var buf: [Context.max_log_len]u8 = undefined;
                            traceLog(l, @tagName(scope), std.fmt.bufPrint(&buf, "[{s}] {s}", .{ system_name, msg }) catch msg);
                        }
                    }
                },
            }
        }
    };
}

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

fn ScheduleParamsOf(comptime M: type, comptime name: []const u8) type {
    const F = @TypeOf(@field(M, name));
    if (!isScheduleDecl(F) or F.Params == void) {
        @compileError("mach: ." ++ @tagName(M.mach_module) ++ "." ++ name ++ " is not a schedule with params, see mach.scheduleWith()");
    }
    return F.Params;
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
fn ModuleFunctionName(comptime M: type) type {
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
fn ModuleTagEnum(comptime M: type) type {
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
                        var frame: ScheduleContext.Frame = .{ .parent = current_schedule_frame };
                        if (F.Params != void) {
                            frame.params = &@field(m.modules.schedule_params, @tagName(module_name) ++ "." ++ @tagName(fn_name));
                            frame.params_type = &ScheduleContext.TypeTag(F.Params).tag;
                        }
                        current_schedule_frame = &frame;
                        defer {
                            current_schedule_frame = frame.parent;
                            if (frame.len > 0) {
                                const finalize_zone = tracy.initZone(@src(), .{
                                    .name = debug_name ++ " finalize",
                                    .color = ScheduleContext.trace_colors.finalize,
                                });
                                defer finalize_zone.deinit();
                                frame.finalizeAll();
                            }
                        }

                        inline for (F.entries) |schedule_entry| {
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
                            ctx.schedule = .{ .frame = current_schedule_frame };
                            @field(args, arg_name) = ctx;
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
                },
            }
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

fn isValid(comptime module: anytype) bool {
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

test "Objects.sliceField" {
    const test_module = struct {
        pub const mach_module = .test_module;
        things: Objects(.{}, struct { a: u32, b: f32 }),
    };

    //TODO: swap to testing allocator once remainder of deinit implemented
    var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer aa.deinit();
    const allocator = aa.allocator();

    const io = std.Options.debug_io;
    var modules = Modules(.{test_module}){
        .mods = undefined,
        .graph = undefined,
        .io = io,
    };
    try modules.init(allocator, io);
    defer modules.deinit(allocator);

    const things = &modules.mods.test_module.things;
    _ = try things.new(.{ .a = 1, .b = 1.5 });
    const freed = try things.new(.{ .a = 2, .b = 2.5 });
    const deleted = try things.new(.{ .a = 3, .b = 3.5 });
    _ = try things.new(.{ .a = 4, .b = 4.5 });
    things.free(freed);
    things.delete(deleted);

    var as = things.sliceField(.a);
    try std.testing.expectEqual(@as(?u32, 1), as.next());
    try std.testing.expectEqual(@as(?u32, 4), as.next());
    try std.testing.expectEqual(@as(?u32, null), as.next());

    var bs = things.sliceField(.b);
    try std.testing.expectEqual(@as(?f32, 1.5), bs.next());
    try std.testing.expectEqual(@as(?f32, 4.5), bs.next());
    try std.testing.expectEqual(@as(?f32, null), bs.next());

    // Order matches slice()
    var ids = things.slice();
    var values = things.sliceField(.a);
    while (ids.next()) |id| try std.testing.expectEqual(@as(?u32, things.get(id, .a)), values.next());
    try std.testing.expectEqual(@as(?u32, null), values.next());
}

/// A resource which records when it was released, for the schedule tests.
const TestResource = struct {
    id: u8,
    log: *std.ArrayList(u8),

    pub fn release(r: *TestResource) void {
        r.log.appendAssumeCapacity(r.id);
    }
};

test "ScheduleContext: share values, finalize in reverse order when the schedule ends" {
    const a = struct {
        const A = @This();
        pub const mach_module = .a;
        pub const mach_systems = .{ .frame, .begin, .use };

        pub const frame = schedule(.{
            .{ A, .begin },
            .{ A, .use },
        });

        first: TestResource,
        second: TestResource,
        seen: u32,
        released_during_use: usize,

        pub fn begin(m: *A, ctx: Context) void {
            ctx.schedule.put(.first, &m.first, .{.release});
            ctx.schedule.put(.second, &m.second, .{.release});
            ctx.schedule.put(.number, @as(u32, 42), .{});
        }

        pub fn use(m: *A, ctx: Context) void {
            m.seen = ctx.schedule.require(.number, u32);
            m.released_during_use = m.first.log.items.len;
        }
    };

    var buf: [8]u8 = undefined;
    var log: std.ArrayList(u8) = .initBuffer(&buf);

    const allocator = std.testing.allocator;
    var modules: Modules(.{a}) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);
    modules.mods.a.first = .{ .id = 1, .log = &log };
    modules.mods.a.second = .{ .id = 2, .log = &log };

    modules.get(.a).run(.frame);
    try std.testing.expectEqual(42, modules.mods.a.seen);
    try std.testing.expectEqual(0, modules.mods.a.released_during_use);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, log.items);

    // Values don't outlive the run.
    try std.testing.expect(current_schedule_frame == null);
}

test "ScheduleContext: chained schedules across modules" {
    const inner = struct {
        const Inner = @This();
        pub const mach_module = .inner;
        pub const mach_systems = .{ .chain, .readParent };

        pub const chain = schedule(.{
            .{ Inner, .readParent },
        });

        from_parent: ?u32,
        resource: TestResource,

        pub fn readParent(m: *Inner, ctx: Context) void {
            m.from_parent = ctx.schedule.get(.parent_value, u32);
            ctx.schedule.put(.inner_value, @as(u32, 2), .{});
            ctx.schedule.put(.parent_value, @as(u32, 99), .{}); // Shadows, within this schedule.
            ctx.schedule.put(.resource, &m.resource, .{.release});
        }
    };
    const outer = struct {
        const Outer = @This();
        pub const mach_module = .outer;
        pub const mach_systems = .{ .main, .begin, .check };

        pub const main = schedule(.{
            .{ Outer, .begin },
            .{ inner, .chain },
            .{ Outer, .check },
        });

        parent_value_after: ?u32,
        inner_value_after: ?u32,
        released_before_check: usize,
        log: *std.ArrayList(u8),

        pub fn begin(ctx: Context) void {
            ctx.schedule.put(.parent_value, @as(u32, 1), .{});
        }

        pub fn check(m: *Outer, ctx: Context) void {
            m.parent_value_after = ctx.schedule.get(.parent_value, u32);
            m.inner_value_after = ctx.schedule.get(.inner_value, u32);
            m.released_before_check = m.log.items.len;
        }
    };

    var buf: [8]u8 = undefined;
    var log: std.ArrayList(u8) = .initBuffer(&buf);

    const allocator = std.testing.allocator;
    var modules: Modules(.{ outer, inner }) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);
    modules.mods.outer.log = &log;
    modules.mods.inner.resource = .{ .id = 7, .log = &log };

    modules.get(.outer).run(.main);
    try std.testing.expectEqual(1, modules.mods.inner.from_parent);
    try std.testing.expectEqual(1, modules.mods.outer.parent_value_after);
    try std.testing.expectEqual(null, modules.mods.outer.inner_value_after);
    // The nested schedule's values were released when it ended, before the outer one carried on.
    try std.testing.expectEqual(1, modules.mods.outer.released_before_check);
}

test "ScheduleContext: systems called with Mod.call see the schedule" {
    const callee = struct {
        pub const mach_module = .callee;
        pub const mach_systems = .{.read};

        seen: ?u32,

        pub fn read(m: *@This(), ctx: Context) void {
            m.seen = ctx.schedule.get(.value, u32);
        }
    };
    const caller = struct {
        const Caller = @This();
        pub const mach_module = .caller;
        pub const mach_systems = .{ .main, .callIt };

        pub const main = schedule(.{
            .{ Caller, .callIt },
        });

        pub fn callIt(ctx: Context, callee_mod: Mod(callee)) void {
            ctx.schedule.put(.value, @as(u32, 5), .{});
            callee_mod.call(.read);
        }
    };

    const allocator = std.testing.allocator;
    var modules: Modules(.{ caller, callee }) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);

    modules.get(.caller).run(.main);
    try std.testing.expectEqual(5, modules.mods.callee.seen);

    // Outside of a schedule, there are no values.
    modules.get(.callee).run(.read);
    try std.testing.expectEqual(null, modules.mods.callee.seen);
}

test "ScheduleContext: stop skips the rest of the running schedule only" {
    const m = struct {
        const M = @This();
        pub const mach_module = .m;
        pub const mach_systems = .{ .outer, .inner, .stopIt, .neverRuns, .afterInner, .provide };

        pub const outer = schedule(.{
            .{ M, .inner },
            .{ M, .afterInner },
        });

        pub const inner = schedule(.{
            .{ M, .provide },
            .{ M, .stopIt },
            .{ M, .neverRuns },
        });

        resource: TestResource,
        never_ran: bool,
        after_inner_ran: bool,

        pub fn provide(m_: *M, ctx: Context) void {
            ctx.schedule.put(.resource, &m_.resource, .{.release});
        }

        pub fn stopIt(ctx: Context) void {
            ctx.schedule.stop();
        }

        pub fn neverRuns(m_: *M) void {
            m_.never_ran = true;
        }

        pub fn afterInner(m_: *M) void {
            m_.after_inner_ran = true;
        }
    };

    var buf: [8]u8 = undefined;
    var log: std.ArrayList(u8) = .initBuffer(&buf);

    const allocator = std.testing.allocator;
    var modules: Modules(.{m}) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);
    modules.mods.m = .{
        .resource = .{ .id = 3, .log = &log },
        .never_ran = false,
        .after_inner_ran = false,
    };

    modules.get(.m).run(.outer);
    try std.testing.expect(!modules.mods.m.never_ran);
    try std.testing.expect(modules.mods.m.after_inner_ran);
    try std.testing.expectEqualSlices(u8, &.{3}, log.items); // Still released.
}

test "ScheduleContext: replace, remove and take" {
    const m = struct {
        const M = @This();
        pub const mach_module = .m;
        pub const mach_systems = .{ .main, .work };

        pub const main = schedule(.{
            .{ M, .work },
        });

        a: TestResource,
        b: TestResource,
        c: TestResource,
        d: TestResource,
        taken: ?*TestResource,
        has_after_remove: bool,

        pub fn work(m_: *M, ctx: Context) void {
            ctx.schedule.put(.pass, &m_.a, .{.release});
            ctx.schedule.put(.pass, &m_.b, .{.release}); // releases a
            ctx.schedule.remove(.pass); // releases b
            m_.has_after_remove = ctx.schedule.has(.pass);
            ctx.schedule.put(.owned, &m_.c, .{.release});
            m_.taken = ctx.schedule.take(.owned, *TestResource); // never released
            ctx.schedule.put(.last, &m_.d, .{.release}); // released at the end
        }
    };

    var buf: [8]u8 = undefined;
    var log: std.ArrayList(u8) = .initBuffer(&buf);

    const allocator = std.testing.allocator;
    var modules: Modules(.{m}) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);
    modules.mods.m.a = .{ .id = 1, .log = &log };
    modules.mods.m.b = .{ .id = 2, .log = &log };
    modules.mods.m.c = .{ .id = 3, .log = &log };
    modules.mods.m.d = .{ .id = 4, .log = &log };

    modules.get(.m).run(.main);
    try std.testing.expect(!modules.mods.m.has_after_remove);
    try std.testing.expectEqual(&modules.mods.m.c, modules.mods.m.taken.?);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 4 }, log.items);
}

test "ScheduleContext: finalizer methods run in order, on the value or a pointer to it" {
    const Handle = struct {
        id: u8,
        log: *std.ArrayList(u8),

        pub fn close(h: *@This()) void {
            h.log.appendAssumeCapacity(h.id);
        }

        pub fn flush(h: @This()) error{}!void {
            h.log.appendAssumeCapacity(h.id + 1);
        }
    };
    const m = struct {
        const M = @This();
        pub const mach_module = .m;
        pub const mach_systems = .{ .main, .work };

        pub const main = schedule(.{
            .{ M, .work },
        });

        handle: Handle,

        pub fn work(m_: *M, ctx: Context) void {
            ctx.schedule.put(.handle, m_.handle, .{ .flush, .close });
        }
    };

    var buf: [8]u8 = undefined;
    var log: std.ArrayList(u8) = .initBuffer(&buf);

    const allocator = std.testing.allocator;
    var modules: Modules(.{m}) = undefined;
    try modules.init(allocator, std.Options.debug_io);
    defer modules.deinit(allocator);
    modules.mods.m.handle = .{ .id = 1, .log = &log };

    modules.get(.m).run(.main);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, log.items);
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
    try std.testing.expect(std.mem.endsWith(u8, std.mem.span(fn_location.file), "module.zig"));
    // The line of `pub fn system`, just above the @src() in its body.
    try std.testing.expectEqual(src.line - 1, fn_location.line);

    const schedule_location = resolveTraceLocation(@intFromPtr(&m.system), "tick") orelse return error.SkipZigTest;
    try std.testing.expectEqual(src.line - 5, schedule_location.line);
}
