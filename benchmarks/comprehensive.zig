const std = @import("std");
const zlog = @import("zlog");
const support = @import("support.zig");

pub fn main() !void {
    var sink_buffer: [512]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var logger = zlog.Logger(.{}).init(&sink.writer);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    const iterations = 60_000;

    std.debug.print("=== Comprehensive Benchmark Sweep ===\n\n", .{});

    printCase("simple", iterations, benchSimple(&logger, trace_ctx, iterations));
    printCase("large payload", iterations, benchLargePayload(&logger, trace_ctx, iterations));
    printCase("many fields", iterations, benchManyFields(&logger, trace_ctx, iterations));
    printCase("numeric mix", iterations, benchNumeric(&logger, trace_ctx, iterations));
    printCase("span lifecycle", iterations, benchSpanLifecycle(&logger, iterations));
    printCase("long message", iterations, benchLongMessage(&logger, trace_ctx, iterations));

    std.debug.print("\nBytes written to sink: {d}\n", .{sink.fullCount()});
}

fn benchSimple(logger: *zlog.Logger(.{}), trace_ctx: zlog.TraceContext, iterations: usize) i128 {
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace("simple log message", trace_ctx, .{
            .service = "auth",
            .operation = "login",
            .iteration = @as(u64, @intCast(i)),
        });
    }
    return support.nowNs() - start;
}

fn benchLargePayload(logger: *zlog.Logger(.{}), trace_ctx: zlog.TraceContext, iterations: usize) i128 {
    const payload =
        "This is a large payload that models detailed production metadata, request context, and human-readable debugging information.";
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace("processing large payload", trace_ctx, .{
            .user_id = "12345",
            .payload = payload,
            .status = "processing",
            .iteration = @as(u64, @intCast(i)),
        });
    }
    return support.nowNs() - start;
}

fn benchManyFields(logger: *zlog.Logger(.{}), trace_ctx: zlog.TraceContext, iterations: usize) i128 {
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace("many fields", trace_ctx, .{
            .field_1 = "value_1",
            .field_2 = "value_2",
            .field_3 = "value_3",
            .field_4 = "value_4",
            .field_5 = "value_5",
            .field_6 = "value_6",
            .field_7 = "value_7",
            .field_8 = "value_8",
            .counter = @as(u64, @intCast(i)),
            .ratio = 0.85,
            .success = true,
            .environment = "production",
        });
    }
    return support.nowNs() - start;
}

fn benchNumeric(logger: *zlog.Logger(.{}), trace_ctx: zlog.TraceContext, iterations: usize) i128 {
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace("numeric fields", trace_ctx, .{
            .user_id = @as(u64, 12345) + @as(u64, @intCast(i % 1024)),
            .session_id = @as(u64, 67890) + @as(u64, @intCast(i % 2048)),
            .response_time = 0.125,
            .cpu_usage = 45.7,
            .success = true,
            .status_code = @as(u64, 200),
        });
    }
    return support.nowNs() - start;
}

fn benchSpanLifecycle(logger: *zlog.Logger(.{}), iterations: usize) i128 {
    const start = support.nowNs();
    for (0..iterations) |i| {
        const span = logger.spanStart("request", .{
            .request_id = @as(u64, @intCast(i)),
            .method = "GET",
            .route = "/api/users",
        });
        logger.spanEnd(span, .{
            .status_code = @as(u64, 200),
            .cached = false,
        });
    }
    return support.nowNs() - start;
}

fn benchLongMessage(logger: *zlog.Logger(.{}), trace_ctx: zlog.TraceContext, iterations: usize) i128 {
    const message =
        "This is a very long log message that simulates detailed operational context in a production service.";
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace(message, trace_ctx, .{
            .component = "message_processor",
            .length = @as(u64, @intCast(message.len)),
            .iteration = @as(u64, @intCast(i)),
        });
    }
    return support.nowNs() - start;
}

fn printCase(name: []const u8, iterations: usize, duration_ns: i128) void {
    std.debug.print(
        "{s:>14}: {d:>8.2} ms  ({d:>10.0} msg/s)\n",
        .{ name, support.nsToMs(duration_ns), support.perSecond(iterations, duration_ns) },
    );
}
