//! Compile-time WGSL reflection and linting.
//!
//! Parses a WGSL shader at comptime (usually from `@embedFile`) and checks the Zig code using it
//! against it, so that mismatches between a shader and its bind group layouts, bind groups,
//! uniform structs, entry points and vertex buffers are compile errors pointing at the shader
//! line, with a suggested fix, instead of backend validation errors (or garbage on screen) at
//! runtime:
//!
//! ```
//! const shader = mach.wgsl.Shader("sprite.wgsl", @embedFile("sprite.wgsl"));
//!
//! // Generate the bind group layout from the shader, instead of writing it by hand...
//! const layout = device.createBindGroupLayout(&shader.layoutDescriptor(0, "sprite"));
//! // ...or check a hand-written one:
//! comptime shader.checkLayout(0, &my_entries);
//!
//! // Typed bind group: one field per shader variable of @group(0), named after it.
//! const group = device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
//!     .layout = layout,
//!     .entries = &shader.bindGroupEntries(0, .{
//!         .uniforms = .{ .buffer = uniforms },
//!         .sprite_transforms = .{ .buffer = transforms },
//!         .spriteSampler = sampler,
//!         .spriteTexture = view,
//!     }),
//! }));
//!
//! // Host structs must have the same layout as the shader's.
//! comptime shader.checkHostType("uniforms", Uniforms);
//!
//! // Entry point names, checked to exist with the right stage.
//! .entry_point = shader.vertexEntry("vertMain"),
//! ```
//!
//! The parser understands the declarations needed for reflection (structs, aliases, resource
//! variables, functions and their attributes), and skips over function bodies other than to see
//! which variables and functions they use. It is not a validator: shaders are still compiled by
//! the GPU backend at runtime.
const std = @import("std");
const gpu = @import("sysgpu/sysgpu/main.zig");

pub const Stage = enum { vertex, fragment, compute };

pub const Stages = struct {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,

    pub fn any(s: Stages) bool {
        return s.vertex or s.fragment or s.compute;
    }

    pub fn has(s: Stages, stage: Stage) bool {
        return switch (stage) {
            .vertex => s.vertex,
            .fragment => s.fragment,
            .compute => s.compute,
        };
    }

    pub fn with(s: Stages, stage: Stage) Stages {
        var r = s;
        switch (stage) {
            .vertex => r.vertex = true,
            .fragment => r.fragment = true,
            .compute => r.compute = true,
        }
        return r;
    }

    pub fn flags(s: Stages) gpu.ShaderStageFlags {
        return .{ .vertex = s.vertex, .fragment = s.fragment, .compute = s.compute };
    }

    pub fn fromFlags(f: gpu.ShaderStageFlags) Stages {
        return .{ .vertex = f.vertex, .fragment = f.fragment, .compute = f.compute };
    }

    /// Zig source for the equivalent `gpu.ShaderStageFlags`.
    pub fn zig(comptime s: Stages) []const u8 {
        comptime {
            var out: []const u8 = ".{";
            var first = true;
            for ([_]Stage{ .vertex, .fragment, .compute }) |stage| {
                if (!s.has(stage)) continue;
                out = out ++ (if (first) " ." else ", .") ++ @tagName(stage) ++ " = true";
                first = false;
            }
            return out ++ (if (first) "}" else " }");
        }
    }
};

/// What kind of resource a binding is, as the shader declares it.
pub const Resource = union(enum) {
    /// `var<uniform>`
    uniform_buffer,
    /// `var<storage, read>` (read_only) or `var<storage, read_write>`
    storage_buffer: struct { read_only: bool },
    /// `sampler` (comparison = false) or `sampler_comparison`
    sampler: struct { comparison: bool },
    /// `texture_*` sampled textures, including depth textures
    texture: struct {
        sample_type: gpu.Texture.SampleType,
        view_dimension: gpu.TextureView.Dimension,
        multisampled: bool,
    },
    /// `texture_storage_*<format, access>`
    storage_texture: struct {
        format: gpu.Texture.Format,
        access: gpu.StorageTextureAccess,
        view_dimension: gpu.TextureView.Dimension,
    },
    /// `texture_external`
    external_texture,

    pub fn describe(r: Resource) []const u8 {
        return switch (r) {
            .uniform_buffer => "a uniform buffer",
            .storage_buffer => |b| if (b.read_only) "a read-only storage buffer" else "a read-write storage buffer",
            .sampler => |s| if (s.comparison) "a comparison sampler" else "a sampler",
            .texture => "a sampled texture",
            .storage_texture => "a storage texture",
            .external_texture => "an external texture",
        };
    }
};

pub const Binding = struct {
    group: u32,
    binding: u32,
    /// The variable name.
    name: []const u8,
    /// The variable type, as written in the shader (whitespace removed).
    type_name: []const u8,
    resource: Resource,
    /// The stages whose entry points use the variable, directly or through called functions.
    visibility: Stages,
    /// For buffers: the size of the type, or for a runtime-sized array (or a struct ending with
    /// one) the size with one element. This is the minimum size a buffer bound to it must have.
    min_size: u64 = 0,
    /// For buffers: the size of one element, if the type is (or ends with) a runtime-sized array,
    /// else the size of the type. sysgpu's D3D12 backend needs it, see `gpu.BindGroup.Entry`.
    elem_size: u32 = 0,
    line: u32,
};

pub const Location = struct {
    location: u32,
    name: []const u8,
    type_name: []const u8,
};

pub const EntryPoint = struct {
    name: []const u8,
    stage: Stage,
    /// `@location` inputs, including those in struct-typed parameters.
    inputs: []const Location,
    /// `@location` outputs, including those in a struct return type.
    outputs: []const Location,
    /// The bindings it uses, as indices into `Shader.bindings`.
    uses: []const usize,
    line: u32,
};

pub const Member = struct {
    name: []const u8,
    type_name: []const u8,
    location: ?u32 = null,
    builtin: ?[]const u8 = null,
    align_attr: ?u32 = null,
    size_attr: ?u32 = null,
};

pub const Struct = struct {
    name: []const u8,
    members: []const Member,
    line: u32,
};

/// The memory layout of a WGSL type, in host-shareable address spaces.
pub const Layout = struct {
    size: u64,
    alignment: u64,
    /// Whether the type is or ends with a runtime-sized array; `size` then counts one element.
    runtime_sized: bool = false,
    /// For a runtime-sized type, the size of its elements.
    elem_size: u64 = 0,
};

pub const MemberLayout = struct {
    name: []const u8,
    type_name: []const u8,
    offset: u64,
    size: u64,
};

const Function = struct {
    name: []const u8,
    stage: ?Stage,
    params: []const Member,
    return_type: ?[]const u8,
    return_location: ?u32,
    /// Identifiers used in the body (deduplicated, member accesses excluded).
    idents: []const []const u8,
    line: u32,
};

const Alias = struct { name: []const u8, type_name: []const u8 };

/// Reflection data of a parsed shader.
pub const Reflection = struct {
    name: []const u8,
    bindings: []const Binding,
    entry_points: []const EntryPoint,
    structs: []const Struct,
    aliases: []const Alias,
};

