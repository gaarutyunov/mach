//! Implements a [texture atlas](https://en.wikipedia.org/wiki/Texture_atlas).
//!
//! This implementation is based on "A Thousand Ways to Pack the Bin - A Practical Approach to
//! Two-Dimensional Rectangle Bin Packing" by Jukka Jylänki. This specific implementation originates
//! [from Mitchell Hashimoto](https://gist.github.com/mitchellh/0c023dbd381c42e145b5da8d58b1487f)
//! which is itself based heavily on Nicolas P. Rougier's freetype-gl project as well as Jukka's C++
//! [implementation](https://github.com/juj/RectangleBinPack).
//!
//! There are two known limitations:
//!
//!   * Written data must be packed, no support for custom strides.
//!   * Texture is always a square, no ability to set width != height. Note
//!     that regions written INTO the atlas do not have to be square, only
//!     the full atlas texture itself.
//!
//! ## Mipmaps
//!
//! An atlas created with `initMipmapped` keeps a full mip chain and guarantees that entries never
//! bleed into each other at any mip level. This uses the block padding technique from
//! [image-atlas](https://github.com/GossiperLoturot/image-atlas): every entry is snapped to a grid
//! of `block_size` (a power of two) cells and surrounded by `block_size / 2` pixels of padding that
//! is filled from the entry's own edges (see `Wrap`). Mips are then generated per entry, so after
//! `log2(block_size)` halvings each cell is still at least 1px and contains only its own entry.
//! The mip chain therefore has `log2(block_size) + 1` levels.
//!
const Atlas = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const mach = @import("../../main.zig");
const math = mach.math;

const log = std.log.scoped(.atlas);

/// Data is the raw texture data.
data: []u8,

/// Width and height of the atlas texture. The current implementation is
/// always square so this is both the width and the height.
size: u32 = 0,

/// The nodes (rectangles) of available space.
nodes: std.ArrayList(Node) = .empty,

/// The format of the texture data being written into the Atlas. This must be
/// uniform for all textures in the Atlas. If you have some textures with
/// different formats, you must use multiple atlases or convert the textures.
format: Format = .greyscale,

/// This will be set to true when the atlas has data set on it. It is up
/// to the user of the atlas to set this to false when they observe the value.
/// This is a useful value to know if you need to send new data to the GPU or
/// not.
modified: bool = false,

/// This will be set to true when the atlas has been resized. It is up
/// to the user of the atlas to set this to false when they observe the value.
/// The resized value is useful for sending textures to the GPU to know if
/// a new texture needs to be allocated or if an existing one can be
/// updated in-place.
resized: bool = false,

/// Size of the packing grid cells in pixels. 1 means the atlas has no mipmaps. Otherwise a power
/// of two, and the atlas is mipmapped (see `initMipmapped`).
block_size: u32 = 1,

/// Mip levels 1..mipLevelCount()-1 (level 0 is `data`). Level `n` is `size >> n` pixels square.
/// Empty when the atlas has no mipmaps.
mip_data: [][]u8 = &.{},

