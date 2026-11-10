//! Writes the structure and state of a `mach.Modules` as JSON for the inspector: modules, their
//! systems (and what each system's parameters give it access to), schedules and their entries,
//! `mach.Objects` lists with their objects, object relations, and GPU objects referenced from
//! module and object fields. See `mach.dvx.Inspector`.
const std = @import("std");
const schedules = @import("schedule.zig");
const ScheduleContext = @import("ScheduleContext.zig");
const Context = @import("Context.zig");
const dataflow = @import("dataflow.zig");
const threads = @import("threads.zig");

/// Most objects written per `mach.Objects` list.
pub const max_objects_per_list = 256;

pub fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Whether `T` is a pointer to a GPU object (`*gpu.Texture`, `?*gpu.Buffer`, ...).
fn gpuPointerChild(comptime T: type) ?type {
    const P = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one) return null;
    const Child = info.pointer.child;
    if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "release")) return null;
    return Child;
}

fn gpuPointerValue(value: anytype) ?usize {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .optional) return if (value) |v| @intFromPtr(v) else null;
    return @intFromPtr(value);
}

fn typeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // Shorten "module.sub.Type" to its last component, keeping generic arguments readable.
    if (std.mem.indexOfScalar(u8, full, '(') != null) return full;
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |i| return full[i + 1 ..];
    return full;
}

fn writeSystemParams(w: *std.Io.Writer, comptime F: type) !void {
    try w.writeAll("[");
    inline for (@typeInfo(F).@"fn".param_types, 0..) |MaybeT, i| {
        const T = MaybeT orelse @compileError("mach: generic system parameter");
        if (i > 0) try w.writeAll(",");
        if (@typeInfo(T) == .pointer and @typeInfo(std.meta.Child(T)) == .@"struct" and @hasDecl(std.meta.Child(T), "mach_module")) {
            try w.print("{{\"kind\":\"module\",\"module\":\"{s}\",\"mutable\":{}}}", .{ @tagName(std.meta.Child(T).mach_module), !@typeInfo(T).pointer.attrs.@"const" });
        } else if (T == Context) {
            try w.writeAll("{\"kind\":\"context\"}");
        } else if (T == std.Io) {
            try w.writeAll("{\"kind\":\"io\"}");
        } else if (comptime ScheduleContext.isRequire(T)) {
            try w.print("{{\"kind\":\"require\",\"key\":\"{s}\",\"type\":", .{T.key_name});
            try writeString(w, @typeName(T.Value));
            try w.writeAll("}");
        } else if (@typeInfo(T) == .@"struct" and @hasDecl(T, "IsMachMod")) {
            try w.print("{{\"kind\":\"mod\",\"module\":\"{s}\"}}", .{@tagName(T.Module.mach_module)});
        } else {
            try w.writeAll("{\"kind\":\"other\",\"type\":");
            try writeString(w, @typeName(T));
            try w.writeAll("}");
        }
    }
    try w.writeAll("]");
}

const PackedID = packed struct(u64) {
    type_id: u16,
    generation: u16,
    index: u32,
};

/// Whether `id` could be an object ID: its type ID is one of a registered `mach.Objects` list.
fn isObjectId(m: anytype, id: u64) bool {
    const unpacked: PackedID = @bitCast(id);
    return unpacked.type_id < m.name_ids.len;
}

