//! Values shared between the systems of a running schedule, instead of being passed through module
//! fields. Available to systems as `ctx.schedule`:
//!
//! ```
//! pub const render = mach.schedule(.{
//!     .{ App, .beginPass },
//!     .{ gfx.Sprite, .render },
//!     .{ App, .endPass },
//! });
//!
//! pub fn beginPass(ctx: mach.Context, ...) void {
//!     ...
//!     ctx.schedule.put(.render_pass, encoder.beginRenderPass(...), .{ .end, .release });
//! }
//!
//! pub fn endPass(ctx: mach.Context) void {
//!     ctx.schedule.remove(.render_pass); // Runs its finalizers now, or else when the schedule ends.
//! }
//! ```
//!
//! Each run of a schedule has its own values, stored on the stack of the thread running it:
//!
//! * Reads also search the schedules it is nested in, so a nested schedule can see the values of
//!   the schedule which called it. Writes only affect the running schedule.
//! * Systems called with `Mod.call` from within a schedule see it too.
//! * Values aren't shared with other threads, or kept between runs. Only the schedule's params are
//!   kept between runs, see `scheduleWith`.
//!
//! Outside of a schedule there are no values: `get` returns null, and `stop` does nothing.
const std = @import("std");
const tracy = @import("tracy");

const ScheduleContext = @This();
const trace_colors = @import("trace.zig").colors;
const module = @import("../module.zig");
const Context = @import("Context.zig");
const Modules = module.Modules;
const Mod = module.Mod;
const schedule = @import("schedule.zig").schedule;

/// The running schedule's frame on this thread, if any. Systems reach it via `ctx.schedule`.
pub threadlocal var current_frame: ?*Frame = null;

frame: ?*Frame = null,

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

    pub fn finalizeAll(frame: *Frame) void {
        while (frame.len > 0) {
            frame.len -= 1;
            frame.slots[frame.len].runFinalizers();
        }
    }
};

/// A unique address per type, to identify the type of a stored value.
pub fn TypeTag(comptime T: type) type {
    return struct {
        const Type = T;
        pub var tag: u8 = 0;
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
    try std.testing.expect(current_frame == null);
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
