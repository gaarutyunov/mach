const std = @import("std");
const app = @import("app");

pub fn main() !void {
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
