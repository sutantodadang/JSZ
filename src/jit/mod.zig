// SPDX-License-Identifier: Apache-2.0
//! Phase 9 JIT scaffold — profiling tier re-exports.
pub const jit = @import("jit.zig");
pub const JitCompiler = jit.JitCompiler;
pub const JitError = jit.JitError;
pub const JitMode = jit.JitMode;
pub const HotEvent = jit.HotEvent;
pub const DeoptFrame = jit.DeoptFrame;