pub const Format = enum(u8) {
    greyscale = 0,
    rgb = 1,
    rgba = 2,

    pub fn depth(self: Format) u8 {
        return switch (self) {
            .greyscale => 1,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

const Cell = struct { x: u32, y: u32 };

const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

pub const Error = error{
    /// Atlas cannot fit the desired region. You must enlarge the atlas.
    AtlasFull,
    /// Mipmap block size must be a power of two and at least 2.
    InvalidBlockSize,
    /// Mipmapped atlas size must be a non-zero multiple of the block size.
    InvalidSize,
};

/// How the padding around a mipmapped entry is filled, i.e. what the entry looks like when
/// sampled slightly outside its bounds (and therefore what its edges blend with in lower mips).
/// Match it to the sampler address mode you emulate for that entry.
pub const Wrap = enum {
    /// Extend the edge pixels outward.
    clamp,
    /// Tile the entry.
    repeat,
    /// Tile the entry, flipping every other tile.
    mirror,
};

/// A region within the texture atlas. These can be acquired using the
/// "reserve" function. A region reservation is required to write data.
pub const Region = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub const UV = extern struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    pub inline fn calculateUV(r: Region, size: u32) UV {
        var uv = UV{
            .x = @floatFromInt(r.x),
            .y = @floatFromInt(r.y),
            .width = @floatFromInt(r.width),
            .height = @floatFromInt(r.height),
        };
        uv.x /= @floatFromInt(size);
        uv.y /= @floatFromInt(size);
        uv.width /= @floatFromInt(size);
        uv.height /= @floatFromInt(size);
        return uv;
    }
};

pub fn init(alloc: Allocator, size: u32, format: Format) !Atlas {
    var result = Atlas{
        .data = try alloc.alloc(u8, size * size * format.depth()),
        .size = size,
        .nodes = .empty,
        .format = format,
    };
    errdefer result.deinit(alloc);

    // TODO: figure out optimal prealloc based on real world usage
    try result.nodes.ensureUnusedCapacity(alloc, 64);

    // This sets up our initial state
    result.clear();
    result.modified = false;

    return result;
}

/// Create a mipmapped atlas. See the "Mipmaps" section of the file documentation.
///
/// `block_size` must be a power of two >= 2 and `size` a multiple of it. Larger blocks give more
/// mip levels (`log2(block_size) + 1`) at the cost of more padding per entry. Regions returned by
/// `reserve` are the entry's own pixels; the padding is managed internally.
pub fn initMipmapped(alloc: Allocator, size: u32, format: Format, block_size: u32) !Atlas {
    if (block_size < 2 or !std.math.isPowerOfTwo(block_size)) return Error.InvalidBlockSize;
    if (size == 0 or size % block_size != 0) return Error.InvalidSize;

    var result = try init(alloc, size, format);
    errdefer result.deinit(alloc);
    result.block_size = block_size;

    const levels = result.mipLevelCount();
    result.mip_data = try alloc.alloc([]u8, levels - 1);
    for (result.mip_data) |*level| level.* = &.{};
    for (result.mip_data, 1..) |*level, i| {
        const level_size = size >> @intCast(i);
        level.* = try alloc.alloc(u8, level_size * level_size * format.depth());
    }

    result.clear();
    result.modified = false;
    return result;
}

pub fn deinit(self: *Atlas, alloc: Allocator) void {
    self.nodes.deinit(alloc);
    alloc.free(self.data);
    for (self.mip_data) |level| alloc.free(level);
    if (self.mip_data.len > 0) alloc.free(self.mip_data);
    self.* = undefined;
}

/// Number of mip levels, including the base level. 1 for an atlas without mipmaps.
pub fn mipLevelCount(self: Atlas) u32 {
    return std.math.log2_int(u32, self.block_size) + 1;
}

/// Raw texture data of the given mip level (0 is `data`).
pub fn levelData(self: Atlas, level: u32) []u8 {
    return if (level == 0) self.data else self.mip_data[level - 1];
}

/// Width and height in pixels of the given mip level.
pub fn levelSize(self: Atlas, level: u32) u32 {
    return self.size >> @intCast(level);
}

/// Size of the packing grid in cells. Equal to `size` without mipmaps.
fn gridSize(self: Atlas) u32 {
    return self.size / self.block_size;
}

/// Without mipmaps a 1px border is kept around the texture to avoid artifacting when
/// sampling. Mipmapped atlases don't need it, entries are already padded.
fn border(self: Atlas) u32 {
    return if (self.block_size == 1) 1 else 0;
}

/// Number of grid cells a mipmapped entry of `len` pixels occupies along one axis: the entry plus
/// `block_size / 2` padding on both sides, rounded up to whole blocks.
fn cellsFor(self: Atlas, len: u32) u32 {
    return (len + self.block_size - 1) / self.block_size + 1;
}

/// Reserve a region within the atlas with the given width and height.
///
/// May allocate to add a new rectangle into the internal list of rectangles.
/// This will not automatically enlarge the texture if it is full.
///
/// For a mipmapped atlas the returned region covers only the entry itself, the padding needed for
/// mipmapping is reserved around it.
pub fn reserve(self: *Atlas, alloc: Allocator, width: u32, height: u32) !Region {
    // If our width/height are 0, then we return the region as-is. This
    // may seem like an error case but it simplifies downstream callers who
    // might be trying to write empty data.
    if (width == 0 and height == 0) return .{ .x = 0, .y = 0, .width = width, .height = height };

    if (self.block_size == 1) {
        const cell = try self.reserveCells(alloc, width, height);
        return .{ .x = cell.x, .y = cell.y, .width = width, .height = height };
    }

    const cell = try self.reserveCells(alloc, self.cellsFor(width), self.cellsFor(height));
    const padding = self.block_size / 2;
    return .{
        .x = cell.x * self.block_size + padding,
        .y = cell.y * self.block_size + padding,
        .width = width,
        .height = height,
    };
}

/// Reserve width x height cells of the packing grid, returning the top-left cell.
fn reserveCells(self: *Atlas, alloc: Allocator, width: u32, height: u32) !Cell {
    // x, y are populated within :best_idx below
    var region: Cell = .{ .x = 0, .y = 0 };

    // Find the location in our nodes list to insert the new node for this region.
    const best_idx: usize = best_idx: {
        var best_height: u32 = math.maxInt(u32);
        var best_width: u32 = best_height;
        var chosen: ?usize = null;

        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            // Check if our region fits within this node.
            const y = self.fit(i, width, height) orelse continue;

            const node = self.nodes.items[i];
            if ((y + height) < best_height or
                ((y + height) == best_height and
                    (node.width > 0 and node.width < best_width)))
            {
                chosen = i;
                best_width = node.width;
                best_height = y + height;
                region.x = node.x;
                region.y = y;
            }
        }

        // If we never found a chosen index, the atlas cannot fit our region.
        break :best_idx chosen orelse return Error.AtlasFull;
    };

    // Insert our new node for this rectangle at the exact best index
    try self.nodes.insert(alloc, best_idx, .{
        .x = region.x,
        .y = region.y + height,
        .width = width,
    });

    // Optimize our rectangles
    var i: usize = best_idx + 1;
    while (i < self.nodes.items.len) : (i += 1) {
        const node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x < (prev.x + prev.width)) {
            const shrink = prev.x + prev.width - node.x;
            node.x += shrink;
            node.width -|= shrink;
            if (node.width <= 0) {
                _ = self.nodes.orderedRemove(i);
                i -= 1;
                continue;
            }
        }

        break;
    }
    self.merge();

    return region;
}

