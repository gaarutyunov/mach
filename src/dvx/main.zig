//! Developer experience: opt-in tools for inspecting and tuning a running Mach application.

// Mach modules
/// Developer overlay (frame timing, per-module memory).
pub const DevOverlay = @import("DevOverlay.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(DevOverlay);
}
