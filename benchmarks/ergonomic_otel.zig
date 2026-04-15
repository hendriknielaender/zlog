const std = @import("std");
const zlog = @import("zlog");
const support = @import("support.zig");

const otel_config = zlog.OTelConfig{
    .base_config = .{ .async_mode = false },
    .resource = zlog.Resource.init().withService("benchmark-service", "1.0.0"),
    .instrumentation_scope = zlog.InstrumentationScope.init("benchmark-logger"),
};

pub fn main() !void {
    var sink_buffer: [512]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var logger = zlog.OTelLogger(otel_config).init(&sink.writer);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    const iterations = 80_000;

    std.debug.print("=== OTel API Ergonomics Benchmark ===\n\n", .{});

    printCase("field array", iterations, benchmarkFieldArray(&logger, iterations));
    printCase("anonymous struct", iterations, benchmarkStructSyntax(&logger, iterations));
    printCase("array + trace", iterations, benchmarkFieldArrayTrace(&logger, trace_ctx, iterations));
    printCase("struct + trace", iterations, benchmarkStructTrace(&logger, trace_ctx, iterations));

    std.debug.print("\nBytes written to sink: {d}\n", .{sink.fullCount()});
}

fn benchmarkFieldArray(logger: *zlog.OTelLogger(otel_config), iterations: usize) i128 {
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.info("user authentication successful", &.{
            zlog.SemConv.userId("user123"),
            zlog.SemConv.userName("alice"),
            zlog.SemConv.sessionId("sess_abc123"),
            zlog.Field.string("request_id", "req_456789"),
            zlog.Field.int("attempt", @as(i64, @intCast(i % 5))),
            zlog.Field.boolean("success", true),
        });
    }
    return support.nowNs() - start;
}

fn benchmarkStructSyntax(logger: *zlog.OTelLogger(otel_config), iterations: usize) i128 {
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.info("user authentication successful", .{
            .user_id = "user123",
            .username = "alice",
            .session_id = "sess_abc123",
            .request_id = "req_456789",
            .attempt = @as(i64, @intCast(i % 5)),
            .success = true,
        });
    }
    return support.nowNs() - start;
}

fn benchmarkFieldArrayTrace(
    logger: *zlog.OTelLogger(otel_config),
    trace_ctx: zlog.TraceContext,
    iterations: usize,
) i128 {
    const start = support.nowNs();
    for (0..iterations) |_| {
        logger.infoWithTrace("HTTP request completed", trace_ctx, &.{
            zlog.SemConv.httpMethod("POST"),
            zlog.SemConv.httpUrl("/api/orders"),
            zlog.SemConv.httpStatusCode(201),
            zlog.SemConv.userId("customer123"),
            zlog.Field.string("request_id", "req_456789"),
            zlog.Field.int("duration_ms", 45),
        });
    }
    return support.nowNs() - start;
}

fn benchmarkStructTrace(
    logger: *zlog.OTelLogger(otel_config),
    trace_ctx: zlog.TraceContext,
    iterations: usize,
) i128 {
    const start = support.nowNs();
    for (0..iterations) |_| {
        logger.infoWithTrace("HTTP request completed", trace_ctx, .{
            .http_method = "POST",
            .http_url = "/api/orders",
            .http_status_code = @as(i64, 201),
            .user_id = "customer123",
            .request_id = "req_456789",
            .duration_ms = @as(i64, 45),
        });
    }
    return support.nowNs() - start;
}

fn printCase(name: []const u8, iterations: usize, duration_ns: i128) void {
    std.debug.print(
        "{s:>16}: {d:>8.2} ms  ({d:>10.0} msg/s)\n",
        .{ name, support.nsToMs(duration_ns), support.perSecond(iterations, duration_ns) },
    );
}
