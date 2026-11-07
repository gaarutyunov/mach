//! Static check that GPU resources acquired in a function get released, see `addGpuLint` in
//! build.zig. Run with `zig build lint-gpu`.
//!
//! For each local variable initialized by a call acquiring a GPU resource (see `acquiring_calls`),
//! reports an error unless, within the block which declares it, the variable is either:
//!
//! * released: `x.release()`, including in a `defer`
//! * put in a schedule to be released: `ctx.schedule.put(.key, x, .{.release})`
//! * handed over to something else: returned, assigned, stored in a struct field or container
//!
//! This is a heuristic working on tokens, since Zig's comptime can't see runtime values, and has
//! limits: it can't tell if a release is reached on all paths, nor whether a resource stored
//! in a field is ever released, and doesn't check resources which aren't assigned to a variable.
//! Silence a finding with a `// gpu-lint: ignore` comment on the line.

const std = @import("std");
const Tokenizer = std.zig.Tokenizer;
const Token = std.zig.Token;

/// Methods returning a GPU resource which the caller must release.
const acquiring_calls = std.StaticStringMap(void).initComptime(.{
    .{"beginComputePass"},
    .{"beginRenderPass"},
    .{"createBindGroup"},
    .{"createBindGroupLayout"},
    .{"createBuffer"},
    .{"createCommandEncoder"},
    .{"createComputePipeline"},
    .{"createPipelineLayout"},
    .{"createQuerySet"},
    .{"createRenderBundleEncoder"},
    .{"createRenderPipeline"},
    .{"createSampler"},
    .{"createShaderModule"},
    .{"createShaderModuleWGSL"},
    .{"createTexture"},
    .{"createView"},
    .{"getBindGroupLayout"},
    .{"getCurrentTextureView"},
});

/// Struct fields which only borrow a resource for the duration of a call, such as in a descriptor:
/// assigning a resource to one of these doesn't hand it over.
const borrowing_fields = std.StaticStringMap(void).initComptime(.{
    .{"buffer"},
    .{"compute"},
    .{"fragment"},
    .{"layout"},
    .{"module"},
    .{"resolve_target"},
    .{"sampler"},
    .{"texture_view"},
    .{"vertex"},
    .{"view"},
});

/// Methods which store their arguments, handing them over to the receiver.
const storing_calls = std.StaticStringMap(void).initComptime(.{
    .{"append"},
    .{"appendAssumeCapacity"},
    .{"new"},
    .{"set"},
    .{"setRaw"},
    .{"setValue"},
    .{"setValueRaw"},
});

pub const Finding = struct {
    line: usize,
    column: usize,
    variable: []const u8,
    call: []const u8,
};

