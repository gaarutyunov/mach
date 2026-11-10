//! Wire protocol between a Mach app (`mach.dvx.Inspector`) and the inspector tool, over a local TCP
//! connection, like Tracy's: the app listens, the tool connects.
//!
//! Every message is a frame: a little-endian u32 length (of what follows), a `Kind` byte, then the
//! payload (JSON).
const std = @import("std");

/// The app listens on the first free port of this range, so several apps can run at once.
pub const first_port: u16 = 8087;
pub const num_ports: u16 = 10;

/// Version of the protocol and snapshot format, increased on incompatible changes.
pub const version = 2;

/// Frames are refused past this size.
pub const max_frame = 256 * 1024 * 1024;

pub const Kind = enum(u8) {
    /// App -> tool, first: `{"version":2,"app":"name","pid":123}`.
    hello = 1,
    /// App -> tool: a snapshot (see `mach.dvx.Inspector.writeSnapshot`).
    snapshot = 2,
    /// Tool -> app: a command, see `Command`.
    command = 3,
    _,
};

/// A command from the tool, as JSON: `{"cmd":"set_param","schedule":"app.render","field":"x",
/// "value":true}`, `{"cmd":"snapshot"}`, `{"cmd":"interval","seconds":0.5}`.
pub const Command = struct {
    cmd: []const u8,
    schedule: []const u8 = "",
    field: []const u8 = "",
    value: bool = false,
    seconds: f64 = 0,
};

pub fn writeFrame(w: *std.Io.Writer, kind: Kind, payload: []const u8) std.Io.Writer.Error!void {
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(payload.len + 1), .little);
    header[4] = @backingInt(kind);
    try w.writeAll(&header);
    try w.writeAll(payload);
    try w.flush();
}

pub const Frame = struct { kind: Kind, payload: []u8 };

/// Reads a frame, allocating its payload with `gpa`.
pub fn readFrame(r: *std.Io.Reader, gpa: std.mem.Allocator) !Frame {
    var header: [5]u8 = undefined;
    try r.readSliceAll(&header);
    const len = std.mem.readInt(u32, header[0..4], .little);
    if (len == 0 or len > max_frame) return error.InvalidFrame;
    const payload = try gpa.alloc(u8, len - 1);
    errdefer gpa.free(payload);
    try r.readSliceAll(payload);
    return .{ .kind = @fromBackingInt(@intCast(header[4])), .payload = payload };
}

test "frames round trip" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrame(&w, .command, "{\"cmd\":\"snapshot\"}");
    var r: std.Io.Reader = .fixed(w.buffered());
    const f = try readFrame(&r, std.testing.allocator);
    defer std.testing.allocator.free(f.payload);
    try std.testing.expectEqual(Kind.command, f.kind);
    try std.testing.expectEqualStrings("{\"cmd\":\"snapshot\"}", f.payload);
}
