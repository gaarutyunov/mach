//! The Mach standard library

const build_options = @import("build-options");
const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.mach);

pub const is_debug = builtin.mode == .debug;

/// The process's command line arguments, set by Mach's entrypoint before the app's main schedule
/// runs (null with a custom entrypoint which doesn't set it).
pub var process_args: ?std.process.Args = null;

// Core
pub const Core = if (build_options.want_core) @import("Core.zig") else struct {};

pub const gfx = if (build_options.want_mach) @import("gfx/main.zig") else struct {};
pub const dvx = if (build_options.want_mach) @import("dvx/main.zig") else struct {};
pub const Audio = if (build_options.want_sysaudio) @import("Audio.zig") else struct {};
pub const math = @import("math/main.zig");
pub const testing = @import("testing.zig");
pub const time = @import("time/main.zig");

pub const sysaudio = if (build_options.want_sysaudio) @import("sysaudio/main.zig") else struct {};
pub const sysgpu = if (build_options.want_sysgpu) @import("sysgpu/main.zig") else struct {};
pub const gpu = if (build_options.want_sysgpu) @import("sysgpu/main.zig").sysgpu else struct {};
/// Compile-time WGSL reflection: derive and check bind group layouts, bind groups, host structs
/// and entry points against a shader.
pub const wgsl = if (build_options.want_sysgpu) @import("wgsl.zig") else struct {};

const module = @import("module.zig");
pub const Context = module.Context;
/// Per-thread recording for the inspector (see `mach.dvx.Inspector`).
pub const module_threads = module.threads;
pub const ModuleMemory = module.ModuleMemory;
pub const FunctionID = module.FunctionID;
pub const Graph = @import("graph.zig").Graph;
pub const PoolAllocator = @import("PoolAllocator.zig");
/// Tracy profiler bindings (zig-tracy). Every call is a no-op unless built with `-Dtracy`.
pub const tracy = @import("tracy");
/// Whether Mach was built with `-Dtracy`.
pub const tracy_enabled = build_options.tracy;
pub const Mod = module.Mod;
pub const ModuleID = module.ModuleID;
pub const Modules = module.Modules;
pub const ModuleFunctionID = module.ModuleFunctionID;
pub const ObjectID = module.ObjectID;
pub const Objects = module.Objects;
pub const Thread = module.Thread;
pub const initGraph = module.initGraph;
pub const schedule = module.schedule;
pub const scheduleWith = module.scheduleWith;
pub const ScheduleContext = module.ScheduleContext;
pub const Require = module.Require;
pub const startThread = module.startThread;
pub const logFn = module.logFn;

/// Dynamic library loading and symbol lookup. Same as `std.DynLib`, except that it also supports
/// Windows (which `std.DynLib` no longer does as of Zig 0.17.)
pub const DynLib = if (builtin.os.tag == .windows) WindowsDynLib else std.DynLib;

const WindowsDynLib = struct {
    module: *anyopaque,

    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

    pub fn open(path: [:0]const u8) error{FileNotFound}!WindowsDynLib {
        return .{ .module = LoadLibraryA(path) orelse return error.FileNotFound };
    }

    pub fn close(self: *WindowsDynLib) void {
        _ = FreeLibrary(self.module);
        self.* = undefined;
    }

    pub fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        const symbol: T = @ptrCast(@alignCast(GetProcAddress(self.module, name) orelse return null));
        return symbol;
    }
};

// Instrumented function to load system libraries and print nicer error
// messages. Accepts a tuple of library names to try in order (e.g.,
// versioned soname first, then unversioned fallback).
pub inline fn dynLibOpen(comptime lib_names: anytype) !DynLib {
    inline for (lib_names) |name| {
        if (DynLib.open(name)) |lib| return lib else |_| {}
    }
    log.err("missing system library, tried:", .{});
    inline for (lib_names) |name| {
        log.err("  * {s}", .{name});
    }
    return error.LibraryNotFound;
}

test {
    // TODO: refactor code so we can use this here:
    // std.testing.refAllDecls(@This());
    _ = Modules;
    _ = Core;
    _ = gpu;
    _ = sysaudio;
    _ = sysgpu;
    _ = wgsl;
    _ = gfx;
    _ = dvx;
    _ = Audio;
    _ = math;
    _ = testing;
    _ = time;
    _ = @import("mpsc.zig");
    _ = @import("graph.zig");
    _ = PoolAllocator;

    std.testing.refAllDecls(math);
}