/// Attempts to fit a rectangle of width x height into the node at idx.
/// The return value is the y within the texture where the rectangle can be
/// placed. The x is the same as the node.
fn fit(self: Atlas, idx: usize, width: u32, height: u32) ?u32 {
    // If the added width exceeds our texture size, it doesn't fit.
    const limit = self.gridSize() - self.border();
    const node = self.nodes.items[idx];
    if ((node.x + width) > limit) return null;

    // Go node by node looking for space that can fit our width.
    var y = node.y;
    var i = idx;
    var width_left = width;
    while (width_left > 0) : (i += 1) {
        const n = self.nodes.items[i];
        if (n.y > y) y = n.y;

        // If the added height exceeds our texture size, it doesn't fit.
        if ((y + height) > limit) return null;

        width_left -|= n.width;
    }

    return y;
}

/// Merge adjacent nodes with the same y value.
fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i < self.nodes.items.len - 1) {
        const node = &self.nodes.items[i];
        const next = self.nodes.items[i + 1];
        if (node.y == next.y) {
            node.width += next.width;
            _ = self.nodes.orderedRemove(i + 1);
            continue;
        }

        i += 1;
    }
}

/// Set the data associated with a reserved region. The data is expected
/// to fit exactly within the region. The data must be formatted with the
/// proper bpp configured on init.
///
/// For a mipmapped atlas this also fills the entry's padding (clamping to its edges) and
/// regenerates its mips. Use `setWrapped` to choose another padding mode.
pub fn set(self: *Atlas, reg: Region, data: []const u8) void {
    if (self.block_size != 1) return self.setWrapped(reg, data, .clamp);

    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));

    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const data_offset = i * reg.width * depth;
        const src = data[data_offset .. data_offset + (reg.width * depth)];
        @memcpy(self.data[tex_offset .. tex_offset + src.len], src);
    }

    self.modified = true;
}