const Lint = struct {
    source: [:0]const u8,
    tags: []const Token.Tag,
    locs: []const Token.Loc,

    fn text(l: Lint, i: usize) []const u8 {
        return l.source[l.locs[i].start..l.locs[i].end];
    }

    fn tag(l: Lint, i: usize) Token.Tag {
        return if (i < l.tags.len) l.tags[i] else .eof;
    }

    fn isIdentifier(l: Lint, i: usize, name: []const u8) bool {
        return l.tag(i) == .identifier and std.mem.eql(u8, l.text(i), name);
    }

    /// If the statement starting at `start` calls an acquiring method outside of any brackets,
    /// returns the method's token. Sets `end` to the end of the statement.
    fn acquiringCall(l: Lint, start: usize, end: *usize) ?usize {
        var depth: usize = 0;
        var call: ?usize = null;
        var i = start;
        while (true) : (i += 1) {
            switch (l.tag(i)) {
                .eof => break,
                .l_paren, .l_brace, .l_bracket => depth += 1,
                .r_paren, .r_brace, .r_bracket => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                .semicolon => if (depth == 0) break,
                .identifier => if (depth == 0 and call == null and
                    l.tag(i -| 1) == .period and l.tag(i + 1) == .l_paren and
                    acquiring_calls.has(l.text(i)))
                {
                    call = i;
                },
                else => {},
            }
        }
        end.* = i;
        return call;
    }

    /// Whether the variable named `name` is released or handed over between token `start` and the
    /// end of the block containing it.
    fn isHandled(l: Lint, name: []const u8, start: usize) bool {
        var depth: usize = 0;
        var i = start;
        while (true) : (i += 1) {
            switch (l.tag(i)) {
                .eof => return false,
                .l_brace => depth += 1,
                .r_brace => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .identifier => if (std.mem.eql(u8, l.text(i), name) and l.tag(i -| 1) != .period and l.handledAt(i)) return true,
                else => {},
            }
        }
    }

    /// Whether this use of the variable at token `i` releases or hands it over.
    fn handledAt(l: Lint, i: usize) bool {
        const next = l.tag(i + 1);

        // x.release()
        if (next == .period) return l.isIdentifier(i + 2, "release") and l.tag(i + 3) == .l_paren;

        // = if (owned) x else null
        if (next == .keyword_else) {
            const open = l.matchingOpen(i - 1) orelse return false;
            return open >= 2 and l.tag(open - 1) == .keyword_if and l.tag(open - 2) == .equal and l.assignmentHandsOver(open - 2);
        }

        // Only uses of the variable's value by itself can hand it over.
        if (next != .semicolon and next != .comma and next != .r_paren and next != .r_brace) return false;
        return switch (l.tag(i - 1)) {
            // return x;
            .keyword_return => true,
            .equal => l.assignmentHandsOver(i - 1),
            .comma, .l_paren => l.handedToCall(i),
            else => false,
        };
    }

    /// Whether assigning a variable using the `=` at token `equal` hands it over.
    fn assignmentHandsOver(l: Lint, equal: usize) bool {
        // .field = x, in a struct initializer.
        if (l.tag(equal - 1) == .identifier and l.tag(equal -| 2) == .period and l.tag(equal -| 3) != .identifier) {
            return !borrowing_fields.has(l.text(equal - 1));
        }
        // a.b = x; or an alias: const y = x;
        return true;
    }

    /// Returns the token opening the parentheses closed by the token `close`.
    fn matchingOpen(l: Lint, close: usize) ?usize {
        if (l.tag(close) != .r_paren) return null;
        var depth: usize = 0;
        var i = close;
        while (i > 0) {
            i -= 1;
            switch (l.tag(i)) {
                .r_paren => depth += 1,
                .l_paren => {
                    if (depth == 0) return i;
                    depth -= 1;
                },
                else => {},
            }
        }
        return null;
    }

    /// Whether the variable at token `i`, which is a call argument, is handed over by the call.
    fn handedToCall(l: Lint, i: usize) bool {
        // Find the opening of the call.
        var depth: usize = 0;
        var open = i;
        while (open > 0) {
            open -= 1;
            switch (l.tag(open)) {
                .r_paren, .r_brace, .r_bracket => depth += 1,
                .l_brace, .l_bracket => {
                    if (depth == 0) return false; // In a tuple or array, not directly an argument.
                    depth -= 1;
                },
                .l_paren => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                else => {},
            }
        }
        if (open == 0 or l.tag(open - 1) != .identifier or l.tag(open -| 2) != .period) return false;

        const method = l.text(open - 1);
        if (storing_calls.has(method)) return true;
        if (!std.mem.eql(u8, method, "put")) return false;

        // ctx.schedule.put(.key, x, .{.release})
        return l.tag(i + 1) == .comma and l.tag(i + 2) == .period and l.tag(i + 3) == .l_brace and
            l.finalizersRelease(i + 4);
    }

    fn finalizersRelease(l: Lint, start: usize) bool {
        var i = start;
        while (l.tag(i) != .r_brace and l.tag(i) != .eof) : (i += 1) {
            if (l.isIdentifier(i, "release") and l.tag(i - 1) == .period) return true;
        }
        return false;
    }

    fn isIgnored(l: Lint, offset: usize) bool {
        const line_end = std.mem.indexOfScalarPos(u8, l.source, offset, '\n') orelse l.source.len;
        return std.mem.indexOf(u8, l.source[offset..line_end], "gpu-lint: ignore") != null;
    }
};

/// Returns the findings for one source file. Their names point into `source`.
pub fn lintSource(allocator: std.mem.Allocator, source: [:0]const u8) std.mem.Allocator.Error![]Finding {
    var tags: std.ArrayList(Token.Tag) = .empty;
    defer tags.deinit(allocator);
    var locs: std.ArrayList(Token.Loc) = .empty;
    defer locs.deinit(allocator);
    var tokenizer: Tokenizer = .init(source);
    while (true) {
        const token = tokenizer.next();
        try tags.append(allocator, token.tag);
        try locs.append(allocator, token.loc);
        if (token.tag == .eof) break;
    }
    const lint: Lint = .{ .source = source, .tags = tags.items, .locs = locs.items };

    var findings: std.ArrayList(Finding) = .empty;
    errdefer findings.deinit(allocator);
    for (tags.items, 0..) |tag, i| {
        if (tag != .keyword_const and tag != .keyword_var) continue;
        if (lint.tag(i + 1) != .identifier) continue;

        // const x = ... or const x: T = ...
        var value = i + 2;
        if (lint.tag(value) == .colon) {
            while (lint.tag(value) != .equal and lint.tag(value) != .semicolon and lint.tag(value) != .eof) value += 1;
        }
        if (lint.tag(value) != .equal) continue;

        var end: usize = undefined;
        const call = lint.acquiringCall(value + 1, &end) orelse continue;
        const name = lint.text(i + 1);
        if (lint.isHandled(name, end) or lint.isIgnored(locs.items[i].start)) continue;

        const location = std.zig.findLineColumn(source, locs.items[i + 1].start);
        try findings.append(allocator, .{
            .line = location.line + 1,
            .column = location.column + 1,
            .variable = name,
            .call = lint.text(call),
        });
    }
    return findings.toOwnedSlice(allocator);
}

