// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Phase 9: -Djit=true links the Cranelift native backend (jit-native/ cdylib)
    // into the CLI so the experimental hot-loop JIT runs natively. Default off, so
    // normal builds/tests/CI need no cargo/Rust toolchain.
    const enable_jit = b.option(bool, "jit", "Link the Cranelift native JIT backend into the CLI (requires cargo)") orelse false;
    const jit_options = b.addOptions();
    jit_options.addOption(bool, "jit_enabled", enable_jit);

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
    exe.root_module.addImport("build_options", jit_options.createModule());
    b.installArtifact(exe);

    // zig build run -- [args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the jsz CLI");
    run_step.dependOn(&run_cmd.step);

    // Phase 9: when -Djit=true, build the Rust cdylib and link it into the CLI so
    // the experimental hot-loop JIT uses Cranelift-compiled native code. The DLL
    // is placed beside the installed binary and on PATH for `zig build run`.
    if (enable_jit) {
        const cargo_build_jit = b.addSystemCommand(&.{
            "cargo", "build", "--release", "--manifest-path", "jit-native/Cargo.toml",
        });
        exe.step.dependOn(&cargo_build_jit.step);
        exe.addLibraryPath(b.path("jit-native/target/release"));
        exe.linkSystemLibrary("jit_native.dll"); // MSVC appends .lib -> jit_native.dll.lib
        exe.linkLibC();
        run_cmd.addPathDir(b.pathFromRoot("jit-native/target/release"));
        const install_dll = b.addInstallBinFile(
            b.path("jit-native/target/release/jit_native.dll"),
            "jit_native.dll",
        );
        b.getInstallStep().dependOn(&install_dll.step);
    }

    // ---------------------------------------------------------------------------
    // Tests: zig build test
    // ---------------------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    // exe.root_module pulls native.zig under -Djit=true (via main.zig); link the
    // cdylib + DLL path so `zig build test -Djit=true` also builds/runs cleanly.
    if (enable_jit) {
        exe_tests.addLibraryPath(b.path("jit-native/target/release"));
        exe_tests.linkSystemLibrary("jit_native.dll");
        exe_tests.linkLibC();
        run_exe_tests.addPathDir(b.pathFromRoot("jit-native/target/release"));
    }

    const test262_runner_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/test/test262_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsz", .module = mod }},
    });
    const test262_runner_tests = b.addTest(.{ .root_module = test262_runner_tests_mod });
    const run_test262_runner_tests = b.addRunArtifact(test262_runner_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_test262_runner_tests.step);

    // ---------------------------------------------------------------------------
    // Fuzz: zig build fuzz --fuzz
    // ---------------------------------------------------------------------------
    const parser_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/test/fuzz/parser_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsz", .module = mod }},
    });
    const parser_fuzz = b.addTest(.{ .root_module = parser_fuzz_mod });
    const run_parser_fuzz = b.addRunArtifact(parser_fuzz);

    const vm_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/test/fuzz/vm_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsz", .module = mod }},
    });
    const vm_fuzz = b.addTest(.{ .root_module = vm_fuzz_mod });
    const run_vm_fuzz = b.addRunArtifact(vm_fuzz);

    // Regex fuzzer drives the matcher directly via jsz._regex (the internal engine).
    const regex_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/test/fuzz/regex_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsz", .module = mod }},
    });
    const regex_fuzz = b.addTest(.{ .root_module = regex_fuzz_mod });
    const run_regex_fuzz = b.addRunArtifact(regex_fuzz);

    const json_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/test/fuzz/json_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsz", .module = mod }},
    });
    const json_fuzz = b.addTest(.{ .root_module = json_fuzz_mod });
    const run_json_fuzz = b.addRunArtifact(json_fuzz);

    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (add --fuzz for fuzzing mode)");
    fuzz_step.dependOn(&run_parser_fuzz.step);
    fuzz_step.dependOn(&run_vm_fuzz.step);
    fuzz_step.dependOn(&run_regex_fuzz.step);
    fuzz_step.dependOn(&run_json_fuzz.step);

    // ---------------------------------------------------------------------------
    // Conformance: zig build conformance
    // ---------------------------------------------------------------------------
    const conformance_exe = b.addExecutable(.{
        .name = "test262-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/test262_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "jsz", .module = mod }},
        }),
    });
    const run_conformance = b.addRunArtifact(conformance_exe);
    const conformance_step = b.step("conformance", "Run Test262 conformance suite");
    conformance_step.dependOn(&run_conformance.step);

    const run_conformance_summary = b.addRunArtifact(conformance_exe);
    run_conformance_summary.addArg("--summary");
    const conformance_summary_step = b.step("conformance-summary", "Run Test262 with category summary");
    conformance_summary_step.dependOn(&run_conformance_summary.step);

    const run_conformance_delta = b.addRunArtifact(conformance_exe);
    run_conformance_delta.addArg("--summary");
    run_conformance_delta.addArg("--fail-on-flips");
    const conformance_delta_step = b.step("conformance-delta", "Fail on unexpected pass/fail flips using known-failing list");
    conformance_delta_step.dependOn(&run_conformance_delta.step);

    const run_conformance_dashboard = b.addRunArtifact(conformance_exe);
    run_conformance_dashboard.addArg("--summary");
    run_conformance_dashboard.addArg("--dashboard");
    run_conformance_dashboard.addArg("docs/CONFORMANCE_DASHBOARD.md");
    const conformance_dashboard_step = b.step("conformance-dashboard", "Generate docs/CONFORMANCE_DASHBOARD.md from Test262 results");
    conformance_dashboard_step.dependOn(&run_conformance_dashboard.step);

    // Full corpus: walk all of external/test262/test, load real harness includes,
    // report the true (un-whitelisted) per-category baseline + dashboard.
    const run_conformance_full = b.addRunArtifact(conformance_exe);
    run_conformance_full.addArg("--full");
    run_conformance_full.addArg("--dashboard");
    run_conformance_full.addArg("docs/CONFORMANCE_FULL.md");
    const conformance_full_step = b.step("conformance-full", "Run the entire Test262 corpus and report the true baseline");
    conformance_full_step.dependOn(&run_conformance_full.step);

    // Full-corpus CI gate: fail on any flip vs tests/test262_known_failing_full.txt.
    const run_conformance_full_delta = b.addRunArtifact(conformance_exe);
    run_conformance_full_delta.addArg("--full");
    run_conformance_full_delta.addArg("--fail-on-flips");
    const conformance_full_delta_step = b.step("conformance-full-delta", "Fail on full-corpus pass/fail flips vs the full known-failing list");
    conformance_full_delta_step.dependOn(&run_conformance_full_delta.step);

    // Seed/refresh the full known-failing list from the current baseline.
    const run_conformance_full_seed = b.addRunArtifact(conformance_exe);
    run_conformance_full_seed.addArg("--full");
    run_conformance_full_seed.addArg("--write-known-failing");
    run_conformance_full_seed.addArg("tests/test262_known_failing_full.txt");
    const conformance_full_seed_step = b.step("conformance-full-seed", "Write tests/test262_known_failing_full.txt from the current full-corpus results");
    conformance_full_seed_step.dependOn(&run_conformance_full_seed.step);

    // Seed/refresh the whitelist known-failing list from the current baseline.
    const run_conformance_seed = b.addRunArtifact(conformance_exe);
    run_conformance_seed.addArg("--summary");
    run_conformance_seed.addArg("--write-known-failing");
    run_conformance_seed.addArg("tests/test262_known_failing.txt");
    const conformance_seed_step = b.step("conformance-seed", "Write tests/test262_known_failing.txt from the current whitelist results");
    conformance_seed_step.dependOn(&run_conformance_seed.step);

    // ---------------------------------------------------------------------------
    // Differential: zig build differential
    // ---------------------------------------------------------------------------
    const diff_exe = b.addExecutable(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/differential.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "jsz", .module = mod }},
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
            .imports = &.{.{ .name = "jsz", .module = mod }},
        }),
    });
    const run_hello = b.addRunArtifact(hello_exe);
    const hello_step = b.step("example-hello", "Build and run examples/hello.zig");
    hello_step.dependOn(&run_hello.step);

    // ---------------------------------------------------------------------------
    // Example: zig build example-embed  (W6 embedding API demo)
    // ---------------------------------------------------------------------------
    const embed_exe = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embed.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "jsz", .module = mod }},
        }),
    });
    b.installArtifact(embed_exe);
    const run_embed = b.addRunArtifact(embed_exe);
    const embed_step = b.step("example-embed", "Build and run examples/embed.zig (W6 embedding API demo)");
    embed_step.dependOn(&run_embed.step);

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
            .imports = &.{.{ .name = "jsz", .module = mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    const bench_phase6_exe = b.addExecutable(.{
        .name = "bench-phase6-ic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/phase6_ic.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "jsz", .module = mod }},
        }),
    });
    const run_bench_phase6 = b.addRunArtifact(bench_phase6_exe);
    const bench_phase6_step = b.step("bench-phase6", "Run Phase 6 shape/IC benchmarks");
    bench_phase6_step.dependOn(&run_bench_phase6.step);
    bench_step.dependOn(&run_bench_phase6.step);

    // ---------------------------------------------------------------------------
    // GC stress: zig build gc-stress
    // ---------------------------------------------------------------------------
    const gc_stress_exe = b.addExecutable(.{
        .name = "gc-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gc_stress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "jsz", .module = mod }},
        }),
    });
    b.installArtifact(gc_stress_exe);
    const run_gc_stress = b.addRunArtifact(gc_stress_exe);
    const gc_stress_step = b.step("gc-stress", "Run Phase 3b GC stress test");
    gc_stress_step.dependOn(&run_gc_stress.step);

    // ---------------------------------------------------------------------------
    // Phase 9 JIT scaffold: zig build jit  (not linked to main binary yet)
    // ---------------------------------------------------------------------------
    const jit_mod = b.createModule(.{
        .root_source_file = b.path("src/jit/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const jit_tests = b.addTest(.{ .root_module = jit_mod });
    const run_jit_tests = b.addRunArtifact(jit_tests);
    const jit_step = b.step("jit", "Run Phase 9 JIT module tests (scaffold; not linked to jsz CLI)");
    jit_step.dependOn(&run_jit_tests.step);

    // ---------------------------------------------------------------------------
    // Phase 9 native JIT backend (Cranelift via Rust cdylib): zig build jit-native
    //   Builds jit-native/ (cargo), links its import lib, runs the FFI tests.
    //   Not linked into the main jsz CLI yet.
    // ---------------------------------------------------------------------------
    const cargo_build = b.addSystemCommand(&.{
        "cargo", "build", "--release", "--manifest-path", "jit-native/Cargo.toml",
    });
    const native_mod = b.createModule(.{
        .root_source_file = b.path("src/jit/native.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_tests = b.addTest(.{ .root_module = native_mod });
    native_tests.step.dependOn(&cargo_build.step);
    native_tests.addLibraryPath(b.path("jit-native/target/release"));
    // Import lib is `jit_native.dll.lib`; the MSVC linker appends `.lib` to the name.
    native_tests.linkSystemLibrary("jit_native.dll");
    native_tests.linkLibC();
    const run_native_tests = b.addRunArtifact(native_tests);
    // Make jit_native.dll resolvable at test runtime.
    run_native_tests.addPathDir(b.pathFromRoot("jit-native/target/release"));
    const jit_native_step = b.step("jit-native", "Build the Cranelift native backend (Rust cdylib) and run its FFI tests");
    jit_native_step.dependOn(&run_native_tests.step);
}
