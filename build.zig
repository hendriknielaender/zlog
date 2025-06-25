const std = @import("std");
const log = std.log.scoped(.zlog_build);

const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Setup dependencies (always needed)
    const deps = setupDependencies(b, target, optimize);

    // Setup library and module (always needed as base)
    const lib_step = setupLibrary(b, target, optimize, deps);

    // Setup other components only when requested
    setupTesting(b, target, optimize, deps);
    setupBenchmarks(b, target, optimize, deps);
    setupDocumentation(b, lib_step.lib);
}

const Dependencies = struct {
    zbench_module: *std.Build.Module,
    libxev_module: *std.Build.Module,
};

fn setupDependencies(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Dependencies {
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

    return .{
        .zbench_module = zbench_module,
        .libxev_module = libxev_module,
    };
}

const LibraryStep = struct {
    lib: *std.Build.Step.Compile,
    module: *std.Build.Module,
};

fn setupLibrary(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Dependencies) LibraryStep {
    // Module for the main library
    const zlog_module = b.addModule("zlog", .{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });
    zlog_module.addImport("xev", deps.libxev_module);

    // Static library
    const lib = b.addStaticLibrary(.{
        .name = "zlog",
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
        .version = version,
    });
    lib.root_module.addImport("xev", deps.libxev_module);
    b.installArtifact(lib);

    return .{
        .lib = lib,
        .module = zlog_module,
    };
}

fn setupTesting(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Dependencies) void {
    const test_step = b.step("test", "Run unit tests");

    // Unit tests (built into the source file)
    const unit_tests = b.addTest(.{
        .name = "zlog_tests",
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("xev", deps.libxev_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}

fn setupBenchmarks(b: *std.Build, target: std.Build.ResolvedTarget, _: std.builtin.OptimizeMode, deps: Dependencies) void {
    const benchmark_step = b.step("benchmarks", "Run all performance benchmarks");

    const benchmark_names = [_][]const u8{
        "async",
        "comprehensive",
        "isolated",
        "memory",
        "production",
        "redaction",
    };

    // Create module for benchmarks to import
    const zlog_benchmark_module = b.addModule("zlog", .{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    zlog_benchmark_module.addImport("xev", deps.libxev_module);

    for (benchmark_names) |benchmark_name| {
        const benchmark_exe = b.addExecutable(.{
            .name = b.fmt("benchmark_{s}", .{benchmark_name}),
            .root_source_file = b.path(b.fmt("benchmarks/{s}.zig", .{benchmark_name})),
            .target = target,
            .optimize = .ReleaseFast,
        });

        benchmark_exe.root_module.addImport("zbench", deps.zbench_module);
        benchmark_exe.root_module.addImport("zlog", zlog_benchmark_module);
        benchmark_exe.root_module.addImport("xev", deps.libxev_module);

        const run_benchmark = b.addRunArtifact(benchmark_exe);

        // Individual benchmark steps
        const individual_step = b.step(b.fmt("benchmark-{s}", .{benchmark_name}), b.fmt("Run {s} benchmark", .{benchmark_name}));
        individual_step.dependOn(&run_benchmark.step);

        benchmark_step.dependOn(&run_benchmark.step);
    }
}

fn setupDocumentation(b: *std.Build, lib: *std.Build.Step.Compile) void {
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate and install documentation");
    docs_step.dependOn(&install_docs.step);

    // log.info("Documentation setup complete", .{});
}