/// Writes `"modules":[...],"objects":[...],"relations":[...],"dataflow":[...]` (without braces).
pub fn write(m: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    @setEvalBranchQuota(100_000);
    if (!dataflow.enabled) return w.writeAll("\"modules\":[],\"dataflow\":[],\"threads\":[]");
    const ModulesT = @TypeOf(m.*);
    try w.writeAll("\"modules\":[");
    inline for (ModulesT.modules, 0..) |M, mi| {
        if (mi > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"type\":", .{@tagName(M.mach_module)});
        try writeString(w, @typeName(M));
        try w.writeAll(",\"systems\":[");
        if (@hasDecl(M, "mach_systems")) {
            inline for (M.mach_systems, 0..) |sys, si| {
                if (si > 0) try w.writeAll(",");
                const F = @TypeOf(@field(M, @tagName(sys)));
                try w.print("{{\"name\":\"{s}\",", .{@tagName(sys)});
                if (comptime schedules.isScheduleDecl(F)) {
                    try w.writeAll("\"kind\":\"schedule\",\"entries\":[");
                    inline for (F.entries, 0..) |entry, ei| {
                        if (ei > 0) try w.writeAll(",");
                        try w.print("{{\"module\":\"{s}\",\"system\":\"{s}\"", .{ @tagName(entry.@"0".mach_module), @tagName(entry.@"1") });
                        if (@typeInfo(@TypeOf(entry)).@"struct".field_names.len > 2) {
                            try w.print(",\"condition\":\"{s}\"", .{@tagName(entry.@"2")});
                        }
                        try w.writeAll("}");
                    }
                    try w.writeAll("],\"params\":[");
                    if (F.Params != void) {
                        const params = &@field(m.schedule_params, @tagName(M.mach_module) ++ "." ++ @tagName(sys));
                        inline for (@typeInfo(F.Params).@"struct".field_names, 0..) |pname, pi| {
                            if (pi > 0) try w.writeAll(",");
                            const v = @field(params, pname);
                            try w.print("{{\"name\":\"{s}\",\"type\":", .{pname});
                            try writeString(w, @typeName(@TypeOf(v)));
                            try w.writeAll(",\"value\":");
                            if (@TypeOf(v) == bool) {
                                try w.print("\"{}\"", .{v});
                            } else if (@TypeOf(v) == std.atomic.Value(bool)) {
                                try w.print("\"{}\"", .{v.raw});
                            } else switch (@typeInfo(@TypeOf(v))) {
                                .int, .float => try w.print("\"{d}\"", .{v}),
                                else => try w.writeAll("null"),
                            }
                            try w.writeAll("}");
                        }
                    }
                    try w.writeAll("]}");
                } else {
                    try w.writeAll("\"kind\":\"fn\",\"params\":");
                    try writeSystemParams(w, F);
                    try w.writeAll("}");
                }
            }
        }
        try w.writeAll("],\"lists\":[");
        const mod = &@field(m.mods, @tagName(M.mach_module));
        comptime var list_index = 0;
        inline for (@typeInfo(M).@"struct".field_names, @typeInfo(M).@"struct".field_types) |fname, FT| {
            if (@typeInfo(FT) == .@"struct" and @hasDecl(FT, "IsMachObjects")) {
                if (list_index > 0) try w.writeAll(",");
                list_index += 1;
                const objs = &@field(mod, fname);
                try w.print("{{\"name\":\"{s}\",\"type_id\":{d},\"address\":{d},\"fields\":[", .{ fname, objs.internal.type_id, @intFromPtr(objs) });
                const T = @typeInfo(@TypeOf(FT.getValue)).@"fn".return_type.?;
                inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, 0..) |n, FFT, fi| {
                    if (fi > 0) try w.writeAll(",");
                    try w.print("{{\"name\":\"{s}\",\"type\":", .{n});
                    try writeString(w, typeName(FFT));
                    try w.print(",\"gpu\":{}}}", .{gpuPointerChild(FFT) != null});
                }
                objs.lockShared();
                defer objs.unlockShared();
                var live: usize = 0;
                const n = objs.internal.generation.items.len;
                for (0..n) |i| {
                    if (!objs.internal.freed.isSet(i) and !objs.internal.pending_delete.isSet(i)) live += 1;
                }
                try w.print("],\"live\":{d},\"slots\":{d},\"capacity\":{d},\"objects\":[", .{ live, n, objs.internal.data.capacity });
                var written: usize = 0;
                for (0..n) |i| {
                    if (objs.internal.freed.isSet(i) or objs.internal.pending_delete.isSet(i)) continue;
                    if (written == max_objects_per_list) break;
                    if (written > 0) try w.writeAll(",");
                    written += 1;
                    const id: u64 = @bitCast(PackedID{ .type_id = objs.internal.type_id, .generation = objs.internal.generation.items[i], .index = @intCast(i) });
                    try w.print("{{\"id\":{d},\"index\":{d},\"gpu\":[", .{ id, i });
                    const value = objs.internal.data.get(i);
                    var gi: usize = 0;
                    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |gname, GT| {
                        if (comptime gpuPointerChild(GT) != null and @hasField(@TypeOf(value), gname)) {
                            if (gpuPointerValue(@field(value, gname))) |ptr| {
                                if (gi > 0) try w.writeAll(",");
                                gi += 1;
                                try w.print("{{\"field\":\"{s}\",\"ptr\":{d}}}", .{ gname, ptr });
                            }
                        }
                    }
                    try w.writeAll("],\"refs\":[");
                    // Fields holding object IDs of other lists, e.g. `.window`, `.render_list`.
                    var ri: usize = 0;
                    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |rname, RT| {
                        if (@hasField(@TypeOf(value), rname)) {
                            const v = @field(value, rname);
                            if (RT == u64 or RT == ?u64) {
                                // Only values which look like object IDs (of a registered
                                // list), not e.g. hashes.
                                if (@as(?u64, v)) |ref| if (isObjectId(m, ref)) {
                                    if (ri > 0) try w.writeAll(",");
                                    ri += 1;
                                    try w.print("{{\"field\":\"{s}\",\"id\":{d}}}", .{ rname, ref });
                                };
                            } else if (RT == std.ArrayList(u64)) {
                                for (v.items[0..@min(v.items.len, 64)]) |ref| {
                                    if (ri > 0) try w.writeAll(",");
                                    ri += 1;
                                    try w.print("{{\"field\":\"{s}\",\"id\":{d}}}", .{ rname, ref });
                                }
                                if (v.items.len > 64) {
                                    if (ri > 0) try w.writeAll(",");
                                    ri += 1;
                                    try w.print("{{\"field\":\"{s}\",\"more\":{d}}}", .{ rname, v.items.len - 64 });
                                }
                            }
                        }
                    }
                    try w.writeAll("],\"children\":[");
                    if (written <= 128) {
                        if (objs.getChildren(id)) |children| {
                            defer children.deinit();
                            for (children.items, 0..) |c, ci| {
                                if (ci > 0) try w.writeAll(",");
                                try w.print("{d}", .{c});
                            }
                        } else |_| {}
                    }
                    try w.writeAll("]}");
                }
                try w.writeAll("]}");
            }
        }
        try w.writeAll("],\"gpu_fields\":[");
        var gfi: usize = 0;
        inline for (@typeInfo(M).@"struct".field_names, @typeInfo(M).@"struct".field_types) |fname, FT| {
            if (comptime gpuPointerChild(FT) != null) {
                // Module fields may be `undefined` until set up: only trust non-null optionals.
                if (@typeInfo(FT) == .optional) {
                    if (gpuPointerValue(@field(mod, fname))) |ptr| {
                        if (gfi > 0) try w.writeAll(",");
                        gfi += 1;
                        try w.print("{{\"field\":\"{s}\",\"ptr\":{d}}}", .{ fname, ptr });
                    }
                }
            }
        }
        try w.writeAll("]");
        // Memory, if the module has a pool or is metered.
        if (@field(m.pools, @tagName(M.mach_module))) |*pool| {
            try w.print(",\"memory\":{{\"used\":{d},\"peak\":{d},\"budget\":{d}}}", .{ pool.metrics.used_bytes.loadUsize(), pool.metrics.peak_bytes.loadUsize(), pool.buffer.len });
        } else if (@field(m.metered_allocators, @tagName(M.mach_module))) |*metered| {
            try w.print(",\"memory\":{{\"used\":{d},\"peak\":{d},\"budget\":0}}", .{ metered.metrics.used_bytes.loadUsize(), metered.metrics.peak_bytes.loadUsize() });
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"dataflow\":");
    try dataflow.writeJson(w, writeString);
    try w.writeAll(",\"threads\":");
    try threads.writeJson(w, writeString, m.io);
}

/// Sets a bool (or `std.atomic.Value(bool)`) param of a schedule declared with `mach.scheduleWith`,
/// by name ("module.schedule" and the field). Returns whether there was such a param.
pub fn setScheduleParam(m: anytype, schedule_name: []const u8, field: []const u8, value: bool) bool {
    if (!dataflow.enabled) return false;
    const ParamsT = @TypeOf(m.schedule_params);
    inline for (@typeInfo(ParamsT).@"struct".field_names) |name| {
        if (std.mem.eql(u8, name, schedule_name)) {
            const params = &@field(m.schedule_params, name);
            inline for (@typeInfo(@TypeOf(params.*)).@"struct".field_names) |f| {
                if (std.mem.eql(u8, f, field)) {
                    const T = @TypeOf(@field(params, f));
                    if (T == bool) {
                        @field(params, f) = value;
                        return true;
                    } else if (T == std.atomic.Value(bool)) {
                        @field(params, f).store(value, .release);
                        return true;
                    }
                }
            }
        }
    }
    return false;
}