/// Set the data of a region reserved in a mipmapped atlas, filling the padding around it
/// according to `wrap` and regenerating the mips of the entry. See `set`.
pub fn setWrapped(self: *Atlas, reg: Region, data: []const u8, wrap: Wrap) void {
    if (self.block_size == 1) return self.set(reg, data);
    if (reg.width == 0 or reg.height == 0) return;

    const depth: u32 = self.format.depth();
    const padding = self.block_size / 2;
    assert(data.len >= reg.width * reg.height * depth);

    // The cell this region was reserved in, see `reserve`.
    assert(reg.x >= padding and reg.y >= padding);
    const cell_x = reg.x - padding;
    const cell_y = reg.y - padding;
    const cell_w = self.cellsFor(reg.width) * self.block_size;
    const cell_h = self.cellsFor(reg.height) * self.block_size;
    assert(cell_x % self.block_size == 0 and cell_y % self.block_size == 0);
    assert(cell_x + cell_w <= self.size and cell_y + cell_h <= self.size);

    // Level 0: the entry surrounded by its padding.
    var y: u32 = 0;
    while (y < cell_h) : (y += 1) {
        const sy = wrapCoord(@as(i64, y) - padding, reg.height, wrap);
        const row = ((cell_y + y) * self.size + cell_x) * depth;
        var x: u32 = 0;
        while (x < cell_w) : (x += 1) {
            const sx = wrapCoord(@as(i64, x) - padding, reg.width, wrap);
            const src = (sy * reg.width + sx) * depth;
            const dst = row + x * depth;
            @memcpy(self.data[dst .. dst + depth], data[src .. src + depth]);
        }
    }

    // Lower levels: 2x2 box filter of the previous level, restricted to this cell. Cells are a
    // multiple of block_size, so they halve exactly down to the last level.
    var level: u32 = 1;
    while (level < self.mipLevelCount()) : (level += 1) {
        downsample(
            self.levelData(level - 1),
            self.levelSize(level - 1),
            self.levelData(level),
            self.levelSize(level),
            cell_x >> @intCast(level),
            cell_y >> @intCast(level),
            cell_w >> @intCast(level),
            cell_h >> @intCast(level),
            depth,
        );
    }

    self.modified = true;
}

/// Map a coordinate relative to an entry of length `len` (possibly outside of it) to a pixel of
/// the entry.
fn wrapCoord(i: i64, len: u32, wrap: Wrap) u32 {
    const n: i64 = len;
    return @intCast(switch (wrap) {
        .clamp => std.math.clamp(i, 0, n - 1),
        .repeat => @mod(i, n),
        .mirror => blk: {
            const m = @mod(i, 2 * n);
            break :blk if (m < n) m else 2 * n - 1 - m;
        },
    });
}

/// Write the w x h rectangle at (x, y) of `dst` by averaging 2x2 pixels of `src`, the level above.
fn downsample(src: []const u8, src_size: u32, dst: []u8, dst_size: u32, x: u32, y: u32, w: u32, h: u32, depth: u32) void {
    var dy: u32 = 0;
    while (dy < h) : (dy += 1) {
        const r0 = (2 * (y + dy)) * src_size;
        const r1 = r0 + src_size;
        var dx: u32 = 0;
        while (dx < w) : (dx += 1) {
            const sx = 2 * (x + dx);
            const dst_off = ((y + dy) * dst_size + x + dx) * depth;
            var c: u32 = 0;
            while (c < depth) : (c += 1) {
                const sum = @as(u32, src[(r0 + sx) * depth + c]) + src[(r0 + sx + 1) * depth + c] +
                    src[(r1 + sx) * depth + c] + src[(r1 + sx + 1) * depth + c];
                dst[dst_off + c] = @intCast((sum + 2) / 4);
            }
        }
    }
}

/// Copy a size_old x size_old image into the top-left corner of a size_new x size_new one.
fn copyInto(dst: []u8, size_new: u32, src: []const u8, size_old: u32, depth: u32) void {
    @memset(dst, 0);
    const row_len = size_old * depth;
    var y: u32 = 0;
    while (y < size_old) : (y += 1) {
        @memcpy(dst[y * size_new * depth ..][0..row_len], src[y * row_len ..][0..row_len]);
    }
}

