const std = @import("std");
const zlog = @import("zlog");
const support = @import("support.zig");

const BenchmarkResult = struct {
    total_duration_ns: i128,
    average_latency_ns: i128,
    error_count: usize,
    request_count: usize,

    fn throughput(self: BenchmarkResult) f64 {
        return support.perSecond(self.request_count, self.total_duration_ns);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var runtime = std.Io.Threaded.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    std.debug.print("=== Production Workload Benchmark ===\n", .{});
    std.debug.print("Comparing sync and async logging with synthetic sink latency.\n\n", .{});

    const scenarios = [_]struct {
        name: []const u8,
        latency_ns: i128,
    }{
        .{ .name = "Fast SSD", .latency_ns = 100_000 },
    };

    for (scenarios) |scenario| {
        std.debug.print("--- {s} ({d} us sink latency) ---\n", .{
            scenario.name,
            @divTrunc(scenario.latency_ns, 1_000),
        });

        var sync_buffer: [4096]u8 = undefined;
        var sync_sink = support.LatencyWriter.init(io, scenario.latency_ns, &sync_buffer);
        var sync_logger = zlog.Logger(.{}).init(&sync_sink.writer);
        defer sync_logger.deinit();

        const sync_result = runWorkload(&sync_logger, 1_000);
        printResult("sync", sync_result, sync_sink.totalBytes());

        var async_buffer: [4096]u8 = undefined;
        var async_sink = support.LatencyWriter.init(io, scenario.latency_ns, &async_buffer);
        var async_logger = try zlog.Logger(.{
            .async_mode = true,
            .async_queue_size = 8192,
            .batch_size = 64,
        }).initAsync(&async_sink.writer, allocator);
        defer async_logger.deinitWithAllocator(allocator);

        const async_result = runWorkload(&async_logger, 1_000);
        try async_logger.runEventLoopUntilDone();
        printResult("async", async_result, async_sink.totalBytes());

        std.debug.print("throughput delta: {d:>8.2}x\n\n", .{async_result.throughput() / sync_result.throughput()});
    }
}

fn runWorkload(logger: anytype, request_count: usize) BenchmarkResult {
    var total_latency_ns: i128 = 0;
    var error_count: usize = 0;
    const start = support.nowNs();

    for (0..request_count) |i| {
        const req_start = support.nowNs();

        var request_id_buffer: [24]u8 = undefined;
        const request_id = std.fmt.bufPrint(&request_id_buffer, "req-{d}", .{i}) catch {
            @panic("request id buffer overflow");
        };
        const method = if (i % 3 == 0) "POST" else "GET";
        const endpoint = switch (i % 4) {
            0 => "/api/users",
            1 => "/api/orders",
            2 => "/api/products",
            else => "/health",
        };

        logger.info("request validated", .{
            .request_id = request_id,
            .method = method,
            .endpoint = endpoint,
            .stage = "validation",
            .user_id = @as(u64, 1000) + @as(u64, @intCast(i % 5000)),
        });

        logger.debug("database connection acquired", .{
            .request_id = request_id,
            .pool = "primary",
            .query_type = "user_lookup",
        });

        const should_fail = i % 20 == 0;
        if (should_fail) {
            logger.err("request failed", .{
                .request_id = request_id,
                .@"error" = "invalid_payment_method",
                .error_code = @as(u64, 4001),
            });
            error_count += 1;
        } else {
            logger.info("request completed", .{
                .request_id = request_id,
                .response_size = @as(u64, 256) + @as(u64, @intCast(i % 1024)),
            });
        }

        const req_end = support.nowNs();
        total_latency_ns += req_end - req_start;

        if (i % 100 == 0) support.sleepMs(1);
    }

    const total_duration_ns = support.nowNs() - start;
    return .{
        .total_duration_ns = total_duration_ns,
        .average_latency_ns = @divTrunc(total_latency_ns, @as(i128, @intCast(request_count))),
        .error_count = error_count,
        .request_count = request_count,
    };
}

fn printResult(label: []const u8, result: BenchmarkResult, bytes_written: u64) void {
    std.debug.print(
        "{s:>5}: {d:>8.2} ms total  {d:>8.2} us avg  {d:>8.0} req/s  errors={d:>3}  bytes={d}\n",
        .{
            label,
            support.nsToMs(result.total_duration_ns),
            @as(f64, @floatFromInt(result.average_latency_ns)) / 1_000.0,
            result.throughput(),
            result.error_count,
            bytes_written,
        },
    );
}
