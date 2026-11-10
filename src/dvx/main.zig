//! Developer experience: opt-in tools for inspecting and tuning a running Mach application.

/// Atomic counters, gauges and histograms, calculated only with `-Dmetrics`.
pub const metrics = @import("metrics.zig");

// Mach modules
/// Developer overlay (frame timing, per-module memory).
pub const DevOverlay = @import("DevOverlay.zig");
/// Writes snapshots of the program for the inspector tool (`zig build inspector`).
pub const Inspector = @import("Inspector.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(metrics);
    std.testing.refAllDecls(DevOverlay);
    std.testing.refAllDecls(Inspector);
    _ = @import("gpu_lint.zig");
}
