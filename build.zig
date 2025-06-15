const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies.
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });
    const zbench_module = zbench_dep.module("zbench");

    // Module for the main library.
    const zlog_module = b.addModule("zlog", .{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library.
    const lib = b.addStaticLibrary(.{
        .name = "zlog",
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Unit tests (built into the source file).
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Benchmarks.
    const benchmarks = b.addExecutable(.{
        .name = "benchmarks",
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    benchmarks.root_module.addImport("zbench", zbench_module);
    benchmarks.root_module.addImport("zlog", zlog_module);

    const run_benchmarks = b.addRunArtifact(benchmarks);

    // Test step.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Comparison benchmarks.
    const comparison = b.addExecutable(.{
        .name = "comparison",
        .root_source_file = b.path("benchmarks/comparison.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    comparison.root_module.addImport("zbench", zbench_module);
    comparison.root_module.addImport("zlog", zlog_module);

    const run_comparison = b.addRunArtifact(comparison);

    // Benchmark step.
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_benchmarks.step);

    // Isolated performance analysis.
    const isolated = b.addExecutable(.{
        .name = "isolated",
        .root_source_file = b.path("benchmarks/isolated.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    isolated.root_module.addImport("zlog", zlog_module);

    const run_isolated = b.addRunArtifact(isolated);

    // Comparison step.
    const compare_step = b.step("compare", "Run comparison benchmarks");
    compare_step.dependOn(&run_comparison.step);

    // Memory allocation benchmarks.
    const memory = b.addExecutable(.{
        .name = "memory",
        .root_source_file = b.path("benchmarks/memory.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    memory.root_module.addImport("zbench", zbench_module);
    memory.root_module.addImport("zlog", zlog_module);

    const run_memory = b.addRunArtifact(memory);

    // Isolated step.
    const isolated_step = b.step("isolated", "Run isolated performance analysis");
    isolated_step.dependOn(&run_isolated.step);

    // Memory step.
    const memory_step = b.step("memory", "Run memory allocation benchmarks");
    memory_step.dependOn(&run_memory.step);
}