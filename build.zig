const std = @import("std");

const version = std.SemanticVersion{ .major = 0, .minor = 3, .patch = 0 };

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
    setupExamples(b, target, optimize, deps);
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
    const lib = b.addLibrary(.{
        .name = "zlog",
        .root_module = zlog_module,
        .version = version,
        .linkage = .static,
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
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zlog.zig"),
            .target = target,
            .optimize = optimize,
        }),
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
        "ergonomic_otel",
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
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("benchmarks/{s}.zig", .{benchmark_name})),
                .target = target,
                .optimize = .ReleaseFast,
            }),
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

fn setupExamples(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deps: Dependencies) void {
    const examples_step = b.step("examples", "Run all examples");

    // Create module for examples to import
    const zlog_example_module = b.addModule("zlog", .{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });
    zlog_example_module.addImport("xev", deps.libxev_module);

    // OTel example
    const otel_example = b.addExecutable(.{
        .name = "otel_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/otel_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    otel_example.root_module.addImport("zlog", zlog_example_module);
    otel_example.root_module.addImport("xev", deps.libxev_module);

    const run_otel_example = b.addRunArtifact(otel_example);
    const otel_step = b.step("example-otel", "Run OpenTelemetry example");
    otel_step.dependOn(&run_otel_example.step);
    examples_step.dependOn(&run_otel_example.step);
}

fn setupDocumentation(b: *std.Build, lib: *std.Build.Step.Compile) void {
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate and install documentation");
    docs_step.dependOn(&install_docs.step);
}