/// Parses a WGSL shader at comptime. `name` is used in error messages, usually the file name.
/// Returns a namespace of comptime checks and helpers for the shader, see the file docs.
pub fn Shader(comptime name: []const u8, comptime source: []const u8) type {
    return struct {
        pub const reflection: Reflection = parse(name, source);
        pub const bindings = reflection.bindings;
        pub const entry_points = reflection.entry_points;
        pub const file_name: [:0]const u8 = name ++ "";

        /// Returns the binding of the variable `var_name`, or a compile error.
        pub fn binding(comptime var_name: []const u8) Binding {
            comptime {
                for (bindings) |b| if (std.mem.eql(u8, b.name, var_name)) return b;
                var names: []const u8 = "";
                for (bindings) |b| names = names ++ "\n  " ++ bindingSummary(name, b);
                @compileError(name ++ ": no resource variable named `" ++ var_name ++ "`, the shader declares:" ++ names);
            }
        }

        /// The bindings of `@group(group)`, sorted by binding number.
        pub fn groupBindings(comptime group: u32) []const Binding {
            comptime {
                var out: []const Binding = &.{};
                for (bindings) |b| {
                    if (b.group == group) out = out ++ [_]Binding{b};
                }
                if (out.len == 0) {
                    var groups: []const u8 = "";
                    for (bindings) |b| groups = groups ++ std.fmt.comptimePrint(" {d}", .{b.group});
                    @compileError(std.fmt.comptimePrint("{s}: the shader has no @group({d}) bindings, it uses groups:{s}", .{ name, group, if (groups.len == 0) " none" else groups }));
                }
                var sorted = out[0..out.len].*;
                std.mem.sortUnstable(Binding, &sorted, {}, struct {
                    fn lessThan(_: void, a: Binding, b: Binding) bool {
                        return a.binding < b.binding;
                    }
                }.lessThan);
                const final = sorted;
                return &final;
            }
        }

        /// The number of bind groups the shader uses (highest `@group` + 1).
        pub const num_groups: u32 = blk: {
            var n: u32 = 0;
            for (bindings) |b| n = @max(n, b.group + 1);
            break :blk n;
        };

        /// Bind group layout entries for `@group(group)`, derived from the shader: each binding
        /// is visible to the stages that use it.
        pub fn layoutEntries(comptime group: u32) [groupBindings(group).len]gpu.BindGroupLayout.Entry {
            comptime {
                const bs = groupBindings(group);
                var out: [bs.len]gpu.BindGroupLayout.Entry = undefined;
                for (bs, 0..) |b, i| out[i] = layoutEntry(b);
                return out;
            }
        }

        /// A bind group layout descriptor for `@group(group)`, see `layoutEntries`.
        pub fn layoutDescriptor(comptime group: u32, label: ?[*:0]const u8) gpu.BindGroupLayout.Descriptor {
            const S = struct {
                const entries = layoutEntries(group);
            };
            return gpu.BindGroupLayout.Descriptor.init(.{ .label = label, .entries = &S.entries });
        }

        /// Checks that `entries` describe a bind group layout compatible with `@group(group)` of
        /// the shader, or else fails compilation with an explanation and a suggested fix.
        pub fn checkLayout(comptime group: u32, comptime entries: []const gpu.BindGroupLayout.Entry) void {
            comptime {
                if (diagnoseLayout(name, groupBindings(group), entries)) |msg| @compileError(msg);
            }
        }

        /// Checks that the host type `T` has the same memory layout as the shader's type for the
        /// resource variable `var_name` (the element type, if it is a runtime-sized array), or
        /// the struct named `var_name` if there is no such variable.
        pub fn checkHostType(comptime var_name: []const u8, comptime T: type) void {
            comptime {
                if (diagnoseHostType(reflection, var_name, T)) |msg| @compileError(msg);
            }
        }

        /// The memory layout of a WGSL type of this shader (e.g. a struct name).
        pub fn layoutOf(comptime type_name: []const u8) Layout {
            return comptime typeLayout(reflection, type_name);
        }

        /// Returns `entry` if the shader has a `@vertex` entry point with that name, else a
        /// compile error listing those it has.
        pub fn vertexEntry(comptime entry: []const u8) [:0]const u8 {
            return comptime entryPoint(.vertex, entry).name ++ "";
        }

        /// See `vertexEntry`.
        pub fn fragmentEntry(comptime entry: []const u8) [:0]const u8 {
            return comptime entryPoint(.fragment, entry).name ++ "";
        }

        /// See `vertexEntry`.
        pub fn computeEntry(comptime entry: []const u8) [:0]const u8 {
            return comptime entryPoint(.compute, entry).name ++ "";
        }

        pub fn entryPoint(comptime stage: Stage, comptime entry: []const u8) EntryPoint {
            comptime {
                if (findEntry(reflection, entry)) |e| {
                    if (e.stage != stage) {
                        @compileError(std.fmt.comptimePrint("{s}:{d}: entry point `{s}` is a @{s} entry point, not @{s}", .{ name, e.line, entry, @tagName(e.stage), @tagName(stage) }));
                    }
                    return e;
                }
                var names: []const u8 = "";
                for (entry_points) |e| names = names ++ std.fmt.comptimePrint("\n  @{s} fn {s} (line {d})", .{ @tagName(e.stage), e.name, e.line });
                @compileError(name ++ ": no entry point named `" ++ entry ++ "`, the shader has:" ++ if (names.len == 0) " none" else names);
            }
        }

        /// Checks that the vertex buffer layouts provide every `@location` input of the vertex
        /// entry point `entry`, with formats of matching component counts and types.
        pub fn checkVertexBuffers(comptime entry: []const u8, comptime buffers: []const gpu.VertexBufferLayout) void {
            comptime {
                if (diagnoseVertexBuffers(name, reflection, entryPoint(.vertex, entry), buffers)) |msg| @compileError(msg);
            }
        }

        /// Checks that a fragment state with `count` color targets covers every `@location`
        /// output of the fragment entry point `entry`.
        pub fn checkColorTargets(comptime entry: []const u8, comptime count: usize) void {
            comptime {
                const e = entryPoint(.fragment, entry);
                for (e.outputs) |o| {
                    if (o.location >= count) @compileError(std.fmt.comptimePrint(
                        "{s}:{d}: fragment entry point `{s}` writes @location({d}) but the fragment state has only {d} color target(s)\n  fix: add a gpu.ColorTargetState for each output location",
                        .{ name, e.line, entry, o.location, count },
                    ));
                }
            }
        }

        /// A struct with one field per resource variable of `@group(group)`, named after it:
        /// `BufferBinding` for buffers, `*gpu.Sampler` for samplers and `*gpu.TextureView` for
        /// textures. See `bindGroupEntries`.
        pub fn BindGroup(comptime group: u32) type {
            const bs = groupBindings(group);
            var names: [bs.len][]const u8 = undefined;
            var types: [bs.len]type = undefined;
            var attrs: [bs.len]std.builtin.Type.Struct.FieldAttributes = undefined;
            for (bs, 0..) |b, i| {
                names[i] = b.name;
                types[i] = switch (b.resource) {
                    .uniform_buffer, .storage_buffer => BufferBinding,
                    .sampler => *gpu.Sampler,
                    .texture, .storage_texture => *gpu.TextureView,
                    .external_texture => @compileError(name ++ ": texture_external bindings are not supported by mach.wgsl"),
                };
                attrs[i] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = null };
            }
            return @Struct(.auto, null, &names, &types, &attrs);
        }

        /// Bind group entries for `@group(group)`, from one value per resource variable.
        /// Buffer sizes default to the whole buffer (from `offset`), and the element size is
        /// derived from the shader.
        pub fn bindGroupEntries(comptime group: u32, values: BindGroup(group)) [groupBindings(group).len]gpu.BindGroup.Entry {
            const bs = comptime groupBindings(group);
            var out: [bs.len]gpu.BindGroup.Entry = undefined;
            inline for (bs, 0..) |b, i| {
                const v = @field(values, b.name);
                out[i] = switch (b.resource) {
                    .uniform_buffer, .storage_buffer => .{
                        .binding = b.binding,
                        .buffer = v.buffer,
                        .offset = v.offset,
                        .size = v.size orelse (v.buffer.getSize() - v.offset),
                        .elem_size = b.elem_size,
                    },
                    .sampler => gpu.BindGroup.Entry.initSampler(b.binding, v),
                    .texture, .storage_texture => gpu.BindGroup.Entry.initTextureView(b.binding, v),
                    .external_texture => unreachable,
                };
            }
            return out;
        }
    };
}

/// A buffer bound to a buffer variable, see `Shader.BindGroup`.
pub const BufferBinding = struct {
    buffer: *gpu.Buffer,
    offset: u64 = 0,
    /// Defaults to the rest of the buffer after `offset`.
    size: ?u64 = null,
};

fn findEntry(r: Reflection, entry: []const u8) ?EntryPoint {
    for (r.entry_points) |e| if (std.mem.eql(u8, e.name, entry)) return e;
    return null;
}

/// A one-line description of a binding, e.g. "@group(0) @binding(1) `transforms`: array<mat4x4<f32>> (vertex)".
pub fn bindingSummary(comptime file: []const u8, comptime b: Binding) []const u8 {
    return std.fmt.comptimePrint("{s}:{d}: @group({d}) @binding({d}) `{s}`: {s}, used by {s}", .{
        file, b.line, b.group, b.binding, b.name, b.type_name, stagesText(b.visibility),
    });
}

fn stagesText(comptime s: Stages) []const u8 {
    comptime {
        var out: []const u8 = "";
        for ([_]Stage{ .vertex, .fragment, .compute }) |stage| {
            if (!s.has(stage)) continue;
            out = out ++ (if (out.len == 0) "" else "+") ++ @tagName(stage);
        }
        return if (out.len == 0) "no entry point" else out;
    }
}

