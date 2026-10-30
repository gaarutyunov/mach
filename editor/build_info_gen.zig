//! Build-time generator for build_info.zig (such as Mach and Zig version used.)
//!
//! Usage: build_info_gen <build.zig.zon> <git dir> <output build_info.zig>
//!
//! Generates a build_info.zig file with `mach_version` (git tag or commit SHA) and
//! `mach_zig_version` string constants.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) std.process.fatal("usage: {s} <build.zig.zon> <git dir> <output>", .{args[0]});
    const zon_path = args[1];
    const git_dir = args[2];
    const out_path = args[3];

    // Read the Mach Zig version from build.zig.zon.
    const zon_bytes = Io.Dir.cwd().readFileAlloc(io, zon_path, arena, .limited(1 * 1024 * 1024)) catch |err|
        std.process.fatal("unable to read {s}: {t}", .{ zon_path, err });
    const mach_zig_version = parseMachZigVersion(zon_bytes) orelse
        std.process.fatal("unable to find .mach_zig_version in {s}", .{zon_path});

    // Run git: prefer exact-match tag, otherwise full commit SHA.
    const raw_version = runGit(arena, io, &.{ "git", "-C", git_dir, "describe", "--tags", "--exact-match", "HEAD" }) orelse
        runGit(arena, io, &.{ "git", "-C", git_dir, "rev-parse", "HEAD" }) orelse
        "unknown";
    const mach_version = std.mem.trim(u8, raw_version, " \r\n\t");

    const contents = try std.fmt.allocPrint(arena,
        \\pub const mach_version: []const u8 = "{s}";
        \\pub const mach_zig_version: []const u8 = "{s}";
        \\
    , .{ mach_version, mach_zig_version });

    Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = contents }) catch |err|
        std.process.fatal("unable to write {s}: {t}", .{ out_path, err });
}

fn runGit(arena: std.mem.Allocator, io: Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch return null;
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

fn parseMachZigVersion(zon: []const u8) ?[]const u8 {
    const key = ".mach_zig_version";
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, zon, idx, key)) |k| {
        // Ensure preceding char is whitespace or start, to avoid matching .foo_mach_zig_version
        const prev_ok = k == 0 or std.ascii.isWhitespace(zon[k - 1]) or zon[k - 1] == ',';
        idx = k + key.len;
        if (!prev_ok) continue;
        const start_quote = std.mem.indexOfScalarPos(u8, zon, idx, '"') orelse return null;
        const end_quote = std.mem.indexOfScalarPos(u8, zon, start_quote + 1, '"') orelse return null;
        return zon[start_quote + 1 .. end_quote];
    }
    return null;
}
