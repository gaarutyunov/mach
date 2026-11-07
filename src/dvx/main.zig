//! Developer experience: opt-in tools for inspecting and tuning a running Mach application.

/// Atomic counters, gauges and histograms, calculated only with `-Dmetrics`.
pub const metrics = @import("metrics.zig");

// Mach modules
/// Developer overlay (frame timing, per-module memory).
pub const DevOverlay = @import("DevOverlay.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(metrics);
    std.testing.refAllDecls(DevOverlay);
    _ = @import("gpu_lint.zig");
}
