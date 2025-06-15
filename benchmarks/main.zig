const std = @import("std");
const zbench = @import("zbench");
const zlog = @import("zlog");

// Null writer for benchmarking formatting performance without I/O overhead.
const NullWriter = struct {
    const Self = @This();
    const Error = error{};
    const Writer = std.io.Writer(*Self, Error, write);

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    fn write(self: *Self, bytes: []const u8) Error!usize {
        _ = self;
        return bytes.len;
    }
};

// Benchmark configurations.
const BenchConfig = struct {
    name: []const u8,
    iterations: u32 = 10000,
};

const bench_configs = [_]BenchConfig{
    .{ .name = "simple_message", .iterations = 100000 },
    .{ .name = "with_fields", .iterations = 50000 },
    .{ .name = "many_fields", .iterations = 25000 },
    .{ .name = "string_escaping", .iterations = 25000 },
    .{ .name = "disabled_level", .iterations = 100000 },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    // zlog benchmarks
    try bench.add("zlog_simple_message", benchZlogSimpleMessage, .{});
    try bench.add("zlog_with_fields", benchZlogWithFields, .{});
    try bench.add("zlog_many_fields", benchZlogManyFields, .{});
    try bench.add("zlog_string_escaping", benchZlogStringEscaping, .{});
    try bench.add("zlog_disabled_level", benchZlogDisabledLevel, .{});
    try bench.add("zlog_level_filtering", benchZlogLevelFiltering, .{});

    // Note: Memory allocation benchmarks moved to dedicated `zig build memory` command

    // Concurrent logging benchmarks
    try bench.add("zlog_concurrent", benchZlogConcurrent, .{});

    try bench.run(std.io.getStdOut().writer());
}

// zlog benchmarks.

fn benchZlogSimpleMessage(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < bench_configs[0].iterations) : (i += 1) {
        logger.info("User logged in successfully", &.{});
    }
}

fn benchZlogWithFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < bench_configs[1].iterations) : (i += 1) {
        logger.info("User action", &.{
            zlog.field.string("user_id", "12345"),
            zlog.field.string("action", "login"),
            zlog.field.int("timestamp", 1634567890),
        });
    }
}

fn benchZlogManyFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < bench_configs[2].iterations) : (i += 1) {
        logger.info("Complex operation", &.{
            zlog.field.string("service", "auth"),
            zlog.field.string("method", "POST"),
            zlog.field.string("path", "/api/v1/login"),
            zlog.field.int("status_code", 200),
            zlog.field.float("duration_ms", 45.67),
            zlog.field.string("user_agent", "Mozilla/5.0"),
            zlog.field.string("ip", "192.168.1.1"),
            zlog.field.uint("content_length", 1024),
            zlog.field.boolean("cached", false),
            zlog.field.string("trace_id", "abc123def456"),
        });
    }
}

fn benchZlogStringEscaping(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < bench_configs[3].iterations) : (i += 1) {
        logger.info("Message with \"quotes\" and \nspecial\tchars", &.{
            zlog.field.string("data", "Line1\nLine2\tTabbed\"Quoted\"\\Backslash"),
            zlog.field.string("json", "{\"key\": \"value with \\\"quotes\\\"\"}"),
        });
    }
}

fn benchZlogDisabledLevel(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{ .level = .err }).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < bench_configs[4].iterations) : (i += 1) {
        // These should be filtered out at runtime.
        logger.debug("Debug message that should not be logged", &.{
            zlog.field.string("expensive_computation", "result"),
        });
    }
}

fn benchZlogLevelFiltering(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{ .level = .warn }).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < 50000) : (i += 1) {
        // Mix of levels - some filtered, some not.
        logger.trace("Trace", &.{});
        logger.debug("Debug", &.{});
        logger.info("Info", &.{});
        logger.warn("Warning", &.{});
        logger.err("Error", &.{});
    }
}

// Concurrent logging benchmarks.

fn benchZlogConcurrent(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    const thread_count = 4;
    const iterations_per_thread = 2500;

    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]ConcurrentContext = undefined;

    for (&contexts, 0..) |*ctx, i| {
        ctx.* = ConcurrentContext{
            .logger = &logger,
            .iterations = iterations_per_thread,
            .thread_id = i,
        };
    }

    // Start threads.
    for (&threads, &contexts) |*thread, *ctx| {
        thread.* = std.Thread.spawn(.{}, zlogConcurrentWorker, .{ctx}) catch unreachable;
    }

    // Wait for completion.
    for (&threads) |*thread| {
        thread.join();
    }
}

// Helper structures and functions for concurrent benchmarks.

const ConcurrentContext = struct {
    logger: *zlog.Logger(.{}),
    iterations: u32,
    thread_id: usize,
};

fn zlogConcurrentWorker(ctx: *ConcurrentContext) void {
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        ctx.logger.info("Concurrent message", &.{
            zlog.field.uint("thread_id", ctx.thread_id),
            zlog.field.uint("iteration", i),
            zlog.field.string("worker", "zlog"),
        });
    }
}
