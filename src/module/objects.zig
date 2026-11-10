//! `mach.Objects`: lists of objects owned by a module, with fields, tags and graph relations.
const std = @import("std");
const mach = @import("../main.zig");
const module = @import("../module.zig");
const Graph = @import("../graph.zig").Graph;
const threads = @import("threads.zig");
const Modules = module.Modules;

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
            const locked = objs.internal.mu.tryLock(objs.internal.io);
            if (locked) threads.listLocked(objs);
            return locked;
        }

        /// Acquires the mutex, blocking the caller's thread until it can.
        /// It is undefined behavior if the mutex is already held by the caller's thread.
        /// Once acquired, call `unlock()` on the Mutex to release it.
        pub fn lock(objs: *@This()) void {
            objs.internal.mu.lockUncancelable(objs.internal.io);
            threads.listLocked(objs);
        }

        /// Releases the mutex which was previously acquired with `lock()` or `tryLock()`.
        /// It is undefined behavior if the mutex is unlocked from a different thread that it was locked from.
        pub fn unlock(objs: *@This()) void {
            threads.listUnlocked(objs);
            objs.internal.mu.unlock(objs.internal.io);
        }

        /// Tries to acquire a shared (read) lock without blocking the caller's thread.
        ///
        /// Returns `false` if the calling thread would have to block to acquire it.
        /// Otherwise, returns `true` and the caller should call `unlockShared()` to release it.
        pub fn tryLockShared(objs: *@This()) bool {
            const locked = objs.internal.mu.tryLockShared(objs.internal.io);
            if (locked) threads.listLocked(objs);
            return locked;
        }

        /// Acquires a shared (read) lock, blocking the caller's thread until it can.
        /// Multiple readers may hold the lock concurrently, but no writer may hold it while readers
        /// do.
        /// Once acquired, call `unlockShared()` on the Mutex to release it.
        pub fn lockShared(objs: *@This()) void {
            objs.internal.mu.lockSharedUncancelable(objs.internal.io);
            threads.listLocked(objs);
        }

        /// Releases the shared (reader) lock which was previously acquired with `lockShared()` or
        /// `tryLockShared()`.
        pub fn unlockShared(objs: *@This()) void {
            threads.listUnlocked(objs);
            objs.internal.mu.unlockShared(objs.internal.io);
        }

        pub fn new(objs: *@This(), value: T) std.mem.Allocator.Error!ObjectID {
            threads.listAccess(objs, true);
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
            threads.listAccess(objs, true);
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "setValueRaw");
            data.set(unpacked.index, toStorage(value));
        }

        /// Sets all fields of the given object to the given value.
        ///
        /// Unlike setAllRaw, this method respects mach.Objects tracking
        /// and changes made to an object through this method will be tracked.
        pub fn setValue(objs: *@This(), id: ObjectID, value: T) void {
            threads.listAccess(objs, true);
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
            threads.listAccess(objs, true);
            const data = &objs.internal.data;
            const unpacked = objs.validateAndUnpack(id, "setRaw");

            data.items(field_name)[unpacked.index] = value;
        }

        /// Sets a single field of the given object to the given value.
        ///
        /// Unlike setAllRaw, this method respects mach.Objects tracking
        /// and changes made to an object through this method will be tracked.
        pub fn set(objs: *@This(), id: ObjectID, comptime field_name: std.meta.FieldEnum(T), value: @FieldType(T, @tagName(field_name))) void {
            threads.listAccess(objs, true);
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
            threads.listAccess(objs, false);
            const data = &objs.internal.data;

            const unpacked = objs.validateAndUnpack(id, "get");
            return data.items(field_name)[unpacked.index];
        }

        /// Get all fields.
        pub fn getValue(objs: *@This(), id: ObjectID) T {
            threads.listAccess(objs, false);
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
            threads.listAccess(objs, true);
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
            threads.listAccess(objs, true);
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
        pub fn setTag(objs: *@This(), id: ObjectID, comptime M: type, tag: module.ModuleTagEnum(M), value_id: ?ObjectID) !void {
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
        pub fn removeTag(objs: *@This(), id: ObjectID, comptime M: type, tag: module.ModuleTagEnum(M)) void {
            _ = objs.validateAndUnpack(id, "removeTag");
            const tagged = TaggedObject{
                .object_id = id,
                .tag_hash = std.hash.Wyhash.hash(0, @tagName(tag)),
            };
            _ = objs.internal.tags.remove(tagged);
        }

        /// Whether an object has a tag
        pub fn hasTag(objs: *@This(), id: ObjectID, comptime M: type, tag: module.ModuleTagEnum(M)) bool {
            _ = objs.validateAndUnpack(id, "hasTag");
            const tagged = TaggedObject{
                .object_id = id,
                .tag_hash = std.hash.Wyhash.hash(0, @tagName(tag)),
            };
            return objs.internal.tags.contains(tagged);
        }

        /// Get an object's tag value, or null.
        pub fn getTag(objs: *@This(), id: ObjectID, comptime M: type, tag: module.ModuleTagEnum(M)) ?mach.ObjectID {
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

        /// Whether the given object is from this pool of objects and alive (not freed, nor marked for
        /// deletion). Unlike `is`, never panics: for IDs which may be stale, e.g. ones from a
        /// render snapshot while the app thread deletes objects.
        pub fn isAlive(objs: *const @This(), id: ObjectID) bool {
            const unpacked: PackedID = @bitCast(id);
            if (unpacked.type_id != objs.internal.type_id) return false;
            if (unpacked.index >= objs.internal.generation.items.len) return false;
            if (objs.internal.generation.items[unpacked.index] != unpacked.generation) return false;
            if (objs.internal.freed.isSet(unpacked.index)) return false;
            return !objs.internal.pending_delete.isSet(unpacked.index);
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
            threads.listAccess(dst, true);
            threads.listAccess(src, false);
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
