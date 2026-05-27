// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------------
    // Public module: @import("jsz") -> src/root.zig
    // ---------------------------------------------------------------------------
    const mod = b.addModule("jsz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ---------------------------------------------------------------------------
    // Main executable: jsz CLI
    // ---------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "jsz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jsz", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // zig build run -- [args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the jsz CLI");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------------
    // Tests: zig build test
    // ---------------------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ---------------------------------------------------------------------------
    // Fuzz: zig build fuzz --fuzz
    // ---------------------------------------------------------------------------
    const parser_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/test/fuzz/parser_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "jsz", .module = mod } },
    });
    const parser_fuzz = b.addTest(.{ .root_module = parser_fuzz_mod });
    const run_parser_fuzz = b.addRunArtifact(parser_fuzz);

    const vm_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/test/fuzz/vm_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "jsz", .module = mod } },
    });
    const vm_fuzz = b.addTest(.{ .root_module = vm_fuzz_mod });
    const run_vm_fuzz = b.addRunArtifact(vm_fuzz);

    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (add --fuzz for fuzzing mode)");
    fuzz_step.dependOn(&run_parser_fuzz.step);
    fuzz_step.dependOn(&run_vm_fuzz.step);

    // ---------------------------------------------------------------------------
    // Conformance: zig build conformance
    // ---------------------------------------------------------------------------
    const conformance_exe = b.addExecutable(.{
        .name = "test262-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/test262_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "jsz", .module = mod } },
        }),
    });
    const run_conformance = b.addRunArtifact(conformance_exe);
    const conformance_step = b.step("conformance", "Run Test262 conformance suite");
    conformance_step.dependOn(&run_conformance.step);

    // ---------------------------------------------------------------------------
    // Differential: zig build differential
    // ---------------------------------------------------------------------------
    const diff_exe = b.addExecutable(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/differential.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "jsz", .module = mod } },
        }),
    });
    const run_diff = b.addRunArtifact(diff_exe);
    const diff_step = b.step("differential", "Run Node.js differential harness");
    diff_step.dependOn(&run_diff.step);

    // ---------------------------------------------------------------------------
    // Example: zig build example-hello
    // ---------------------------------------------------------------------------
    const hello_exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "jsz", .module = mod } },
        }),
    });
    const run_hello = b.addRunArtifact(hello_exe);
    const hello_step = b.step("example-hello", "Build and run examples/hello.zig");
    hello_step.dependOn(&run_hello.step);

    // ---------------------------------------------------------------------------
    // Docs: zig build docs  (autodoc via -femit-docs on the module test artifact)
    // ---------------------------------------------------------------------------
    const docs_mod_test = b.addTest(.{ .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_mod_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API docs into zig-out/docs/");
    docs_step.dependOn(&install_docs.step);

    // ---------------------------------------------------------------------------
    // Bench: zig build bench
    // ---------------------------------------------------------------------------
    const bench_exe = b.addExecutable(.{
        .name = "bench-fib20",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/fib20.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{ .{ .name = "jsz", .module = mod } },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ---------------------------------------------------------------------------
    // GC stress: zig build gc-stress
    // ---------------------------------------------------------------------------
    const gc_stress_exe = b.addExecutable(.{
        .name = "gc-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gc_stress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "jsz", .module = mod } },
        }),
    });
    b.installArtifact(gc_stress_exe);
    const run_gc_stress = b.addRunArtifact(gc_stress_exe);
    const gc_stress_step = b.step("gc-stress", "Run Phase 3b GC stress test");
    gc_stress_step.dependOn(&run_gc_stress.step);
}