// Grow the texture to the new size, preserving all previously written data.
//
// For a mipmapped atlas the new size must be a multiple of the block size.
pub fn grow(self: *Atlas, alloc: Allocator, size_new: u32) Allocator.Error!void {
    assert(size_new >= self.size);
    assert(size_new % self.block_size == 0);
    if (size_new == self.size) return;

    const depth = self.format.depth();
    const size_old = self.size;
    const levels = self.mipLevelCount();

    // Allocate all new levels up front so failure leaves the atlas untouched.
    var new_levels: [32][]u8 = undefined;
    var allocated: u32 = 0;
    errdefer for (new_levels[0..allocated]) |level| alloc.free(level);
    while (allocated < levels) : (allocated += 1) {
        const level_size = size_new >> @intCast(allocated);
        new_levels[allocated] = try alloc.alloc(u8, level_size * level_size * depth);
    }

    // Add our new rectangle for our added righthand space. We do this
    // right away since its the only operation that can fail and we want
    // to make error cleanup easier.
    const grid_old = self.gridSize();
    try self.nodes.append(alloc, .{
        .x = grid_old - self.border(),
        .y = self.border(),
        .width = size_new / self.block_size - grid_old,
    });

    // If our allocations and rectangle add succeeded, we can go ahead
    // and persist our new size and copy over the old data.
    var level: u32 = 0;
    while (level < levels) : (level += 1) {
        const old = self.levelData(level);
        copyInto(new_levels[level], size_new >> @intCast(level), old, size_old >> @intCast(level), depth);
        alloc.free(old);
        if (level == 0) self.data = new_levels[0] else self.mip_data[level - 1] = new_levels[level];
    }
    self.size = size_new;

    // We are both modified and resized
    self.modified = true;
    self.resized = true;
}

// Empty the atlas. This doesn't reclaim any previously allocated memory.
pub fn clear(self: *Atlas) void {
    self.modified = true;
    @memset(self.data, 0);
    for (self.mip_data) |level| @memset(level, 0);
    self.nodes.clearRetainingCapacity();

    // Add our initial rectangle. This is the size of the full grid
    // and is the initial rectangle we fit our regions in. Without mipmaps we keep
    // a 1px border to avoid artifacting when sampling the texture.
    const b = self.border();
    self.nodes.appendAssumeCapacity(.{ .x = b, .y = b, .width = self.gridSize() - 2 * b });
}

test "exact fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 34, .greyscale); // +2 for 1px border
    defer atlas.deinit(alloc);

    _ = try atlas.reserve(alloc, 32, 32);
    try testing.expect(!atlas.modified);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "doesnt fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .greyscale);
    defer atlas.deinit(alloc);

    // doesn't fit due to border
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 32, 32));
}

test "fit multiple" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .greyscale);
    defer atlas.deinit(alloc);

    _ = try atlas.reserve(alloc, 15, 30);
    _ = try atlas.reserve(alloc, 15, 30);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "writing data" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .greyscale);
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expect(!atlas.modified);
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    try testing.expect(atlas.modified);

    // 33 because of the 1px border and so on
    try testing.expectEqual(@as(u8, 1), atlas.data[33]);
    try testing.expectEqual(@as(u8, 2), atlas.data[34]);
    try testing.expectEqual(@as(u8, 3), atlas.data[65]);
    try testing.expectEqual(@as(u8, 4), atlas.data[66]);
}

test "grow" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 4, .greyscale); // +2 for 1px border
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));

    // Write some data so we can verify that growing doesn't mess it up
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(u8, 1), atlas.data[5]);
    try testing.expectEqual(@as(u8, 2), atlas.data[6]);
    try testing.expectEqual(@as(u8, 3), atlas.data[9]);
    try testing.expectEqual(@as(u8, 4), atlas.data[10]);

    // Reset our state
    atlas.modified = false;
    atlas.resized = false;

    // Expand by exactly 1 should fit our new 1x1 block.
    try atlas.grow(alloc, atlas.size + 1);
    try testing.expect(atlas.modified);
    try testing.expect(atlas.resized);
    _ = try atlas.reserve(alloc, 1, 1);

    // Ensure our data is still set. Not the offsets change due to size.
    try testing.expectEqual(@as(u8, 1), atlas.data[atlas.size + 1]);
    try testing.expectEqual(@as(u8, 2), atlas.data[atlas.size + 2]);
    try testing.expectEqual(@as(u8, 3), atlas.data[atlas.size * 2 + 1]);
    try testing.expectEqual(@as(u8, 4), atlas.data[atlas.size * 2 + 2]);
}