/// The layout entry the shader expects for a binding.
pub fn layoutEntry(comptime b: Binding) gpu.BindGroupLayout.Entry {
    // Unused bindings are visible to every stage of a render pipeline, so that the layout stays
    // valid if a later version of the shader uses them.
    const vis = if (b.visibility.any()) b.visibility.flags() else gpu.ShaderStageFlags{ .vertex = true, .fragment = true };
    return switch (b.resource) {
        .uniform_buffer => gpu.BindGroupLayout.Entry.initBuffer(b.binding, vis, .uniform, false, 0),
        .storage_buffer => |s| gpu.BindGroupLayout.Entry.initBuffer(b.binding, vis, if (s.read_only) .read_only_storage else .storage, false, 0),
        .sampler => |s| gpu.BindGroupLayout.Entry.initSampler(b.binding, vis, if (s.comparison) .comparison else .filtering),
        .texture => |t| gpu.BindGroupLayout.Entry.initTexture(b.binding, vis, t.sample_type, t.view_dimension, t.multisampled),
        .storage_texture => |t| gpu.BindGroupLayout.Entry.initStorageTexture(b.binding, vis, t.access, t.format, t.view_dimension),
        .external_texture => @compileError("mach.wgsl: texture_external bindings are not supported"),
    };
}

/// Zig source creating the layout entry the shader expects for a binding.
pub fn layoutEntrySource(comptime b: Binding) []const u8 {
    const vis = (if (b.visibility.any()) b.visibility else Stages{ .vertex = true, .fragment = true }).zig();
    return switch (b.resource) {
        .uniform_buffer => std.fmt.comptimePrint("gpu.BindGroupLayout.Entry.initBuffer({d}, {s}, .uniform, false, 0)", .{ b.binding, vis }),
        .storage_buffer => |s| std.fmt.comptimePrint("gpu.BindGroupLayout.Entry.initBuffer({d}, {s}, .{s}, false, 0)", .{ b.binding, vis, if (s.read_only) "read_only_storage" else "storage" }),
        .sampler => |s| std.fmt.comptimePrint("gpu.BindGroupLayout.Entry.initSampler({d}, {s}, .{s})", .{ b.binding, vis, if (s.comparison) "comparison" else "filtering" }),
        .texture => |t| std.fmt.comptimePrint("gpu.BindGroupLayout.Entry.initTexture({d}, {s}, .{s}, .{s}, {})", .{ b.binding, vis, @tagName(t.sample_type), @tagName(t.view_dimension), t.multisampled }),
        .storage_texture => |t| std.fmt.comptimePrint("gpu.BindGroupLayout.Entry.initStorageTexture({d}, {s}, .{s}, .{s}, .{s})", .{ b.binding, vis, @tagName(t.access), @tagName(t.format), @tagName(t.view_dimension) }),
        .external_texture => "(texture_external is not supported)",
    };
}

/// What kind of resource a layout entry describes.
pub fn entryKind(e: gpu.BindGroupLayout.Entry) enum { buffer, sampler, texture, storage_texture, none } {
    if (e.buffer.type != .undefined) return .buffer;
    if (e.sampler.type != .undefined) return .sampler;
    if (e.texture.sample_type != .undefined) return .texture;
    if (e.storage_texture.access != .undefined) return .storage_texture;
    return .none;
}

/// A description of a layout entry, e.g. "a uniform buffer".
pub fn describeEntry(e: gpu.BindGroupLayout.Entry) []const u8 {
    return switch (entryKind(e)) {
        .buffer => switch (e.buffer.type) {
            .uniform => "a uniform buffer",
            .storage => "a read-write storage buffer",
            .read_only_storage => "a read-only storage buffer",
            .undefined => unreachable,
        },
        .sampler => if (e.sampler.type == .comparison) "a comparison sampler" else "a sampler",
        .texture => "a sampled texture",
        .storage_texture => "a storage texture",
        .none => "an entry with no resource type set",
    };
}

/// Returns an error message if `entries` aren't compatible with the shader's `bindings` (all of
/// the same group), or null. Usable at comptime and at runtime.
pub fn diagnoseLayout(comptime file: []const u8, comptime bs: []const Binding, comptime entries: []const gpu.BindGroupLayout.Entry) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        for (entries, 0..) |e, i| {
            for (entries[0..i]) |prev| {
                if (prev.binding == e.binding) return std.fmt.comptimePrint("bind group layout has two entries for binding {d}", .{e.binding});
            }
        }
        for (bs) |b| {
            const where = bindingSummary(file, b);
            const fix = "\n  fix: use " ++ layoutEntrySource(b) ++ "\n  (or generate the layout from the shader: shader.layoutEntries(" ++ std.fmt.comptimePrint("{d}", .{b.group}) ++ "))";
            const e = for (entries) |e| {
                if (e.binding == b.binding) break e;
            } else return where ++ "\n  error: the bind group layout has no entry for this binding" ++ fix;

            const mismatch = std.fmt.comptimePrint("\n  error: the shader declares {s}, but layout entry {d} is {s}", .{ b.resource.describe(), b.binding, describeEntry(e) });
            switch (b.resource) {
                .uniform_buffer => if (entryKind(e) != .buffer or e.buffer.type != .uniform) return where ++ mismatch ++ fix,
                .storage_buffer => |s| {
                    if (entryKind(e) != .buffer or e.buffer.type == .uniform) return where ++ mismatch ++ fix;
                    if (!s.read_only and e.buffer.type == .read_only_storage) return where ++ "\n  error: the shader declares var<storage, read_write> but the layout entry is .read_only_storage" ++ fix;
                    if (s.read_only and e.buffer.type == .storage) return where ++ "\n  error: the shader declares var<storage, read> but the layout entry is .storage (read-write)" ++ fix;
                },
                .sampler => |s| {
                    if (entryKind(e) != .sampler) return where ++ mismatch ++ fix;
                    if (s.comparison != (e.sampler.type == .comparison)) return where ++ mismatch ++ fix;
                },
                .texture => |t| {
                    if (entryKind(e) != .texture) return where ++ mismatch ++ fix;
                    const sample_ok = e.texture.sample_type == t.sample_type or
                        (t.sample_type == .float and e.texture.sample_type == .unfilterable_float) or
                        (t.sample_type == .depth and e.texture.sample_type == .unfilterable_float);
                    if (!sample_ok) return where ++ std.fmt.comptimePrint("\n  error: the shader samples it as .{s}, but the layout entry has sample type .{s}", .{ @tagName(t.sample_type), @tagName(e.texture.sample_type) }) ++ fix;
                    const dim = if (e.texture.view_dimension == .dimension_undefined) .dimension_2d else e.texture.view_dimension;
                    if (dim != t.view_dimension) return where ++ std.fmt.comptimePrint("\n  error: the shader declares a .{s} texture, but the layout entry has view dimension .{s}", .{ @tagName(t.view_dimension), @tagName(dim) }) ++ fix;
                    if (t.multisampled != (e.texture.multisampled == .true)) return where ++ "\n  error: multisampled doesn't match the shader" ++ fix;
                },
                .storage_texture => |t| {
                    if (entryKind(e) != .storage_texture) return where ++ mismatch ++ fix;
                    if (e.storage_texture.format != t.format) return where ++ std.fmt.comptimePrint("\n  error: the shader declares format .{s}, but the layout entry has .{s}", .{ @tagName(t.format), @tagName(e.storage_texture.format) }) ++ fix;
                    const dim = if (e.storage_texture.view_dimension == .dimension_undefined) .dimension_2d else e.storage_texture.view_dimension;
                    if (dim != t.view_dimension) return where ++ std.fmt.comptimePrint("\n  error: the shader declares a .{s} storage texture, but the layout entry has view dimension .{s}", .{ @tagName(t.view_dimension), @tagName(dim) }) ++ fix;
                },
                .external_texture => {},
            }
            const have = Stages.fromFlags(e.visibility);
            for ([_]Stage{ .vertex, .fragment, .compute }) |stage| {
                if (b.visibility.has(stage) and !have.has(stage)) {
                    return where ++ std.fmt.comptimePrint("\n  error: the {s} stage uses it, but layout entry {d} is only visible to {s}\n  fix: .visibility = {s}", .{ @tagName(stage), b.binding, have.zig(), have.with(stage).zig() });
                }
            }
            if (entryKind(e) == .buffer and e.buffer.min_binding_size != 0 and e.buffer.min_binding_size < b.min_size) {
                return where ++ std.fmt.comptimePrint("\n  error: layout entry min_binding_size is {d}, but the shader needs at least {d} bytes\n  fix: .min_binding_size = {d} (or 0)", .{ e.buffer.min_binding_size, b.min_size, b.min_size });
            }
        }
        return null;
    }
}

