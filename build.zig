const std = @import("std");

const version = std.SemanticVersion{ .major = 0, .minor = 3, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Setup library and module (always needed as base)
    const lib_step = setupLibrary(b, target, optimize);

    // Setup other components only when requested
    setupTesting(b, target, optimize);
    setupBenchmarks(b, target);
    setupExamples(b, target, optimize);
    setupDocumentation(b, lib_step.lib);
}

const LibraryStep = struct {
    lib: *std.Build.Step.Compile,
    module: *std.Build.Module,
};

fn setupLibrary(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) LibraryStep {
    // Module for the main library
    const zlog_module = b.addModule("zlog", .{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "zlog",
        .root_module = zlog_module,
        .version = version,
        .linkage = .static,
    });
    b.installArtifact(lib);

    return .{
        .lib = lib,
        .module = zlog_module,
    };
}

fn setupTesting(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
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

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}

fn setupBenchmarks(b: *std.Build, target: std.Build.ResolvedTarget) void {
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

    for (benchmark_names) |benchmark_name| {
        const benchmark_exe = b.addExecutable(.{
            .name = b.fmt("benchmark_{s}", .{benchmark_name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("benchmarks/{s}.zig", .{benchmark_name})),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });
        benchmark_exe.root_module.addImport("zlog", zlog_benchmark_module);

        const run_benchmark = b.addRunArtifact(benchmark_exe);

        // Individual benchmark steps
        const individual_step = b.step(b.fmt("benchmark-{s}", .{benchmark_name}), b.fmt("Run {s} benchmark", .{benchmark_name}));
        individual_step.dependOn(&run_benchmark.step);

        benchmark_step.dependOn(&run_benchmark.step);
    }
}

fn setupExamples(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const examples_step = b.step("examples", "Run all examples");

    // Create module for examples to import
    const zlog_example_module = b.addModule("zlog", .{
        .root_source_file = b.path("src/zlog.zig"),
        .target = target,
        .optimize = optimize,
    });

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