test "writing RGB data" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .rgb);
    defer atlas.deinit(alloc);

    // This is RGB so its 3 bpp
    const reg = try atlas.reserve(alloc, 1, 2);
    atlas.set(reg, &[_]u8{
        1, 2, 3,
        4, 5, 6,
    });

    // 33 because of the 1px border and so on
    const depth = @as(usize, @intCast(atlas.format.depth()));
    try testing.expectEqual(@as(u8, 1), atlas.data[33 * depth]);
    try testing.expectEqual(@as(u8, 2), atlas.data[33 * depth + 1]);
    try testing.expectEqual(@as(u8, 3), atlas.data[33 * depth + 2]);
    try testing.expectEqual(@as(u8, 4), atlas.data[65 * depth]);
    try testing.expectEqual(@as(u8, 5), atlas.data[65 * depth + 1]);
    try testing.expectEqual(@as(u8, 6), atlas.data[65 * depth + 2]);
}

test "grow RGB" {
    const alloc = testing.allocator;

    // Atlas is 4x4 so its a 1px border meaning we only have 2x2 available
    var atlas = try init(alloc, 4, .rgb);
    defer atlas.deinit(alloc);

    // Get our 2x2, which should be ALL our usable space
    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));

    // This is RGB so its 3 bpp
    atlas.set(reg, &[_]u8{
        10, 11, 12, // (0, 0) (x, y) from top-left
        13, 14, 15, // (1, 0)
        20, 21, 22, // (0, 1)
        23, 24, 25, // (1, 1)
    });

    // Our top left skips the first row (size * depth) and the first
    // column (depth) for the 1px border.
    const depth = @as(usize, @intCast(atlas.format.depth()));
    var tl = (atlas.size * depth) + depth;
    try testing.expectEqual(@as(u8, 10), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 11), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 12), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 13), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 14), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 15), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    tl += (atlas.size * depth); // next row
    try testing.expectEqual(@as(u8, 20), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 21), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 22), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 23), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 24), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 25), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    // Expand by exactly 1 should fit our new 1x1 block.
    try atlas.grow(alloc, atlas.size + 1);

    // Data should be in same place accounting for the new size
    tl = (atlas.size * depth) + depth;
    try testing.expectEqual(@as(u8, 10), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 11), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 12), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 13), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 14), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 15), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    tl += (atlas.size * depth); // next row
    try testing.expectEqual(@as(u8, 20), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 21), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 22), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 23), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 24), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 25), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    // Should fit the new blocks around the edges
    _ = try atlas.reserve(alloc, 1, 3);
    _ = try atlas.reserve(alloc, 2, 1);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "mipmapped: invalid options" {
    const alloc = testing.allocator;
    try testing.expectError(Error.InvalidBlockSize, initMipmapped(alloc, 64, .greyscale, 1));
    try testing.expectError(Error.InvalidBlockSize, initMipmapped(alloc, 64, .greyscale, 12));
    try testing.expectError(Error.InvalidSize, initMipmapped(alloc, 60, .greyscale, 8));
}

test "mipmapped: levels" {
    const alloc = testing.allocator;
    var atlas = try initMipmapped(alloc, 64, .rgba, 8);
    defer atlas.deinit(alloc);

    try testing.expectEqual(@as(u32, 4), atlas.mipLevelCount());
    try testing.expectEqual(@as(u32, 8), atlas.levelSize(3));
    try testing.expectEqual(@as(usize, 8 * 8 * 4), atlas.levelData(3).len);
}

