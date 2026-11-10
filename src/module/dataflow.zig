//! Records which systems put and read which schedule values (`ctx.schedule.put/get/...`), for the
//! inspector's dataflow graph. Recording only happens with `-Dinspector` and once
//! `start()` has been called, and each (system, key, access) is recorded once.
const std = @import("std");
const build_options = @import("build-options");

pub const enabled = build_options.inspector;

/// The system running on this thread, e.g. "app.beginFrame".
pub threadlocal var current_system: []const u8 = "";

pub const Access = enum(u8) { put, get, take, remove };

pub const Entry = struct {
    system: []const u8,
    key: []const u8,
    type_name: []const u8,
    access: Access,
    count: u64,
};

const max_entries = 512;

var recording: std.atomic.Value(bool) = .init(false);
var mutex: std.atomic.Mutex = .unlocked;
var entries: [max_entries]Entry = undefined;
var len: usize = 0;

pub fn start() void {
    if (!enabled) return;
    recording.store(true, .release);
}

pub fn isRecording() bool {
    return enabled and recording.load(.monotonic);
}

pub fn record(key: []const u8, type_name: []const u8, access: Access) void {
    if (!isRecording()) return;
    const system = current_system;
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();
    for (entries[0..len]) |*e| {
        // Names are comptime strings: comparing pointers is enough.
        if (e.system.ptr == system.ptr and e.key.ptr == key.ptr and e.access == access) {
            e.count += 1;
            return;
        }
    }
    if (len == max_entries) return;
    entries[len] = .{ .system = system, .key = key, .type_name = type_name, .access = access, .count = 1 };
    len += 1;
}

/// Writes the recorded accesses as a JSON array.
pub fn writeJson(w: *std.Io.Writer, writeString: anytype) std.Io.Writer.Error!void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();
    try w.writeAll("[");
    for (entries[0..len], 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"system\":");
        try writeString(w, e.system);
        try w.writeAll(",\"key\":");
        try writeString(w, e.key);
        try w.writeAll(",\"type\":");
        try writeString(w, e.type_name);
        try w.print(",\"access\":\"{s}\",\"count\":{d}}}", .{ @tagName(e.access), e.count });
    }
    try w.writeAll("]");
}
