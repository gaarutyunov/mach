const std = @import("std");
const app = @import("app");
const mach = @import("mach");

/// The app's own `std_options` if it has some, or else logging through `mach.logFn`, which also
/// sends every `std.log` message to Tracy (with `-Dtracy`).
pub const std_options: std.Options = if (@hasDecl(app, "std_options")) app.std_options else .{ .logFn = mach.logFn };

pub fn main(init: std.process.Init.Minimal) !void {
    mach.process_args = init.args;
    var io_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = io_threaded.io();

    // The set of Mach modules our application may use.
    var mods: app.Modules = undefined;
    if (@hasDecl(app, "machInit")) {
        // The app chooses its own allocators, e.g.:
        //
        // pub fn machInit(mods: *Modules, io: std.Io) !void {
        //     try mods.initOptions(gpa, io, .{ .allocators = .{ .mach_gfx_sprite = pool } });
        // }
        try app.machInit(&mods, io);
    } else {
        try mods.init(std.heap.c_allocator, io);
    }
    // TODO: enable mods.deinit(allocator); for allocator leak detection
    // defer mods.deinit(allocator);

    const app_mod = mods.get(.app);
    app_mod.run(.main);
}
