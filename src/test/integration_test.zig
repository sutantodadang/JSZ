// SPDX-License-Identifier: Apache-2.0
//! Integration test orchestrator.
//! All test bodies live in src/test/integration/*.zig, split by feature area.
//! Zig discovers tests from any file reachable via @import from root.zig.
//!
//! Sub-file layout (R5 split 2026-06-11):
//!   integration/helpers.zig    – shared eval helpers (no tests)
//!   integration/core.zig       – integration, phase3a, gc, phase7          (46 tests)
//!   integration/jit.zig        – S6/S7/S8, JIT double, Phase 9             (13 tests)
//!   integration/async.zig      – W2, W2-async, W2 unification, await, promise (24 tests)
//!   integration/esm.zig        – esm, snapshot                             (18 tests)
//!   integration/es_features.zig – es2016–2022, tco, debugger, source map   (44 tests)
//!   integration/phase13.zig    – phase13                                   (39 tests)
//!   integration/typed_array.zig – TypedArray constructors + prototype methods (28 tests)
//!   integration/temporal_calendar.zig – Temporal non-ISO calendars            (9 tests)

// Pull in each sub-file so Zig discovers their test blocks.
const _core = @import("./integration/core.zig");
const _jit = @import("./integration/jit.zig");
const _async = @import("./integration/async.zig");
const _esm = @import("./integration/esm.zig");
const _es_features = @import("./integration/es_features.zig");
const _phase13 = @import("./integration/phase13.zig");
const _typed_array = @import("./integration/typed_array.zig");
const _temporal_calendar = @import("./integration/temporal_calendar.zig");

// Suppress unused-import warnings.
comptime {
    _ = _core;
    _ = _jit;
    _ = _async;
    _ = _esm;
    _ = _es_features;
    _ = _phase13;
    _ = _typed_array;
    _ = _temporal_calendar;
}
