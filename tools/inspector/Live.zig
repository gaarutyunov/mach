//! The live connection to a running Mach app (see `mach.dvx.Inspector`), like Tracy's: scans the
//! app ports on 127.0.0.1 until it finds one, keeps the latest snapshot it streams, sends commands,
//! and reconnects when the app goes away.
const std = @import("std");
const mach = @import("mach");
const protocol = mach.dvx.inspector_protocol;

const Live = @This();

pub const Hello = struct { version: u32 = 0, app: []const u8 = "", pid: i64 = 0, port: u16 = 0 };

allocator: std.mem.Allocator,
io: std.Io,
thread: ?std.Thread = null,
stopping: std.atomic.Value(bool) = .init(false),

mutex: std.Io.Mutex = .init,
/// Under `mutex`:
connected: bool = false,
app_buf: [64]u8 = undefined,
app_len: usize = 0,
pid: i64 = 0,
port: u16 = 0,
/// The latest snapshot received and not yet taken.
snapshot: ?[]u8 = null,
snapshots_received: u64 = 0,
stream: ?std.Io.net.Stream = null,

pub fn init(allocator: std.mem.Allocator, io: std.Io) Live {
    return .{ .allocator = allocator, .io = io };
}

pub fn start(l: *Live) !void {
    l.thread = try std.Thread.spawn(.{}, run, .{l});
}

pub fn deinit(l: *Live) void {
    l.stopping.store(true, .release);
    l.mutex.lockUncancelable(l.io);
    if (l.stream) |s| s.shutdown(l.io, .both) catch {};
    l.mutex.unlock(l.io);
    if (l.thread) |t| t.join();
    if (l.snapshot) |s| l.allocator.free(s);
}

/// Takes the latest snapshot received, if any (the caller owns it).
pub fn take(l: *Live) ?[]u8 {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    const s = l.snapshot;
    l.snapshot = null;
    return s;
}

pub const Status = struct { connected: bool, app: []const u8, pid: i64, port: u16, snapshots: u64 };

/// The connection's status; `buf` holds the app name.
pub fn status(l: *Live, buf: []u8) Status {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    const n = @min(buf.len, l.app_len);
    @memcpy(buf[0..n], l.app_buf[0..n]);
    return .{ .connected = l.connected, .app = buf[0..n], .pid = l.pid, .port = l.port, .snapshots = l.snapshots_received };
}

/// Sends a command to the app (see `protocol.Command`), if connected.
pub fn send(l: *Live, command: protocol.Command) void {
    var json: std.Io.Writer.Allocating = .init(l.allocator);
    defer json.deinit();
    std.json.Stringify.value(command, .{}, &json.writer) catch return;
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    const s = l.stream orelse return;
    var buf: [1024]u8 = undefined;
    var w = s.writer(l.io, &buf);
    protocol.writeFrame(&w.interface, .command, json.written()) catch {};
}

fn run(l: *Live) void {
    while (!l.stopping.load(.acquire)) {
        const stream = l.find() orelse {
            l.io.sleep(.fromMilliseconds(500), .awake) catch {};
            continue;
        };
        l.receive(stream);
        stream.close(l.io);
        l.mutex.lockUncancelable(l.io);
        l.connected = false;
        l.stream = null;
        l.mutex.unlock(l.io);
    }
}

/// Connects to the first app found.
fn find(l: *Live) ?std.Io.net.Stream {
    var port = protocol.first_port;
    while (port < protocol.first_port + protocol.num_ports) : (port += 1) {
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        return address.connect(l.io, .{ .mode = .stream }) catch continue;
    }
    return null;
}

fn receive(l: *Live, stream: std.Io.net.Stream) void {
    var buf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(l.io, &buf);
    const hello_frame = protocol.readFrame(&sr.interface, l.allocator) catch return;
    defer l.allocator.free(hello_frame.payload);
    if (hello_frame.kind != .hello) return;
    var arena: std.heap.ArenaAllocator = .init(l.allocator);
    defer arena.deinit();
    const hello = std.json.parseFromSliceLeaky(Hello, arena.allocator(), hello_frame.payload, .{ .ignore_unknown_fields = true }) catch return;
    if (hello.version != protocol.version) {
        std.log.err("inspector: {s} speaks protocol version {d}, this tool {d}: rebuild one of them", .{ hello.app, hello.version, protocol.version });
        l.io.sleep(.fromSeconds(2), .awake) catch {};
        return;
    }
    {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        l.connected = true;
        l.stream = stream;
        l.app_len = @min(hello.app.len, l.app_buf.len);
        @memcpy(l.app_buf[0..l.app_len], hello.app[0..l.app_len]);
        l.pid = hello.pid;
        l.port = hello.port;
    }
    while (!l.stopping.load(.acquire)) {
        const frame = protocol.readFrame(&sr.interface, l.allocator) catch return;
        if (frame.kind != .snapshot) {
            l.allocator.free(frame.payload);
            continue;
        }
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        if (l.snapshot) |old| l.allocator.free(old);
        l.snapshot = frame.payload;
        l.snapshots_received += 1;
    }
}
