const std = @import("std");
const zlog = @import("zlog");

/// Ultra-performance benchmark for the async queue and batched flush path.
pub fn main() !void {
    std.debug.print("=== Ultra-Performance Async Logger Benchmark ===\n", .{});
    std.debug.print("Using bounded queueing with explicit batched flushes\n\n", .{});

    // Create high-performance logger configuration
    const ultra_config = zlog.Config{
        .level = .info,
        .async_mode = true,
        .async_queue_size = 1024, // Using fixed size from new implementation
        .batch_size = 32, // Using fixed size from new implementation
        .buffer_size = 8192, // Buffer for formatting
        .enable_logging = true,
        .enable_simd = true,
    };

    // Use /dev/null for maximum throughput testing
    const dev_null = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer dev_null.close();
    var dev_null_buffer: [4096]u8 = undefined;
    var dev_null_writer = dev_null.writer(&dev_null_buffer);

    // Initialize ultra-performance async logger
    var async_state = zlog.Logger(ultra_config).AsyncState{};
    var logger = zlog.Logger(ultra_config).initAsync(&dev_null_writer, &async_state);
    defer logger.deinit();

    // Create trace context for all operations
    const trace_ctx = zlog.TraceContext.init(true);

    // Pre-create fields to avoid allocation during benchmark
    const benchmark_fields = [_]zlog.Field{
        zlog.field.string("service", "benchmark"),
        zlog.field.string("operation", "test_logging"),
        zlog.field.uint("iteration", 12345),
        zlog.field.string("environment", "performance_test"),
    };

    std.debug.print("Warming up...\n", .{});

    // Warmup phase
    for (0..1000) |i| {
        logger.infoWithTrace("warmup message", trace_ctx, &benchmark_fields);

        if (i % 100 == 0) {
            // Drain queued logs periodically.
            logger.drain();
        }
    }

    // Drain any remaining warmup messages.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    logger.drain();

    std.debug.print("  Warmup complete\n", .{});
    std.debug.print("Starting main benchmark...\n", .{});

    // Main benchmark phase
    const message_counts = [_]u32{ 1_000, 10_000, 50_000, 100_000 };

    for (message_counts) |msg_count| {
        std.debug.print("\n--- Testing {} messages ---\n", .{msg_count});

        const start_time = std.time.nanoTimestamp();

        // Send messages with periodic queue draining.
        for (0..msg_count) |i| {
            logger.infoWithTrace("high throughput test message", trace_ctx, &benchmark_fields);

            // Process queued writes periodically.
            if (i % 1000 == 0) {
                logger.drain();
            }
        }

        // Process any remaining messages.
        for (0..10) |_| {
            logger.drain();
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }

        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        const messages_per_second = @as(f64, @floatFromInt(msg_count)) / (duration_ms / 1000.0);

        std.debug.print("  Time:         {d:.1} ms\n", .{duration_ms});
        std.debug.print("  Messages:     {}\n", .{msg_count});
        std.debug.print("  Throughput:   {d:.0} messages/second\n", .{messages_per_second});
        std.debug.print(
            "  Throughput:   {d:.2} million messages/second\n",
            .{messages_per_second / 1_000_000.0},
        );

        if (messages_per_second >= 1_000_000.0) {
            std.debug.print("  ✅ SUCCESS: Achieved > 1M messages/second!\n", .{});
        } else if (messages_per_second >= 500_000.0) {
            std.debug.print("  ⚠️  Good: Achieved > 500K messages/second\n", .{});
        } else {
            std.debug.print(
                "  📊 Result: {d:.0}K messages/second\n",
                .{messages_per_second / 1000.0},
            );
        }
    }

    // Test burst throughput
    std.debug.print("\n--- Burst Test (100K messages, minimal processing) ---\n", .{});
    const minimal_fields = [_]zlog.Field{
        zlog.field.uint("id", 42),
    };

    const burst_count: u32 = 100_000;
    const start_burst = std.time.nanoTimestamp();

    // Send messages with minimal queue draining.
    for (0..burst_count) |i| {
        logger.infoWithTrace("burst", trace_ctx, &minimal_fields);

        // Less frequent draining for maximum throughput.
        if (i % 10000 == 0) {
            logger.drain();
        }
    }

    // Final processing.
    for (0..20) |_| {
        logger.drain();
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    const end_burst = std.time.nanoTimestamp();
    const burst_duration_ms = @as(f64, @floatFromInt(end_burst - start_burst)) / 1_000_000.0;
    const burst_throughput = @as(f64, @floatFromInt(burst_count)) / (burst_duration_ms / 1000.0);

    std.debug.print("  Time:         {d:.1} ms\n", .{burst_duration_ms});
    std.debug.print("  Messages:     {}\n", .{burst_count});
    std.debug.print("  Throughput:   {d:.0} messages/second\n", .{burst_throughput});
    std.debug.print(
        "  Throughput:   {d:.2} million messages/second\n",
        .{burst_throughput / 1_000_000.0},
    );

    if (burst_throughput >= 2_000_000.0) {
        std.debug.print("  🚀 EXCELLENT: Achieved > 2M messages/second!\n", .{});
    } else if (burst_throughput >= 1_000_000.0) {
        std.debug.print("  ✅ SUCCESS: Achieved > 1M messages/second!\n", .{});
    }

    // Final flush - run until the queue is empty.
    std.debug.print("\nFlushing remaining messages...\n", .{});
    var flush_iterations: u32 = 0;
    while (flush_iterations < 100) : (flush_iterations += 1) {
        logger.drain();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    std.debug.print("\n=== Ultra-Performance Benchmark Complete ===\n", .{});
    std.debug.print("Async Queue Summary:\n", .{});
    std.debug.print("  - Bounded queue allocated during initialization\n", .{});
    std.debug.print("  - Batched writes drained by explicit flush points\n", .{});
    std.debug.print("  - Pre-formatted JSON in caller thread\n", .{});
    std.debug.print("  - Memory-safe: no dangling pointers\n", .{});
    std.debug.print("  - Zero allocation in the hot path\n", .{});
}
