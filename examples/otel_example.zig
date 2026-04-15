const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const otel_config = comptime zlog.OTelConfig{
        .base_config = .{
            .async_mode = true,
        },
        .resource = zlog.Resource.init().withService("zlog-example", "0.16.0"),
        .instrumentation_scope = zlog.InstrumentationScope.init("otel-example"),
    };

    var logger = try zlog.OTelLogger(otel_config).initAsyncOwnedStderr(gpa, io);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    logger.infoWithTrace("example request complete", trace_ctx, .{
        .http_method = "GET",
        .http_route = "/hello",
        .http_status_code = 200,
        .user_id = "demo-user",
        .duration_ms = @as(u64, 12),
    });

    try logger.runEventLoopUntilDone();
}