/// Returns an error message if the host type `T` doesn't match the layout of the shader type
/// named by `var_name` (see `Shader.checkHostType`), or null.
pub fn diagnoseHostType(comptime r: Reflection, comptime var_name: []const u8, comptime T: type) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var type_name: []const u8 = var_name;
        var line: u32 = 0;
        var what: []const u8 = "struct";
        for (r.bindings) |b| {
            if (!std.mem.eql(u8, b.name, var_name)) continue;
            type_name = b.type_name;
            line = b.line;
            what = "variable";
            if (runtimeArrayElement(b.type_name)) |elem| {
                type_name = elem;
                what = "array element of variable";
            }
        }
        if (line == 0) {
            const s = findStruct(r, resolveAlias(r, var_name)) orelse
                return r.name ++ ": no resource variable or struct named `" ++ var_name ++ "`";
            line = s.line;
        }
        const where = std.fmt.comptimePrint("{s}:{d}: {s} `{s}` ({s}) vs host type {s}", .{ r.name, line, what, var_name, type_name, @typeName(T) });
        const layout = typeLayout(r, type_name);
        const resolved = resolveAlias(r, type_name);
        const s = findStruct(r, resolved);

        if (s == null) {
            // Not a struct: only the size can be compared (a stride, for array elements).
            if (@sizeOf(T) != std.mem.alignForward(u64, layout.size, layout.alignment)) {
                return where ++ std.fmt.comptimePrint("\n  error: size mismatch, the shader's {s} is {d} bytes (stride {d}), {s} is {d} bytes", .{ type_name, layout.size, std.mem.alignForward(u64, layout.size, layout.alignment), @typeName(T), @sizeOf(T) });
            }
            return null;
        }

        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".layout != .@"extern") {
            return where ++ "\n  error: host type must be an `extern struct` to have a defined layout";
        }
        const members = structMemberLayouts(r, s.?);
        const fields = info.@"struct".field_names;
        const table = layoutTable(members, T);
        if (fields.len != members.len) {
            return where ++ std.fmt.comptimePrint("\n  error: the shader struct has {d} members, {s} has {d} fields", .{ members.len, @typeName(T), fields.len }) ++ table;
        }
        for (members, fields, 0..) |m, f, i| {
            const offset = @offsetOf(T, f);
            const size = @sizeOf(@FieldType(T, f));
            if (offset != m.offset) {
                const fix = if (offset < m.offset)
                    std.fmt.comptimePrint("\n  fix: align the field: `{s}: {s} align({d})`", .{ f, @typeName(@FieldType(T, f)), memberAlign(r, m.type_name) })
                else
                    "\n  fix: remove padding before the field, or add @align to the WGSL member";
                return where ++ std.fmt.comptimePrint("\n  error: member {d} `{s}` is at offset {d} in the shader, but field `{s}` is at offset {d}", .{ i, m.name, m.offset, f, offset }) ++ fix ++ table;
            }
            if (size != m.size and !(i == members.len - 1 and layout.runtime_sized)) {
                return where ++ std.fmt.comptimePrint("\n  error: member `{s}` is {d} bytes in the shader, but field `{s}` is {d} bytes", .{ m.name, m.size, f, size }) ++ table;
            }
        }
        const wgsl_size = std.mem.alignForward(u64, layout.size, layout.alignment);
        if (!layout.runtime_sized and @sizeOf(T) != wgsl_size) {
            return where ++ std.fmt.comptimePrint("\n  error: the shader struct is {d} bytes (with trailing padding to its {d}-byte alignment), {s} is {d} bytes\n  fix: add `align({d})` to the first field of {s}, or pad it", .{ wgsl_size, layout.alignment, @typeName(T), @sizeOf(T), layout.alignment, @typeName(T) }) ++ table;
        }
        return null;
    }
}

fn layoutTable(comptime members: []const MemberLayout, comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "\n  shader layout:";
        for (members) |m| out = out ++ std.fmt.comptimePrint("\n    {d: >4} {d: >4}  {s}: {s}", .{ m.offset, m.size, m.name, m.type_name });
        out = out ++ "\n  host layout (" ++ @typeName(T) ++ "):";
        if (@typeInfo(T) == .@"struct") {
            for (@typeInfo(T).@"struct".field_names) |f| {
                out = out ++ std.fmt.comptimePrint("\n    {d: >4} {d: >4}  {s}: {s}", .{ @offsetOf(T, f), @sizeOf(@FieldType(T, f)), f, @typeName(@FieldType(T, f)) });
            }
        }
        return out;
    }
}

fn diagnoseVertexBuffers(comptime file: []const u8, comptime r: Reflection, comptime e: EntryPoint, comptime buffers: []const gpu.VertexBufferLayout) ?[]const u8 {
    comptime {
        for (e.inputs) |in| {
            const attr: gpu.VertexAttribute = blk: for (buffers) |buf| {
                const attrs = if (buf.attributes) |a| a[0..buf.attribute_count] else &[_]gpu.VertexAttribute{};
                for (attrs) |a| if (a.shader_location == in.location) break :blk a;
            } else return std.fmt.comptimePrint("{s}:{d}: vertex entry point `{s}` reads @location({d}) `{s}`: {s}, but no vertex buffer attribute has shader_location {d}", .{ file, e.line, e.name, in.location, in.name, in.type_name, in.location });
            const want = vectorShape(r, in.type_name) orelse continue;
            const have = vertexFormatShape(attr.format) orelse continue;
            if (want.scalar != have.scalar) {
                return std.fmt.comptimePrint("{s}:{d}: vertex input @location({d}) `{s}` is {s}, but its attribute format .{s} provides {s} components", .{ file, e.line, in.location, in.name, in.type_name, @tagName(attr.format), @tagName(have.scalar) });
            }
        }
        return null;
    }
}

const ScalarKind = enum { float, sint, uint };
const Shape = struct { scalar: ScalarKind, count: u32 };

fn vectorShape(comptime r: Reflection, comptime type_name: []const u8) ?Shape {
    const t = expandShorthand(resolveAlias(r, type_name));
    var p = TypeParser{ .text = t };
    const base = p.ident();
    const elem = if (p.peekChar('<')) blk: {
        p.pos += 1;
        break :blk p.ident();
    } else base;
    const scalar: ScalarKind = if (eql(elem, "f32") or eql(elem, "f16")) .float else if (eql(elem, "i32")) .sint else if (eql(elem, "u32")) .uint else return null;
    const count: u32 = if (eql(base, "vec2")) 2 else if (eql(base, "vec3")) 3 else if (eql(base, "vec4")) 4 else 1;
    return .{ .scalar = scalar, .count = count };
}

fn vertexFormatShape(comptime f: gpu.VertexFormat) ?Shape {
    const n = @tagName(f);
    const scalar: ScalarKind = if (std.mem.startsWith(u8, n, "uint")) .uint else if (std.mem.startsWith(u8, n, "sint")) .sint else .float;
    const count: u32 = if (std.mem.endsWith(u8, n, "x2")) 2 else if (std.mem.endsWith(u8, n, "x3")) 3 else if (std.mem.endsWith(u8, n, "x4")) 4 else 1;
    return .{ .scalar = scalar, .count = count };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------------------------
// Type layouts

fn findStruct(comptime r: Reflection, comptime name: []const u8) ?Struct {
    for (r.structs) |s| if (eql(s.name, name)) return s;
    return null;
}

fn resolveAlias(comptime r: Reflection, comptime name: []const u8) []const u8 {
    var n = name;
    var depth: usize = 0;
    outer: while (depth < 16) : (depth += 1) {
        for (r.aliases) |a| if (eql(a.name, n)) {
            n = a.type_name;
            continue :outer;
        };
        break;
    }
    return n;
}

/// Expands predeclared aliases like `vec4f` and `mat4x4f`.
fn expandShorthand(comptime t: []const u8) []const u8 {
    const suffixes = .{ .{ 'f', "f32" }, .{ 'h', "f16" }, .{ 'i', "i32" }, .{ 'u', "u32" } };
    if ((std.mem.startsWith(u8, t, "vec") and t.len == 5) or (std.mem.startsWith(u8, t, "mat") and t.len == 7)) {
        inline for (suffixes) |s| {
            if (t[t.len - 1] == s[0]) return t[0 .. t.len - 1] ++ "<" ++ s[1] ++ ">";
        }
    }
    return t;
}

/// If the type is `array<E>` (runtime-sized), returns `E`.
fn runtimeArrayElement(comptime t: []const u8) ?[]const u8 {
    var p = TypeParser{ .text = t };
    if (!eql(p.ident(), "array") or !p.peekChar('<')) return null;
    p.pos += 1;
    const elem = p.typeText();
    if (p.peekChar(',')) return null;
    return elem;
}

const TypeParser = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipWs(p: *TypeParser) void {
        while (p.pos < p.text.len and std.ascii.isWhitespace(p.text[p.pos])) p.pos += 1;
    }

    fn peekChar(p: *TypeParser, c: u8) bool {
        p.skipWs();
        return p.pos < p.text.len and p.text[p.pos] == c;
    }

    fn ident(p: *TypeParser) []const u8 {
        p.skipWs();
        const start = p.pos;
        while (p.pos < p.text.len and (std.ascii.isAlphanumeric(p.text[p.pos]) or p.text[p.pos] == '_')) p.pos += 1;
        return p.text[start..p.pos];
    }

    /// A whole type (with template arguments) starting at the current position.
    fn typeText(p: *TypeParser) []const u8 {
        p.skipWs();
        const start = p.pos;
        _ = p.ident();
        if (p.peekChar('<')) {
            var depth: usize = 0;
            while (p.pos < p.text.len) : (p.pos += 1) {
                switch (p.text[p.pos]) {
                    '<' => depth += 1,
                    '>' => {
                        depth -= 1;
                        if (depth == 0) {
                            p.pos += 1;
                            break;
                        }
                    },
                    else => {},
                }
            }
        }
        return p.text[start..p.pos];
    }

    fn number(p: *TypeParser) ?u64 {
        p.skipWs();
        const start = p.pos;
        while (p.pos < p.text.len and (std.ascii.isAlphanumeric(p.text[p.pos]))) p.pos += 1;
        var digits = p.text[start..p.pos];
        while (digits.len > 0 and (digits[digits.len - 1] == 'u' or digits[digits.len - 1] == 'i')) digits = digits[0 .. digits.len - 1];
        return std.fmt.parseInt(u64, digits, 0) catch null;
    }
};

