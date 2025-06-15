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

    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const libxev_module = libxev_dep.module("xev");

    // Module for the main library.
    const zlog_module = b.addModule("zlog", .{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });
    zlog_module.addImport("xev", libxev_module);

    // Static library.
    const lib = b.addStaticLibrary(.{
        .name = "zlog",
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("xev", libxev_module);
    b.installArtifact(lib);

    // Unit tests (built into the source file).
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("xev", libxev_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Test step.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Async performance benchmark.
    const async_bench = b.addExecutable(.{
        .name = "async",
        .root_source_file = b.path("benchmarks/async.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    async_bench.root_module.addImport("zlog", zlog_module);
    async_bench.root_module.addImport("xev", libxev_module);

    const run_async = b.addRunArtifact(async_bench);

    // Memory allocation benchmark.
    const memory = b.addExecutable(.{
        .name = "memory",
        .root_source_file = b.path("benchmarks/memory.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    memory.root_module.addImport("zbench", zbench_module);
    memory.root_module.addImport("zlog", zlog_module);

    const run_memory = b.addRunArtifact(memory);

    // Isolated performance analysis.
    const isolated = b.addExecutable(.{
        .name = "isolated",
        .root_source_file = b.path("benchmarks/isolated.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    isolated.root_module.addImport("zlog", zlog_module);

    const run_isolated = b.addRunArtifact(isolated);

    // Production benchmark.
    const production = b.addExecutable(.{
        .name = "production",
        .root_source_file = b.path("benchmarks/production.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    production.root_module.addImport("zlog", zlog_module);
    production.root_module.addImport("xev", libxev_module);

    const run_production = b.addRunArtifact(production);

    // Comprehensive benchmark.
    const comprehensive = b.addExecutable(.{
        .name = "comprehensive",
        .root_source_file = b.path("benchmarks/comprehensive.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    comprehensive.root_module.addImport("zbench", zbench_module);
    comprehensive.root_module.addImport("zlog", zlog_module);

    const run_comprehensive = b.addRunArtifact(comprehensive);

    // Consolidated benchmark step.
    const benchmarks_step = b.step("benchmarks", "Run all performance benchmarks");
    benchmarks_step.dependOn(&run_async.step);
    benchmarks_step.dependOn(&run_memory.step);
    benchmarks_step.dependOn(&run_isolated.step);
    benchmarks_step.dependOn(&run_production.step);
    benchmarks_step.dependOn(&run_comprehensive.step);
}