fn lintFile(io: std.Io, arena: std.mem.Allocator, stderr: *std.Io.Writer, dir: std.Io.Dir, path: []const u8) !usize {
    const source = try dir.readFileAllocOptions(io, path, arena, .limited(64 * 1024 * 1024), .of(u8), 0);
    const findings = try lintSource(arena, source);
    for (findings) |f| {
        try stderr.print("{s}:{d}:{d}: error: GPU resource '{s}' from {s}() is never released\n", .{ path, f.line, f.column, f.variable, f.call });
    }
    return findings.len;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var num_findings: usize = 0;
    const cwd = std.Io.Dir.cwd();
    for (args[1..]) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) {
            num_findings += try lintFile(io, arena, stderr, cwd, path);
            continue;
        }
        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const full_path = try std.fs.path.join(arena, &.{ path, entry.path });
            num_findings += try lintFile(io, arena, stderr, cwd, full_path);
        }
    }
    try stderr.flush();
    if (num_findings > 0) std.process.exit(1);
}

fn expectFindings(source: [:0]const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const findings = try lintSource(allocator, source);
    defer allocator.free(findings);
    try std.testing.expectEqual(expected.len, findings.len);
    for (findings, expected) |f, name| try std.testing.expectEqualStrings(name, f.variable);
}

test "reports resources which aren't released" {
    try expectFindings(
        \\fn f() void {
        \\    const encoder = device.createCommandEncoder(&.{});
        \\    const view = swap_chain.getCurrentTextureView() orelse return;
        \\    const attachment: Attachment = .{ .view = view };
        \\    encoder.finish(&.{});
        \\}
    , &.{ "encoder", "view" });
}

test "a release in another block doesn't count" {
    try expectFindings(
        \\fn f() void {
        \\    {
        \\        const pass = encoder.beginRenderPass(&desc);
        \\        pass.end();
        \\    }
        \\    {
        \\        const pass = encoder.beginRenderPass(&desc);
        \\        pass.release();
        \\    }
        \\}
    , &.{"pass"});
}

test "accepts released and handed over resources" {
    try expectFindings(
        \\fn released() void {
        \\    const a = device.createBuffer(&.{});
        \\    defer a.release();
        \\    const b = try device.createBuffer(&.{});
        \\    b.release();
        \\}
        \\fn returned() *gpu.Buffer {
        \\    const a = device.createBuffer(&.{});
        \\    return a;
        \\}
        \\fn stored(app: *App) void {
        \\    const a = device.createBuffer(&.{});
        \\    app.buffer = a;
        \\    const b = device.createTexture(&.{});
        \\    const pipeline = .{ .texture = b };
        \\    const c = device.createSampler(&.{});
        \\    objects.set(id, .sampler, c);
        \\    const d = device.createBindGroupLayout(&.{});
        \\    const built = .{ .bind_group_layout = if (owned) d else null };
        \\}
    , &.{});
}

test "schedule context" {
    try expectFindings(
        \\fn released(ctx: mach.Context) void {
        \\    const a = encoder.beginRenderPass(&desc);
        \\    ctx.schedule.put(.render_pass, a, .{ .end, .release });
        \\}
        \\fn notReleased(ctx: mach.Context) void {
        \\    const b = encoder.beginRenderPass(&desc);
        \\    ctx.schedule.put(.render_pass, b, .{.end});
        \\}
    , &.{"b"});
}

test "borrowing isn't handing over, unrelated calls are ignored, comments silence" {
    try expectFindings(
        \\fn f() void {
        \\    const layout = device.createPipelineLayout(&.{});
        \\    const pipeline = device.createRenderPipeline(&.{ .layout = layout });
        \\    defer pipeline.release();
        \\    const ignored = device.createBuffer(&.{}); // gpu-lint: ignore
        \\    const other = foo.createThing();
        \\    const nested = wrap(device.createBuffer(&.{}));
        \\}
    , &.{"layout"});
}