fn memberAlign(comptime r: Reflection, comptime type_name: []const u8) u64 {
    return typeLayout(r, type_name).alignment;
}

/// The host-shareable memory layout of a WGSL type.
pub fn typeLayout(comptime r: Reflection, comptime type_name: []const u8) Layout {
    comptime {
        @setEvalBranchQuota(100_000);
        const t = expandShorthand(resolveAlias(r, type_name));
        if (findStruct(r, t)) |s| {
            const members = structMemberLayouts(r, s);
            var alignment: u64 = 1;
            for (s.members) |m| alignment = @max(alignment, m.align_attr orelse memberAlign(r, m.type_name));
            const last = members[members.len - 1];
            const last_layout = typeLayout(r, last.type_name);
            const end = last.offset + last.size;
            return .{
                .size = if (last_layout.runtime_sized) end else std.mem.alignForward(u64, end, alignment),
                .alignment = alignment,
                .runtime_sized = last_layout.runtime_sized,
                .elem_size = last_layout.elem_size,
            };
        }
        var p = TypeParser{ .text = t };
        const base = p.ident();
        if (eql(base, "f32") or eql(base, "i32") or eql(base, "u32") or eql(base, "bool")) return .{ .size = 4, .alignment = 4 };
        if (eql(base, "f16")) return .{ .size = 2, .alignment = 2 };
        if (eql(base, "atomic")) {
            _ = p.peekChar('<');
            p.pos += 1;
            return typeLayout(r, p.typeText());
        }
        if (eql(base, "vec2") or eql(base, "vec3") or eql(base, "vec4")) {
            _ = p.peekChar('<');
            p.pos += 1;
            const scalar = typeLayout(r, p.typeText()).size;
            const n: u64 = base[3] - '0';
            return .{ .size = n * scalar, .alignment = (if (n == 3) 4 else n) * scalar };
        }
        if (std.mem.startsWith(u8, base, "mat") and base.len == 6) {
            const cols: u64 = base[3] - '0';
            const rows: u64 = base[5] - '0';
            _ = p.peekChar('<');
            p.pos += 1;
            const scalar_name = p.typeText();
            const col = typeLayout(r, std.fmt.comptimePrint("vec{d}<{s}>", .{ rows, scalar_name }));
            return .{ .size = cols * std.mem.alignForward(u64, col.size, col.alignment), .alignment = col.alignment };
        }
        if (eql(base, "array")) {
            _ = p.peekChar('<');
            p.pos += 1;
            const elem = typeLayout(r, p.typeText());
            const stride = std.mem.alignForward(u64, elem.size, elem.alignment);
            if (p.peekChar(',')) {
                p.pos += 1;
                const n = p.number() orelse @compileError(r.name ++ ": can't evaluate array size in `" ++ type_name ++ "`, use a literal");
                return .{ .size = n * stride, .alignment = elem.alignment };
            }
            return .{ .size = stride, .alignment = elem.alignment, .runtime_sized = true, .elem_size = stride };
        }
        @compileError(r.name ++ ": unknown or non-host-shareable type `" ++ type_name ++ "`");
    }
}

pub fn structMemberLayouts(comptime r: Reflection, comptime s: Struct) []const MemberLayout {
    comptime {
        var out: []const MemberLayout = &.{};
        var offset: u64 = 0;
        for (s.members) |m| {
            const l = typeLayout(r, m.type_name);
            const alignment = m.align_attr orelse l.alignment;
            offset = std.mem.alignForward(u64, offset, alignment);
            const size = m.size_attr orelse l.size;
            out = out ++ [_]MemberLayout{.{ .name = m.name, .type_name = m.type_name, .offset = offset, .size = size }};
            offset += size;
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

// ---------------------------------------------------------------------------------------------
// Parser

const Tok = struct {
    kind: Kind,
    text: []const u8,
    line: u32,
    start: usize,

    const Kind = enum { ident, number, punct, eof };

    fn is(t: Tok, s: []const u8) bool {
        return t.kind != .eof and std.mem.eql(u8, t.text, s);
    }
};

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,

    fn skipWs(l: *Lexer) void {
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '\n') {
                l.line += 1;
                l.pos += 1;
            } else if (std.ascii.isWhitespace(c)) {
                l.pos += 1;
            } else if (c == '/' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == '/') {
                while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
            } else if (c == '/' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == '*') {
                var depth: usize = 0;
                while (l.pos + 1 < l.src.len) {
                    if (l.src[l.pos] == '/' and l.src[l.pos + 1] == '*') {
                        depth += 1;
                        l.pos += 2;
                    } else if (l.src[l.pos] == '*' and l.src[l.pos + 1] == '/') {
                        depth -= 1;
                        l.pos += 2;
                        if (depth == 0) break;
                    } else {
                        if (l.src[l.pos] == '\n') l.line += 1;
                        l.pos += 1;
                    }
                }
            } else break;
        }
    }

    fn next(l: *Lexer) Tok {
        l.skipWs();
        const start = l.pos;
        if (l.pos >= l.src.len) return .{ .kind = .eof, .text = "", .line = l.line, .start = start };
        const c = l.src[l.pos];
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (l.pos < l.src.len and (std.ascii.isAlphanumeric(l.src[l.pos]) or l.src[l.pos] == '_')) l.pos += 1;
            return .{ .kind = .ident, .text = l.src[start..l.pos], .line = l.line, .start = start };
        }
        if (std.ascii.isDigit(c)) {
            while (l.pos < l.src.len and (std.ascii.isAlphanumeric(l.src[l.pos]) or l.src[l.pos] == '.')) l.pos += 1;
            return .{ .kind = .number, .text = l.src[start..l.pos], .line = l.line, .start = start };
        }
        if (c == '-' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == '>') {
            l.pos += 2;
        } else {
            l.pos += 1;
        }
        return .{ .kind = .punct, .text = l.src[start..l.pos], .line = l.line, .start = start };
    }

    fn peek(l: *Lexer) Tok {
        var copy = l.*;
        return copy.next();
    }
};

const Attr = struct { name: []const u8, args: []const u8 };

const Parser = struct {
    l: Lexer,
    file: []const u8,

    fn fail(p: *Parser, t: Tok, msg: []const u8) noreturn {
        @compileError(std.fmt.comptimePrint("{s}:{d}: mach.wgsl parse error: {s}, found `{s}`", .{ p.file, t.line, msg, t.text }));
    }

    fn expect(p: *Parser, s: []const u8) Tok {
        const t = p.l.next();
        if (!t.is(s)) p.fail(t, "expected `" ++ s ++ "`");
        return t;
    }

    fn ident(p: *Parser) Tok {
        const t = p.l.next();
        if (t.kind != .ident) p.fail(t, "expected an identifier");
        return t;
    }

    fn attrs(p: *Parser) []const Attr {
        var out: []const Attr = &.{};
        while (p.l.peek().is("@")) {
            _ = p.l.next();
            const name = p.ident().text;
            var args: []const u8 = "";
            if (p.l.peek().is("(")) {
                const open = p.l.next();
                var depth: usize = 1;
                var last = open;
                while (depth > 0) {
                    last = p.l.next();
                    if (last.kind == .eof) p.fail(last, "unterminated attribute");
                    if (last.is("(")) depth += 1;
                    if (last.is(")")) depth -= 1;
                }
                args = std.mem.trim(u8, p.l.src[open.start + 1 .. last.start], " \t\r\n");
            }
            out = out ++ [_]Attr{.{ .name = name, .args = args }};
        }
        return out;
    }

    /// A type, returned with whitespace removed.
    fn typeText(p: *Parser) []const u8 {
        const first = p.ident();
        var end = first.start + first.text.len;
        if (p.l.peek().is("<")) {
            var depth: usize = 0;
            while (true) {
                const t = p.l.next();
                if (t.kind == .eof) p.fail(t, "unterminated template list");
                if (t.is("<")) depth += 1;
                if (t.is(">")) {
                    depth -= 1;
                    if (depth == 0) {
                        end = t.start + 1;
                        break;
                    }
                }
            }
        }
        return stripWs(p.l.src[first.start..end]);
    }

    fn skipStatement(p: *Parser) void {
        var depth: usize = 0;
        while (true) {
            const t = p.l.next();
            if (t.kind == .eof) return;
            if (t.is("(") or t.is("{") or t.is("[")) depth += 1;
            if (t.is(")") or t.is("}") or t.is("]")) depth -|= 1;
            if (depth == 0 and t.is(";")) return;
        }
    }
};

