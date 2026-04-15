const std = @import("std");
const zlog = @import("zlog");
const support = @import("support.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const async_config = zlog.Config{
        .async_mode = true,
        .async_queue_size = 4096,
        .batch_size = 64,
        .buffer_size = 8192,
        .enable_simd = true,
    };

    var sink_buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var logger = try zlog.Logger(async_config).initAsync(&sink.writer, allocator);
    defer logger.deinitWithAllocator(allocator);

    const trace_ctx = zlog.TraceContext.init(true);

    std.debug.print("=== Async Logger Benchmark (std.Io) ===\n\n", .{});

    for (0..2_000) |i| {
        logger.infoWithTrace("warmup", trace_ctx, .{
            .iteration = @as(u64, @intCast(i)),
            .service = "benchmark",
            .mode = "async",
        });
    }
    try logger.runEventLoopUntilDone();

    const message_counts = [_]usize{ 1_000, 10_000, 50_000, 100_000 };
    for (message_counts) |count| {
        const start = support.nowNs();
        for (0..count) |i| {
            logger.infoWithTrace("high throughput test", trace_ctx, .{
                .iteration = @as(u64, @intCast(i)),
                .service = "benchmark",
                .mode = "async",
            });
        }
        try logger.runEventLoopUntilDone();
        const duration_ns = support.nowNs() - start;

        std.debug.print(
            "{d:>7} messages in {d:>8.2} ms  ({d:>10.0} msg/s)\n",
            .{ count, support.nsToMs(duration_ns), support.perSecond(count, duration_ns) },
        );
    }

    std.debug.print("\nBytes written to sink: {d}\n", .{sink.fullCount()});
}
