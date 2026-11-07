//! Logging of `mach.Context`, and `mach.logFn`.
const std = @import("std");
const tracy = @import("tracy");
const build_options = @import("build-options");
const Context = @import("Context.zig");

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
pub fn ContextLog(comptime scope: @EnumLiteral()) type {
    return struct {
        pub fn enabled(level: std.log.Level) bool {
            // Tracy receives every message regardless of std.log filtering.
            if (build_options.tracy) return true;
            return switch (level) {
                inline else => |l| std.log.logEnabled(l, scope),
            };
        }

        pub fn log(level: std.log.Level, system_name: []const u8, msg: []const u8) void {
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