fn stripWs(comptime s: []const u8) []const u8 {
    comptime {
        var has_ws = false;
        for (s) |c| if (std.ascii.isWhitespace(c)) {
            has_ws = true;
        };
        if (!has_ws) return s;
        var out: []const u8 = "";
        for (s) |c| if (!std.ascii.isWhitespace(c)) {
            out = out ++ [_]u8{c};
        };
        return out;
    }
}

fn findAttr(comptime as: []const Attr, comptime name: []const u8) ?Attr {
    for (as) |a| if (eql(a.name, name)) return a;
    return null;
}

fn attrInt(comptime p: *Parser, comptime t: Tok, comptime as: []const Attr, comptime name: []const u8) ?u32 {
    const a = findAttr(as, name) orelse return null;
    var digits = a.args;
    while (digits.len > 0 and (digits[digits.len - 1] == 'u' or digits[digits.len - 1] == 'i')) digits = digits[0 .. digits.len - 1];
    return std.fmt.parseInt(u32, digits, 0) catch p.fail(t, "@" ++ name ++ " needs an integer literal, got `" ++ a.args ++ "`");
}

fn parseMembers(comptime p: *Parser, comptime close: []const u8, comptime sep: []const u8) []const Member {
    var out: []const Member = &.{};
    while (true) {
        if (p.l.peek().is(close)) {
            _ = p.l.next();
            break;
        }
        const as = p.attrs();
        const name = p.ident();
        _ = p.expect(":");
        const ty = p.typeText();
        out = out ++ [_]Member{.{
            .name = name.text,
            .type_name = ty,
            .location = attrInt(p, name, as, "location"),
            .builtin = if (findAttr(as, "builtin")) |a| a.args else null,
            .align_attr = attrInt(p, name, as, "align"),
            .size_attr = attrInt(p, name, as, "size"),
        }};
        const t = p.l.next();
        if (t.is(close)) break;
        if (!t.is(sep)) p.fail(t, "expected `" ++ sep ++ "` or `" ++ close ++ "`");
    }
    return out;
}

fn resourceOf(comptime p: *Parser, comptime t: Tok, comptime address_space: []const u8, comptime access: []const u8, comptime ty: []const u8) ?Resource {
    if (eql(address_space, "uniform")) return .uniform_buffer;
    if (eql(address_space, "storage")) return .{ .storage_buffer = .{ .read_only = !eql(access, "read_write") } };
    if (address_space.len > 0) return null; // private, workgroup
    var tp = TypeParser{ .text = ty };
    const base = tp.ident();
    if (eql(base, "sampler")) return .{ .sampler = .{ .comparison = false } };
    if (eql(base, "sampler_comparison")) return .{ .sampler = .{ .comparison = true } };
    if (eql(base, "texture_external")) return .external_texture;
    if (std.mem.startsWith(u8, base, "texture_storage_")) {
        _ = tp.peekChar('<');
        tp.pos += 1;
        const format_name = tp.ident();
        _ = tp.peekChar(',');
        tp.pos += 1;
        const access_name = tp.ident();
        return .{ .storage_texture = .{
            .format = wgslFormat(p, t, format_name),
            .access = if (eql(access_name, "write")) .write_only else p.fail(t, "mach.wgsl: storage texture access `" ++ access_name ++ "` is not supported by sysgpu, only `write`"),
            .view_dimension = viewDimension(p, t, base["texture_storage_".len..]),
        } };
    }
    if (std.mem.startsWith(u8, base, "texture_depth_")) {
        const rest = base["texture_depth_".len..];
        const ms = std.mem.startsWith(u8, rest, "multisampled_");
        return .{ .texture = .{
            .sample_type = .depth,
            .view_dimension = viewDimension(p, t, if (ms) rest["multisampled_".len..] else rest),
            .multisampled = ms,
        } };
    }
    if (std.mem.startsWith(u8, base, "texture_")) {
        const rest = base["texture_".len..];
        const ms = std.mem.startsWith(u8, rest, "multisampled_");
        _ = tp.peekChar('<');
        tp.pos += 1;
        const sampled = tp.ident();
        return .{ .texture = .{
            .sample_type = if (eql(sampled, "f32")) .float else if (eql(sampled, "i32")) .sint else if (eql(sampled, "u32")) .uint else p.fail(t, "unknown texture sample type `" ++ sampled ++ "`"),
            .view_dimension = viewDimension(p, t, if (ms) rest["multisampled_".len..] else rest),
            .multisampled = ms,
        } };
    }
    return null;
}

fn viewDimension(comptime p: *Parser, comptime t: Tok, comptime s: []const u8) gpu.TextureView.Dimension {
    return std.meta.stringToEnum(gpu.TextureView.Dimension, "dimension_" ++ s) orelse p.fail(t, "unknown texture dimension `" ++ s ++ "`");
}

fn wgslFormat(comptime p: *Parser, comptime t: Tok, comptime f: []const u8) gpu.Texture.Format {
    for ([_][]const u8{ "unorm", "snorm", "uint", "sint", "float" }) |suffix| {
        if (std.mem.endsWith(u8, f, suffix)) {
            const zig_name = f[0 .. f.len - suffix.len] ++ "_" ++ suffix;
            return std.meta.stringToEnum(gpu.Texture.Format, zig_name) orelse p.fail(t, "unknown storage texture format `" ++ f ++ "`");
        }
    }
    p.fail(t, "unknown storage texture format `" ++ f ++ "`");
}

/// Collects the identifiers in a `{ ... }` body (after its opening brace), excluding member
/// accesses (`a.b` only counts `a`).
fn bodyIdents(comptime p: *Parser) []const []const u8 {
    var out: []const []const u8 = &.{};
    var depth: usize = 1;
    var prev_dot = false;
    while (depth > 0) {
        const t = p.l.next();
        switch (t.kind) {
            .eof => p.fail(t, "unterminated function body"),
            .ident => if (!prev_dot) {
                const known = for (out) |o| {
                    if (eql(o, t.text)) break true;
                } else false;
                if (!known) out = out ++ [_][]const u8{t.text};
            },
            .punct => {
                if (t.is("{")) depth += 1;
                if (t.is("}")) depth -= 1;
            },
            .number => {},
        }
        prev_dot = t.is(".");
    }
    return out;
}

