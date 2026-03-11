const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{
            .async_mode = false,
            .level = .debug,
        },
        .enable_otel_format = true,
        .resource = zlog.Resource.init().withService("checkout-api", "0.3.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("zlog-example")
            .withVersion("0.3.0"),
    };

    var logger = zlog.OTelLogger(otel_config).init(&stdout_writer);
    defer logger.deinit();
    defer stdout_writer.interface.flush() catch {};

    const trace_ctx = zlog.TraceContext.init(true);

    logger.infoWithTrace("checkout accepted", trace_ctx, .{
        .@"http.method" = "POST",
        .@"http.route" = "/v1/checkout",
        .@"http.status_code" = 202,
        .order_id = "ord_12345",
        .tenant = "eu-central",
        .duration_ms = 18.4,
        .cache_hit = false,
    });

    try logger.flush();
}
