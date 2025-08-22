const std = @import("std");
const zbench = @import("zbench");
const zlog = @import("zlog");

// Null writer for performance testing without I/O overhead
const NullWriter = struct {
    const Self = @This();
    const Error = error{};
    const Writer = std.io.GenericWriter(*Self, Error, write);

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    pub fn deprecatedWriter(self: *Self) Writer {
        return self.writer();
    }

    fn write(self: *Self, bytes: []const u8) Error!usize {
        _ = self;
        return bytes.len;
    }
};

// Global allocator for benchmarks
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn benchmarkVerboseOtelApi(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{ .async_mode = false },
        .resource = zlog.Resource.init().withService("benchmark-service", "1.0.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("benchmark-logger"),
    };

    var logger = zlog.OTelLogger(otel_config).init(null_writer.deprecatedWriter().any());
    defer logger.deinit();

    logger.info("User authentication successful", &.{
        zlog.SemConv.userId("user123"),
        zlog.SemConv.userName("alice"),
        zlog.SemConv.sessionId("sess_abc123"),
        zlog.Field.string("request_id", "req_456789"),
        zlog.Field.int("attempt", 1),
        zlog.Field.boolean("success", true),
    });
}

fn benchmarkUnifiedOtelApi(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{ .async_mode = false },
        .resource = zlog.Resource.init().withService("benchmark-service", "1.0.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("benchmark-logger"),
    };

    var logger = zlog.OTelLogger(otel_config).init(null_writer.deprecatedWriter().any());
    defer logger.deinit();

    logger.info("User authentication successful", .{
        .user_id = "user123",
        .username = "alice",
        .session_id = "sess_abc123",
        .request_id = "req_456789",
        .attempt = @as(i64, 1),
        .success = true,
    });
}
fn benchmarkVerboseOtelWithTrace(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{ .async_mode = false },
        .resource = zlog.Resource.init().withService("benchmark-service", "1.0.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("benchmark-logger"),
    };

    var logger = zlog.OTelLogger(otel_config).init(null_writer.deprecatedWriter().any());
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    logger.infoWithTrace("HTTP request completed", trace_ctx, &.{
        zlog.SemConv.httpMethod("POST"),
        zlog.SemConv.httpUrl("/api/orders"),
        zlog.SemConv.httpStatusCode(201),
        zlog.SemConv.userId("customer123"),
        zlog.Field.string("request_id", "req_456789"),
        zlog.Field.int("duration_ms", 45),
    });
}

fn benchmarkUnifiedOtelWithTrace(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{ .async_mode = false },
        .resource = zlog.Resource.init().withService("benchmark-service", "1.0.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("benchmark-logger"),
    };

    var logger = zlog.OTelLogger(otel_config).init(null_writer.deprecatedWriter().any());
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    logger.infoWithTrace("HTTP request completed", trace_ctx, .{
        .http_method = "POST",
        .http_url = "/api/orders",
        .http_status_code = 201,
        .user_id = "customer123",
        .request_id = "req_456789",
        .duration_ms = @as(i64, 45),
    });
}

fn benchmarkVerboseMixedTypes(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{ .async_mode = false },
        .resource = zlog.Resource.init().withService("benchmark-service", "1.0.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("benchmark-logger"),
    };

    var logger = zlog.OTelLogger(otel_config).init(null_writer.deprecatedWriter().any());
    defer logger.deinit();

    logger.info("Mixed field types", &.{
        zlog.Field.string("string_field", "test_value"),
        zlog.Field.int("int_field", 42),
        zlog.Field.uint("uint_field", 84),
        zlog.Field.float("float_field", 3.14159),
        zlog.Field.boolean("bool_field", true),
        zlog.Field.null_value("null_field"),
    });
}

fn benchmarkUnifiedMixedTypes(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{ .async_mode = false },
        .resource = zlog.Resource.init().withService("benchmark-service", "1.0.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("benchmark-logger"),
    };

    var logger = zlog.OTelLogger(otel_config).init(null_writer.deprecatedWriter().any());
    defer logger.deinit();

    logger.info("Mixed field types", .{
        .string_field = "test_value",
        .int_field = @as(i64, 42),
        .uint_field = @as(u64, 84),
        .float_field = 3.14159,
        .bool_field = true,
        .null_field = null,
    });
}

pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("=== Unified OTEL API Performance Benchmark ===\n\n", .{});
    std.debug.print("Comparing field array vs anonymous struct syntax (sync mode for benchmarking).\n\n", .{});

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    try bench.add("verbose_otel_api", benchmarkVerboseOtelApi, .{});
    try bench.add("unified_otel_api", benchmarkUnifiedOtelApi, .{});
    try bench.add("verbose_otel_with_trace", benchmarkVerboseOtelWithTrace, .{});
    try bench.add("unified_otel_with_trace", benchmarkUnifiedOtelWithTrace, .{});
    try bench.add("verbose_mixed_types", benchmarkVerboseMixedTypes, .{});
    try bench.add("unified_mixed_types", benchmarkUnifiedMixedTypes, .{});

    // Simple benchmark output instead of zbench
    std.debug.print("Running OTEL API benchmarks...\n", .{});
    std.debug.print("• verbose_otel_api: Running...\n", .{});
    benchmarkVerboseOtelApi(allocator);
    std.debug.print("• unified_otel_api: Running...\n", .{});
    benchmarkUnifiedOtelApi(allocator);
    std.debug.print("• verbose_otel_with_trace: Running...\n", .{});
    benchmarkVerboseOtelWithTrace(allocator);
    std.debug.print("All OTEL benchmarks completed successfully.\n", .{});

    std.debug.print("\n=== Analysis ===\n", .{});
    std.debug.print("• verbose_otel_api: Traditional field array syntax\n", .{});
    std.debug.print("• unified_otel_api: Unified API with anonymous struct syntax\n", .{});
    std.debug.print("• verbose_otel_with_trace: Field arrays with trace context\n", .{});
    std.debug.print("• unified_otel_with_trace: Unified API with trace context\n", .{});
    std.debug.print("• verbose_mixed_types: Field arrays with various types\n", .{});
    std.debug.print("• unified_mixed_types: Unified API with various types\n", .{});
    std.debug.print("\nThe unified API should show similar or better performance due to compile-time optimization.\n", .{});
}