/// Parses a WGSL shader, see `Shader`.
pub fn parse(comptime file: []const u8, comptime source: []const u8) Reflection {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var p = Parser{ .l = .{ .src = source }, .file = file };

        const VarDecl = struct { b: Binding };
        var vars: []const VarDecl = &.{};
        var structs: []const Struct = &.{};
        var aliases: []const Alias = &.{};
        var fns: []const Function = &.{};

        while (true) {
            const as = p.attrs();
            const t = p.l.next();
            if (t.kind == .eof) break;
            if (t.is(";")) continue;
            if (t.kind != .ident) p.fail(t, "expected a declaration");

            if (t.is("struct")) {
                const name = p.ident();
                _ = p.expect("{");
                structs = structs ++ [_]Struct{.{ .name = name.text, .members = parseMembers(&p, "}", ","), .line = name.line }};
            } else if (t.is("alias")) {
                const name = p.ident();
                _ = p.expect("=");
                aliases = aliases ++ [_]Alias{.{ .name = name.text, .type_name = p.typeText() }};
                _ = p.expect(";");
            } else if (t.is("var")) {
                var address_space: []const u8 = "";
                var access: []const u8 = "";
                if (p.l.peek().is("<")) {
                    _ = p.l.next();
                    address_space = p.ident().text;
                    if (p.l.peek().is(",")) {
                        _ = p.l.next();
                        access = p.ident().text;
                    }
                    _ = p.expect(">");
                }
                const name = p.ident();
                var ty: []const u8 = "";
                if (p.l.peek().is(":")) {
                    _ = p.l.next();
                    ty = p.typeText();
                }
                if (!p.l.peek().is(";")) p.skipStatement() else _ = p.l.next();
                const group = attrInt(&p, name, as, "group");
                const binding = attrInt(&p, name, as, "binding");
                if (group == null and binding == null) continue;
                if (group == null or binding == null) p.fail(name, "resource variables need both @group and @binding");
                const resource = resourceOf(&p, name, address_space, access, ty) orelse
                    p.fail(name, "@group/@binding on a variable which isn't a resource");
                vars = vars ++ [_]VarDecl{.{ .b = .{
                    .group = group.?,
                    .binding = binding.?,
                    .name = name.text,
                    .type_name = ty,
                    .resource = resource,
                    .visibility = .{},
                    .line = name.line,
                } }};
            } else if (t.is("fn")) {
                const name = p.ident();
                _ = p.expect("(");
                const params = parseMembers(&p, ")", ",");
                var return_type: ?[]const u8 = null;
                var return_location: ?u32 = null;
                if (p.l.peek().is("->")) {
                    _ = p.l.next();
                    const ras = p.attrs();
                    return_location = attrInt(&p, name, ras, "location");
                    return_type = p.typeText();
                }
                _ = p.expect("{");
                const stage: ?Stage = if (findAttr(as, "vertex") != null) .vertex else if (findAttr(as, "fragment") != null) .fragment else if (findAttr(as, "compute") != null) .compute else null;
                fns = fns ++ [_]Function{.{
                    .name = name.text,
                    .stage = stage,
                    .params = params,
                    .return_type = return_type,
                    .return_location = return_location,
                    .idents = bodyIdents(&p),
                    .line = name.line,
                }};
            } else if (t.is("const") or t.is("override") or t.is("enable") or t.is("requires") or t.is("diagnostic") or t.is("const_assert")) {
                p.skipStatement();
            } else {
                p.fail(t, "unexpected top-level token");
            }
        }

        const r0: Reflection = .{ .name = file, .bindings = &.{}, .entry_points = &.{}, .structs = structs, .aliases = aliases };

        // Which bindings each entry point uses, through the functions it calls.
        var bindings: [vars.len]Binding = undefined;
        for (vars, 0..) |v, i| bindings[i] = v.b;
        var entry_points: []const EntryPoint = &.{};
        for (fns) |f| {
            const stage = f.stage orelse continue;
            var reached: []const []const u8 = &.{f.name};
            var i: usize = 0;
            while (i < reached.len) : (i += 1) {
                const g = for (fns) |g| {
                    if (eql(g.name, reached[i])) break g;
                } else continue;
                for (g.idents) |id| {
                    const is_fn = for (fns) |h| {
                        if (eql(h.name, id)) break true;
                    } else false;
                    const seen = for (reached) |x| {
                        if (eql(x, id)) break true;
                    } else false;
                    if (is_fn and !seen) reached = reached ++ [_][]const u8{id};
                }
            }
            var uses: []const usize = &.{};
            for (&bindings, 0..) |*b, bi| {
                const used = for (reached) |fn_name| {
                    const g = for (fns) |g| {
                        if (eql(g.name, fn_name)) break g;
                    } else unreachable;
                    const found = for (g.idents) |id| {
                        if (eql(id, b.name)) break true;
                    } else false;
                    if (found) break true;
                } else false;
                if (used) {
                    b.visibility = b.visibility.with(stage);
                    uses = uses ++ [_]usize{bi};
                }
            }

            var inputs: []const Location = &.{};
            for (f.params) |param| {
                if (param.location) |loc| {
                    inputs = inputs ++ [_]Location{.{ .location = loc, .name = param.name, .type_name = param.type_name }};
                } else if (findStruct(r0, resolveAlias(r0, param.type_name))) |s| {
                    for (s.members) |m| if (m.location) |loc| {
                        inputs = inputs ++ [_]Location{.{ .location = loc, .name = m.name, .type_name = m.type_name }};
                    };
                }
            }
            var outputs: []const Location = &.{};
            if (f.return_location) |loc| {
                outputs = outputs ++ [_]Location{.{ .location = loc, .name = "return", .type_name = f.return_type.? }};
            } else if (f.return_type) |rt| {
                if (findStruct(r0, resolveAlias(r0, rt))) |s| {
                    for (s.members) |m| if (m.location) |loc| {
                        outputs = outputs ++ [_]Location{.{ .location = loc, .name = m.name, .type_name = m.type_name }};
                    };
                }
            }
            entry_points = entry_points ++ [_]EntryPoint{.{
                .name = f.name,
                .stage = stage,
                .inputs = inputs,
                .outputs = outputs,
                .uses = uses,
                .line = f.line,
            }};
        }

        // Binding conflicts and buffer sizes.
        for (&bindings, 0..) |*b, i| {
            for (bindings[0..i]) |prev| {
                if (prev.group == b.group and prev.binding == b.binding) {
                    @compileError(std.fmt.comptimePrint("{s}:{d}: `{s}` and `{s}` (line {d}) both use @group({d}) @binding({d})", .{ file, b.line, b.name, prev.name, prev.line, b.group, b.binding }));
                }
            }
            switch (b.resource) {
                .uniform_buffer, .storage_buffer => {
                    const l = typeLayout(r0, b.type_name);
                    b.min_size = l.size;
                    b.elem_size = @intCast(if (l.runtime_sized) l.elem_size else std.mem.alignForward(u64, l.size, l.alignment));
                },
                else => {},
            }
        }

        const final_bindings = bindings;
        const final_entries = entry_points[0..entry_points.len].*;
        const final_structs = structs[0..structs.len].*;
        const final_aliases = aliases[0..aliases.len].*;
        return .{
            .name = file,
            .bindings = &final_bindings,
            .entry_points = &final_entries,
            .structs = &final_structs,
            .aliases = &final_aliases,
        };
    }
}

// ---------------------------------------------------------------------------------------------
// Tests

const sprite_wgsl = @embedFile("gfx/sprite.wgsl");
const text_wgsl = @embedFile("gfx/text.wgsl");

test "reflects sprite.wgsl" {
    const S = Shader("sprite.wgsl", sprite_wgsl);
    try std.testing.expectEqual(6, S.bindings.len);
    try std.testing.expectEqual(1, S.num_groups);

    const uniforms = comptime S.binding("uniforms");
    try std.testing.expect(uniforms.resource == .uniform_buffer);
    try std.testing.expect(uniforms.visibility.vertex and !uniforms.visibility.fragment);
    try std.testing.expectEqual(80, uniforms.min_size);

    const transforms = comptime S.binding("sprite_transforms");
    try std.testing.expect(transforms.resource.storage_buffer.read_only);
    try std.testing.expectEqual(64, transforms.elem_size);
    try std.testing.expectEqual(64, transforms.min_size);

    const tex = comptime S.binding("spriteTexture");
    try std.testing.expect(tex.visibility.fragment and !tex.visibility.vertex);
    try std.testing.expectEqual(gpu.Texture.SampleType.float, tex.resource.texture.sample_type);
    try std.testing.expectEqual(gpu.TextureView.Dimension.dimension_2d, tex.resource.texture.view_dimension);

    try std.testing.expectEqualStrings("vertMain", S.vertexEntry("vertMain"));
    try std.testing.expectEqualStrings("fragMain", S.fragmentEntry("fragMain"));
    const frag = comptime S.entryPoint(.fragment, "fragMain");
    try std.testing.expectEqual(1, frag.inputs.len);
    try std.testing.expectEqual(1, frag.outputs.len);
    comptime S.checkColorTargets("fragMain", 1);
}

test "generated layouts pass the check, and match sprite's hand-written layout" {
    const S = Shader("sprite.wgsl", sprite_wgsl);
    const generated = comptime S.layoutEntries(0);
    comptime S.checkLayout(0, &generated);

    // Sprite's layout has extra texture entries for custom multi-texturing shaders: allowed.
    const hand_written = comptime [_]gpu.BindGroupLayout.Entry{
        gpu.BindGroupLayout.Entry.initBuffer(0, .{ .vertex = true }, .uniform, false, 0),
        gpu.BindGroupLayout.Entry.initBuffer(1, .{ .vertex = true }, .read_only_storage, false, 0),
        gpu.BindGroupLayout.Entry.initBuffer(2, .{ .vertex = true }, .read_only_storage, false, 0),
        gpu.BindGroupLayout.Entry.initBuffer(3, .{ .vertex = true }, .read_only_storage, false, 0),
        gpu.BindGroupLayout.Entry.initSampler(4, .{ .fragment = true }, .filtering),
        gpu.BindGroupLayout.Entry.initTexture(5, .{ .fragment = true }, .float, .dimension_2d, false),
        gpu.BindGroupLayout.Entry.initTexture(6, .{ .fragment = true }, .float, .dimension_2d, false),
    };
    comptime S.checkLayout(0, &hand_written);
}