test "mipmapped: reserve pads to blocks" {
    const alloc = testing.allocator;
    var atlas = try initMipmapped(alloc, 32, .greyscale, 8);
    defer atlas.deinit(alloc);

    // 5x5 needs ceil(5 / 8) + 1 = 2 cells per axis: a 16x16 block with the entry at +4,+4.
    const a = try atlas.reserve(alloc, 5, 5);
    try testing.expectEqual(Region{ .x = 4, .y = 4, .width = 5, .height = 5 }, a);
    const b = try atlas.reserve(alloc, 5, 5);
    try testing.expectEqual(Region{ .x = 20, .y = 4, .width = 5, .height = 5 }, b);
    _ = try atlas.reserve(alloc, 8, 8); // exactly 2 cells
    _ = try atlas.reserve(alloc, 1, 1);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "mipmapped: entries never bleed into each other" {
    const alloc = testing.allocator;
    var atlas = try initMipmapped(alloc, 32, .greyscale, 8);
    defer atlas.deinit(alloc);

    const white: [7 * 3]u8 = @splat(255);
    const grey: [2 * 9]u8 = @splat(100);
    const a = try atlas.reserve(alloc, 7, 3);
    const b = try atlas.reserve(alloc, 2, 9);
    atlas.set(a, &white);
    atlas.set(b, &grey);
    try testing.expect(atlas.modified);

    // With clamping, each entry's cells are uniformly its own color at every level.
    var level: u32 = 0;
    while (level < atlas.mipLevelCount()) : (level += 1) {
        const size = atlas.levelSize(level);
        const data = atlas.levelData(level);
        const s: u5 = @intCast(level);
        const unit = @as(usize, 8) >> s; // one block at this level
        for (0..2 * unit) |y| for (0..2 * unit) |x| {
            try testing.expectEqual(@as(u8, 255), data[y * size + x]);
        };
        for (0..3 * unit) |y| for (2 * unit..4 * unit) |x| {
            try testing.expectEqual(@as(u8, 100), data[y * size + x]);
        };
    }
}

test "mipmapped: wrap modes fill padding" {
    const alloc = testing.allocator;
    var atlas = try initMipmapped(alloc, 16, .greyscale, 4);
    defer atlas.deinit(alloc);

    // 4x1 entry -> 2x2 cells (8x8 px), entry at (2, 2), padding of 2.
    const reg = try atlas.reserve(alloc, 4, 1);
    const row = [_]u8{ 1, 2, 3, 4 };
    const y = reg.y * atlas.size;

    atlas.setWrapped(reg, &row, .clamp);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2, 3, 4, 4, 4 }, atlas.data[y..][0..8]);
    atlas.setWrapped(reg, &row, .repeat);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 1, 2, 3, 4, 1, 2 }, atlas.data[y..][0..8]);
    atlas.setWrapped(reg, &row, .mirror);
    try testing.expectEqualSlices(u8, &.{ 2, 1, 1, 2, 3, 4, 4, 3 }, atlas.data[y..][0..8]);

    // Level 1 is the 2x2 average of level 0.
    const l1 = atlas.levelData(1);
    try testing.expectEqual(@as(u8, (2 + 1 + 2 + 1 + 2) / 4), l1[0]);
    try testing.expectEqual(@as(u8, (1 + 2 + 1 + 2 + 2) / 4), l1[1]);
}

test "mipmapped: grow preserves all levels" {
    const alloc = testing.allocator;
    var atlas = try initMipmapped(alloc, 16, .rgb, 8);
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 3, 3);
    var pixels: [9 * 3]u8 = undefined;
    for (0..9) |i| pixels[i * 3 ..][0..3].* = .{ 10, 20, 30 };
    atlas.set(reg, &pixels);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));

    try atlas.grow(alloc, 32);
    try testing.expect(atlas.resized);
    var level: u32 = 0;
    while (level < atlas.mipLevelCount()) : (level += 1) {
        try testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, atlas.levelData(level)[0..3]);
        const level_size: usize = atlas.levelSize(level);
        try testing.expectEqual(level_size * level_size * 3, atlas.levelData(level).len);
    }

    // The added space is usable.
    const b = try atlas.reserve(alloc, 3, 3);
    try testing.expectEqual(@as(u32, 20), b.x);
}
