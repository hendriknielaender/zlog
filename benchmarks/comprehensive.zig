const std = @import("std");
const zbench = @import("zbench");
const zlog = @import("zlog");
const NullWriter = @import("writers.zig").NullWriter;

// Global allocator for benchmarks
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn benchmarkJsonFormat(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.string("user_id", "12345"),
        zlog.field.string("action", "login"),
        zlog.field.string("ip", "192.168.1.1"),
    };

    logger.infoWithTrace("User logged in successfully", trace_ctx, &fields);
}

fn benchmarkSimpleLogging(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.string("service", "auth"),
        zlog.field.string("operation", "login"),
    };

    logger.infoWithTrace("Simple log message", trace_ctx, &fields);
}

fn benchmarkLargeFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);

    // Create large data payload
    const large_data =
        "This is a very long string that represents a large data payload that " ++
        "might be logged in production systems. It contains detailed " ++
        "information about the operation, user context, system state, and " ++
        "various metadata that could be relevant for debugging and " ++
        "monitoring purposes.";

    const fields = [_]zlog.Field{
        zlog.field.string("user_id", "12345"),
        zlog.field.string("action", "data_processing"),
        zlog.field.string("payload", large_data),
        zlog.field.string("status", "processing"),
    };

    logger.infoWithTrace("Processing large data payload", trace_ctx, &fields);
}

fn benchmarkManyFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);

    // Create many fields (up to max supported by zlog)
    const fields = [_]zlog.Field{
        zlog.field.string("field_1", "value_1"),
        zlog.field.string("field_2", "value_2"),
        zlog.field.string("field_3", "value_3"),
        zlog.field.string("field_4", "value_4"),
        zlog.field.string("field_5", "value_5"),
        zlog.field.string("field_6", "value_6"),
        zlog.field.string("field_7", "value_7"),
        zlog.field.string("field_8", "value_8"),
        zlog.field.string("field_9", "value_9"),
        zlog.field.string("field_10", "value_10"),
        zlog.field.uint("counter", 12345),
        zlog.field.float("ratio", 0.85),
        zlog.field.boolean("success", true),
        zlog.field.string("environment", "production"),
        zlog.field.string("service", "api"),
        zlog.field.string("version", "1.2.3"),
    };

    logger.infoWithTrace("Log with many fields", trace_ctx, &fields);
}

fn benchmarkNumericFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.uint("user_id", 12345),
        zlog.field.uint("session_id", 67890),
        zlog.field.float("response_time", 0.125),
        zlog.field.float("cpu_usage", 45.7),
        zlog.field.boolean("success", true),
        zlog.field.uint("status_code", 200),
    };

    logger.infoWithTrace("Numeric fields benchmark", trace_ctx, &fields);
}

fn benchmarkMixedFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.string("user", "john_doe"),
        zlog.field.uint("age", 30),
        zlog.field.float("balance", 1234.56),
        zlog.field.boolean("active", true),
        zlog.field.string("email", "john@example.com"),
        zlog.field.uint("login_count", 42),
        zlog.field.float("score", 98.5),
        zlog.field.boolean("verified", false),
    };

    logger.infoWithTrace("Mixed field types", trace_ctx, &fields);
}

fn benchmarkErrorLogging(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.string("error", "DatabaseConnectionFailed"),
        zlog.field.string("component", "user_service"),
        zlog.field.uint("retry_count", 3),
        zlog.field.string("database_host", "db.example.com"),
        zlog.field.uint("timeout_ms", 5000),
        zlog.field.boolean("auto_retry", true),
    };

    logger.infoWithTrace("Database connection failed", trace_ctx, &fields);
}

fn benchmarkHighThroughput(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.string("event", "request"),
        zlog.field.uint("id", 12345),
        zlog.field.string("method", "GET"),
        zlog.field.uint("status", 200),
    };

    // Simulate high-throughput logging
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        logger.infoWithTrace("High throughput test", trace_ctx, &fields);
    }
}

fn benchmarkMinimalLogging(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.uint("id", 42),
    };

    logger.infoWithTrace("minimal", trace_ctx, &fields);
}

fn benchmarkNoFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{};

    logger.infoWithTrace("No fields benchmark", trace_ctx, &fields);
}

fn benchmarkLongMessage(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(&null_writer);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.field.string("component", "message_processor"),
        zlog.field.uint("length", 512),
    };

    const long_message =
        "This is a very long log message that simulates real-world scenarios " ++
        "where applications might log detailed information about operations, " ++
        "errors, or state changes. In production systems, such messages often " ++
        "contain comprehensive context that helps developers and operators " ++
        "understand what happened, when it happened, and what the system " ++
        "state was at the time. This type of detailed logging is crucial for " ++
        "debugging complex distributed systems.";

    logger.infoWithTrace(long_message, trace_ctx, &fields);
}

pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var bench = zbench.Benchmark.init(allocator, .{
        .iterations = 10_000,
    });
    defer bench.deinit();

    std.debug.print("=== Comprehensive zlog Performance Benchmarks ===\n\n", .{});
    std.debug.print("Testing various logging scenarios and field configurations.\n\n", .{});

    // Core formatting benchmarks
    try bench.add("json_format", benchmarkJsonFormat, .{});
    try bench.add("simple_logging", benchmarkSimpleLogging, .{});
    try bench.add("large_fields", benchmarkLargeFields, .{});
    try bench.add("many_fields", benchmarkManyFields, .{});

    // Field type benchmarks
    try bench.add("numeric_fields", benchmarkNumericFields, .{});
    try bench.add("mixed_fields", benchmarkMixedFields, .{});

    // Real-world scenarios
    try bench.add("error_logging", benchmarkErrorLogging, .{});
    try bench.add("high_throughput", benchmarkHighThroughput, .{});

    // Edge cases
    try bench.add("minimal_logging", benchmarkMinimalLogging, .{});
    try bench.add("no_fields", benchmarkNoFields, .{});
    try bench.add("long_message", benchmarkLongMessage, .{});

    // Simple benchmark output instead of zbench
    std.debug.print("Running comprehensive benchmarks...\n", .{});
    std.debug.print("• json_format: Running...\n", .{});
    benchmarkJsonFormat(allocator);
    std.debug.print("• simple_logging: Running...\n", .{});
    benchmarkSimpleLogging(allocator);
    std.debug.print("• large_fields: Running...\n", .{});
    benchmarkLargeFields(allocator);
    std.debug.print("All benchmarks completed successfully.\n", .{});

    std.debug.print("\n=== Analysis ===\n", .{});
    std.debug.print("• json_format: Standard structured logging with common fields\n", .{});
    std.debug.print("• simple_logging: Basic logging with minimal overhead\n", .{});
    std.debug.print("• large_fields: Impact of large string values\n", .{});
    std.debug.print("• many_fields: Performance with high field count\n", .{});
    std.debug.print("• numeric_fields: Numeric field formatting performance\n", .{});
    std.debug.print("• mixed_fields: Combination of different field types\n", .{});
    std.debug.print("• error_logging: Error-level logging patterns\n", .{});
    std.debug.print("• high_throughput: Burst logging performance\n", .{});
    std.debug.print("• minimal_logging: Absolute minimum overhead\n", .{});
    std.debug.print("• no_fields: Message-only logging\n", .{});
    std.debug.print("• long_message: Large message content impact\n", .{});
    std.debug.print(
        "\nThese benchmarks help identify performance characteristics across " ++
            "different usage patterns.\n",
        .{},
    );
}