test "diagnoses wrong layouts" {
    const S = Shader("sprite.wgsl", sprite_wgsl);
    const bs = comptime S.groupBindings(0);
    const Case = struct { entries: []const gpu.BindGroupLayout.Entry, contains: []const u8 };
    const base = comptime S.layoutEntries(0);
    const cases = comptime blk: {
        var missing = base;
        missing[5].binding = 9;
        var wrong_kind = base;
        wrong_kind[0] = gpu.BindGroupLayout.Entry.initBuffer(0, .{ .vertex = true }, .read_only_storage, false, 0);
        var wrong_vis = base;
        wrong_vis[4] = gpu.BindGroupLayout.Entry.initSampler(4, .{ .vertex = true }, .filtering);
        var wrong_tex = base;
        wrong_tex[5] = gpu.BindGroupLayout.Entry.initTexture(5, .{ .fragment = true }, .uint, .dimension_2d, false);
        var wrong_dim = base;
        wrong_dim[5] = gpu.BindGroupLayout.Entry.initTexture(5, .{ .fragment = true }, .float, .dimension_2d_array, false);
        var small = base;
        small[0] = gpu.BindGroupLayout.Entry.initBuffer(0, .{ .vertex = true }, .uniform, false, 64);
        const m = missing;
        const wk = wrong_kind;
        const wv = wrong_vis;
        const wt = wrong_tex;
        const wd = wrong_dim;
        const sm = small;
        break :blk [_]Case{
            .{ .entries = &m, .contains = "has no entry for this binding" },
            .{ .entries = &wk, .contains = "the shader declares a uniform buffer, but layout entry 0 is a read-only storage buffer" },
            .{ .entries = &wv, .contains = "the fragment stage uses it, but layout entry 4 is only visible to .{ .vertex = true }" },
            .{ .entries = &wt, .contains = "samples it as .float, but the layout entry has sample type .uint" },
            .{ .entries = &wd, .contains = "view dimension .dimension_2d_array" },
            .{ .entries = &sm, .contains = "needs at least 80 bytes" },
        };
    };
    inline for (cases) |c| {
        const msg = comptime diagnoseLayout("sprite.wgsl", bs, c.entries) orelse return error.TestExpectedError;
        if (std.mem.indexOf(u8, msg, c.contains) == null) {
            std.debug.print("message: {s}\nexpected to contain: {s}\n", .{ msg, c.contains });
            return error.TestUnexpectedResult;
        }
        // Every message suggests a fix.
        try std.testing.expect(std.mem.indexOf(u8, msg, "fix:") != null);
    }
}

test "host type layouts" {
    const S = Shader("text.wgsl", text_wgsl);
    const Mat4 = extern struct { v: [16]f32 };
    const Vec2 = extern struct { v: [2]f32 };
    const Vec4 = extern struct { v: [4]f32 };
    const Uniforms = extern struct {
        view_projection: Mat4 align(16),
        texture_size: Vec2 align(16),
    };
    comptime S.checkHostType("uniforms", Uniforms);

    const Glyph = extern struct { pos: Vec2, size: Vec2, uv_pos: Vec2, text_index: u32, text_padding: u32, color: Vec4 };
    comptime S.checkHostType("glyphs", Glyph);
    comptime S.checkHostType("transforms", Mat4);
    try std.testing.expectEqual(48, comptime S.layoutOf("Glyph").size);

    // Missing the alignment of texture_size's struct padding: Uniforms is 72 bytes, not 80.
    const BadUniforms = extern struct { view_projection: Mat4, texture_size: Vec2 };
    const msg = comptime diagnoseHostType(S.reflection, "uniforms", BadUniforms).?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "the shader struct is 80 bytes") != null);

    // A vec3 is 16-byte aligned in WGSL.
    const BadGlyph = extern struct { pos: Vec2, size: Vec2, uv_pos: Vec2, text_index: u32, color: Vec4 };
    const msg2 = comptime diagnoseHostType(S.reflection, "glyphs", BadGlyph).?;
    try std.testing.expect(std.mem.indexOf(u8, msg2, "has 6 members") != null);
}

test "parses the rest of WGSL's declarations" {
    const S = Shader("test.wgsl",
        \\enable f16;
        \\alias Color = vec4f;
        \\const PI: f32 = 3.14;
        \\override scale: f32 = 1.0;
        \\struct Light { pos: vec3<f32>, @size(16) intensity: f32, color: Color, }
        \\struct VsIn { @location(0) pos: vec3f, @location(1) uv: vec2f, @builtin(instance_index) i: u32 }
        \\struct VsOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f }
        \\struct FsOut { @location(0) color: vec4f, @location(1) normal: vec4f }
        \\@group(0) @binding(0) var<storage, read_write> lights: array<Light>;
        \\@group(1) @binding(0) var shadow: texture_depth_2d;
        \\@group(1) @binding(1) var shadow_sampler: sampler_comparison;
        \\@group(1) @binding(2) var out_tex: texture_storage_2d<rgba8unorm, write>;
        \\@group(1) @binding(3) var arr: texture_2d_array<u32>;
        \\var<private> counter: u32;
        \\fn helper(x: f32) -> f32 { return lights[0].intensity * x; }
        \\/* block /* nested */ comment */
        \\@vertex fn vs(in: VsIn) -> VsOut { var o: VsOut; o.uv = in.uv * helper(1.0); return o; }
        \\@fragment fn fs(v: VsOut) -> FsOut {
        \\  let d = textureSampleCompare(shadow, shadow_sampler, v.uv, 0.5);
        \\  return FsOut(vec4f(d), vec4f(0));
        \\}
        \\@compute @workgroup_size(8, 8) fn cs(@builtin(global_invocation_id) id: vec3<u32>) {
        \\  textureStore(out_tex, id.xy, vec4f(f32(textureLoad(arr, id.xy, 0, 0).x)));
        \\}
    );
    const lights = comptime S.binding("lights");
    try std.testing.expect(!lights.resource.storage_buffer.read_only);
    try std.testing.expect(lights.visibility.vertex and !lights.visibility.fragment);
    // vec3 (12) + @size(16) f32 at 12 -> 28, color aligned to 32 -> 48.
    try std.testing.expectEqual(48, lights.elem_size);
    const shadow = comptime S.binding("shadow");
    try std.testing.expectEqual(gpu.Texture.SampleType.depth, shadow.resource.texture.sample_type);
    try std.testing.expect(shadow.visibility.fragment);
    try std.testing.expect((comptime S.binding("shadow_sampler")).resource.sampler.comparison);
    const out_tex = comptime S.binding("out_tex");
    try std.testing.expectEqual(gpu.Texture.Format.rgba8_unorm, out_tex.resource.storage_texture.format);
    try std.testing.expect(out_tex.visibility.compute);
    const arr = comptime S.binding("arr");
    try std.testing.expectEqual(gpu.TextureView.Dimension.dimension_2d_array, arr.resource.texture.view_dimension);
    try std.testing.expectEqual(gpu.Texture.SampleType.uint, arr.resource.texture.sample_type);
    try std.testing.expectEqual(2, S.num_groups);

    const vs = comptime S.entryPoint(.vertex, "vs");
    try std.testing.expectEqual(2, vs.inputs.len);
    const fs = comptime S.entryPoint(.fragment, "fs");
    try std.testing.expectEqual(2, fs.outputs.len);

    const attrs = [_]gpu.VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x2, .offset = 12, .shader_location = 1 },
    };
    const buffers = comptime [_]gpu.VertexBufferLayout{gpu.VertexBufferLayout.init(.{ .array_stride = 20, .attributes = &attrs })};
    comptime S.checkVertexBuffers("vs", &buffers);
    const bad_attrs = [_]gpu.VertexAttribute{.{ .format = .float32x3, .offset = 0, .shader_location = 0 }};
    const bad = comptime [_]gpu.VertexBufferLayout{gpu.VertexBufferLayout.init(.{ .array_stride = 12, .attributes = &bad_attrs })};
    try std.testing.expect(comptime diagnoseVertexBuffers("test.wgsl", S.reflection, S.entryPoint(.vertex, "vs"), &bad) != null);

    const entries = comptime S.layoutEntries(1);
    try std.testing.expectEqual(4, entries.len);
    comptime S.checkLayout(1, &entries);
}
