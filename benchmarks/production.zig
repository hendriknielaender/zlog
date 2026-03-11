const std = @import("std");
const zlog = @import("zlog");

const async_config = zlog.Config{
    .async_mode = true,
    .async_queue_size = 1024,
    .batch_size = 32,
};
const async_flush_interval = 64;

var async_state: zlog.Logger(async_config).AsyncState = .{};

// Production-like writer that simulates realistic I/O patterns
const ProductionWriter = struct {
    const Self = @This();
    const Error = error{ DiskFull, NetworkTimeout, PermissionDenied };

    writer: std.Io.Writer,
    bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_latency_ns: u32,
    failure_rate: u32, // Failures per 10000 operations
    last_error: ?Error = null,
    random: std.Random.DefaultPrng,

    pub fn init(write_latency_ns: u32, failure_rate: u32) Self {
        return .{
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
            .write_latency_ns = write_latency_ns,
            .failure_rate = failure_rate,
            .random = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
        };
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .sendFile = std.Io.Writer.unimplementedSendFile,
        .flush = std.Io.Writer.noopFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn write(self: *Self, bytes: []const u8) Error!usize {
        // Simulate write latency
        if (self.write_latency_ns > 0) {
            const start = std.time.nanoTimestamp();
            while (std.time.nanoTimestamp() - start < self.write_latency_ns) {
                std.atomic.spinLoopHint();
            }
        }

        // Simulate occasional failures
        if (self.failure_rate > 0) {
            const rand_val = self.random.random().intRangeAtMost(u32, 0, 9999);
            if (rand_val < self.failure_rate) {
                return switch (rand_val % 3) {
                    0 => Error.DiskFull,
                    1 => Error.NetworkTimeout,
                    else => Error.PermissionDenied,
                };
            }
        }

        _ = self.bytes_written.fetchAdd(bytes.len, .monotonic);
        return bytes.len;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Self = @alignCast(@fieldParentPtr("writer", w));

        if (w.end != 0) {
            self.writeAllBytes(w.buffered()) catch |err| {
                self.last_error = err;
                return error.WriteFailed;
            };
            w.end = 0;
        }

        if (data.len == 0) return 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.writeAllBytes(slice) catch |err| {
                self.last_error = err;
                return error.WriteFailed;
            };
            consumed += slice.len;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.writeAllBytes(pattern) catch |err| {
                self.last_error = err;
                return error.WriteFailed;
            };
            consumed += pattern.len;
        }

        return consumed;
    }

    fn writeAllBytes(self: *Self, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        _ = try self.write(bytes);
    }

    pub fn getBytesWritten(self: *const Self) u64 {
        return self.bytes_written.load(.monotonic);
    }
};

// Realistic request context for web service simulation
const RequestContext = struct {
    request_id: [16]u8,
    user_id: u64,
    endpoint: []const u8,
    method: []const u8,
    start_time: i64,

    fn generate(id: u64) RequestContext {
        var request_id: [16]u8 = undefined;
        std.crypto.random.bytes(&request_id);

        const endpoints = [_][]const u8{
            "/api/users",
            "/api/orders",
            "/api/products",
            "/health",
            "/metrics",
        };
        const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE" };

        return .{
            .request_id = request_id,
            .user_id = 1000 + (id % 50000),
            .endpoint = endpoints[id % endpoints.len],
            .method = methods[id % methods.len],
            .start_time = std.time.milliTimestamp(),
        };
    }

    fn formatRequestId(self: *const RequestContext) [32]u8 {
        var result: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&result, "{x}", .{self.request_id}) catch unreachable;
        return result;
    }
};

// Production workload simulator
const WorkloadSimulator = struct {
    const Self = @This();

    request_count: u32,
    concurrent_requests: u32,
    error_rate: u32,

    pub fn init(request_count: u32, concurrent_requests: u32, error_rate: u32) Self {
        return .{
            .request_count = request_count,
            .concurrent_requests = concurrent_requests,
            .error_rate = error_rate,
        };
    }

    pub fn runSyncWorkload(self: *Self, logger: anytype) !BenchmarkResult {
        return self.runWorkload(logger, 0);
    }

    pub fn runAsyncWorkload(self: *Self, logger: anytype) !BenchmarkResult {
        return self.runWorkload(logger, async_flush_interval);
    }

    fn runWorkload(self: *Self, logger: anytype, flush_every: u32) !BenchmarkResult {
        const start_time = std.time.nanoTimestamp();
        var completed_requests: u32 = 0;
        var total_latency_ns: u64 = 0;
        var error_count: u32 = 0;

        // Simulate production request processing
        for (0..self.request_count) |i| {
            const req_start = std.time.nanoTimestamp();
            const ctx = RequestContext.generate(i);
            const req_id_str = ctx.formatRequestId();

            // Request start logging
            const request_span = logger.spanStart("http_request", &.{
                zlog.field.string("request_id", &req_id_str),
                zlog.field.string("method", ctx.method),
                zlog.field.string("endpoint", ctx.endpoint),
                zlog.field.uint("user_id", ctx.user_id),
            });

            // Simulate request processing with multiple log events
            logger.info("Request validation", &.{
                zlog.field.string("request_id", &req_id_str),
                zlog.field.string("stage", "validation"),
            });

            // Simulate database operations
            const db_span = logger.spanStart("database_query", &.{
                zlog.field.string("request_id", &req_id_str),
                zlog.field.string("query_type", "user_lookup"),
                zlog.field.uint("user_id", ctx.user_id),
            });

            logger.debug("Database connection acquired", &.{
                zlog.field.string("request_id", &req_id_str),
                zlog.field.string("pool", "primary"),
            });

            logger.spanEnd(db_span, &.{
                zlog.field.string("request_id", &req_id_str),
                zlog.field.uint("rows_affected", 1),
            });

            // Simulate business logic
            logger.info("Processing business logic", &.{
                zlog.field.string("request_id", &req_id_str),
                zlog.field.string("operation", "order_calculation"),
            });

            // Simulate occasional errors
            const should_error = (i % 100) < self.error_rate;
            if (should_error) {
                logger.err("Request processing failed", &.{
                    zlog.field.string("request_id", &req_id_str),
                    zlog.field.string("error", "invalid_payment_method"),
                    zlog.field.uint("error_code", 4001),
                });
                error_count += 1;
            } else {
                logger.info("Request completed successfully", &.{
                    zlog.field.string("request_id", &req_id_str),
                    zlog.field.uint("response_size", 256 + (i % 1024)),
                });
            }

            const req_end = std.time.nanoTimestamp();
            const req_latency = req_end - req_start;
            total_latency_ns += @intCast(req_latency);

            logger.spanEnd(request_span, &.{
                zlog.field.string("request_id", &req_id_str),
                zlog.field.uint("status_code", if (should_error) 400 else 200),
                zlog.field.uint("duration_ms", @intCast(@divTrunc(req_latency, 1_000_000))),
            });

            completed_requests += 1;

            if (flush_every > 0 and completed_requests % flush_every == 0) {
                try logger.flush();
            }

            // Realistic request pacing
            if (i % 100 == 0) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        const end_time = std.time.nanoTimestamp();
        const total_duration = end_time - start_time;

        return BenchmarkResult{
            .total_duration_ns = @intCast(total_duration),
            .completed_requests = completed_requests,
            .average_latency_ns = @intCast(@divTrunc(total_latency_ns, completed_requests)),
            .error_count = error_count,
            .throughput_rps = @as(f64, @floatFromInt(completed_requests)) /
                (@as(f64, @floatFromInt(total_duration)) / 1_000_000_000.0),
        };
    }
};

const BenchmarkResult = struct {
    total_duration_ns: u64,
    completed_requests: u32,
    average_latency_ns: u64,
    error_count: u32,
    throughput_rps: f64,

    pub fn print(self: BenchmarkResult, mode: []const u8) void {
        std.debug.print("\n=== {s} Results ===\n", .{mode});
        std.debug.print(
            "Total Duration:     {d:>8.1} ms\n",
            .{@as(f64, @floatFromInt(self.total_duration_ns)) / 1_000_000.0},
        );
        std.debug.print("Completed Requests: {d:>8}\n", .{self.completed_requests});
        std.debug.print(
            "Average Latency:    {d:>8.1} μs\n",
            .{@as(f64, @floatFromInt(self.average_latency_ns)) / 1000.0},
        );
        std.debug.print("Throughput:         {d:>8.1} req/sec\n", .{self.throughput_rps});
        std.debug.print("Error Count:        {d:>8}\n", .{self.error_count});
        std.debug.print(
            "Error Rate:         {d:>8.2}%\n",
            .{
                @as(f64, @floatFromInt(self.error_count)) /
                    @as(f64, @floatFromInt(self.completed_requests)) * 100.0,
            },
        );
    }
};

pub fn main() !void {
    std.debug.print("=== Production-Near Async vs Sync Logging Benchmark ===\n", .{});
    std.debug.print("Simulating high-throughput web service with realistic I/O patterns\n", .{});

    const request_count = 1000;
    const concurrent_requests = 10;
    const error_rate = 5; // 5% error rate

    // Test scenarios with different I/O characteristics
    const scenarios = [_]struct {
        name: []const u8,
        write_latency_ns: u32,
        failure_rate: u32,
    }{
        .{ .name = "Fast SSD", .write_latency_ns = 100_000, .failure_rate = 1 }, // 100μs latency
        .{
            .name = "Network Log",
            .write_latency_ns = 5_000_000,
            .failure_rate = 50,
        }, // 5ms latency
        .{
            .name = "Slow Disk",
            .write_latency_ns = 10_000_000,
            .failure_rate = 20,
        }, // 10ms latency
    };

    for (scenarios) |scenario| {
        std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
        std.debug.print("Scenario: {s} (latency: {d}μs, failure: {d:.2}%)\n", .{
            scenario.name,
            @divTrunc(scenario.write_latency_ns, 1000),
            @as(f64, @floatFromInt(scenario.failure_rate)) / 100.0,
        });
        std.debug.print("=" ** 60 ++ "\n", .{});

        // Sync benchmark
        var sync_writer = ProductionWriter.init(scenario.write_latency_ns, scenario.failure_rate);
        var sync_logger = zlog.Logger(.{}).init(&sync_writer);
        var sync_workload = WorkloadSimulator.init(request_count, concurrent_requests, error_rate);

        std.debug.print("Running sync benchmark...\n", .{});
        const sync_result = try sync_workload.runSyncWorkload(&sync_logger);
        sync_result.print("Sync Logging");
        std.debug.print("Bytes Written:      {d:>8} bytes\n", .{sync_writer.getBytesWritten()});

        // Async benchmark
        var async_writer = ProductionWriter.init(scenario.write_latency_ns, scenario.failure_rate);
        async_state = .{};
        var async_logger = zlog.Logger(async_config).initAsync(&async_writer, &async_state);
        defer async_logger.deinit();

        var async_workload = WorkloadSimulator.init(request_count, concurrent_requests, error_rate);

        std.debug.print("Running async benchmark...\n", .{});
        var async_result = try async_workload.runAsyncWorkload(&async_logger);
        const flush_start = std.time.nanoTimestamp();
        try async_logger.flush();
        const flush_end = std.time.nanoTimestamp();
        const flush_duration_ns = flush_end - flush_start;

        async_result.total_duration_ns += @intCast(flush_duration_ns);
        async_result.throughput_rps =
            @as(f64, @floatFromInt(async_result.completed_requests)) /
            (@as(f64, @floatFromInt(async_result.total_duration_ns)) / 1_000_000_000.0);

        async_result.print("Async Logging");
        std.debug.print("Bytes Written:      {d:>8} bytes\n", .{async_writer.getBytesWritten()});

        // Performance comparison
        const latency_improvement =
            @as(f64, @floatFromInt(sync_result.average_latency_ns)) /
            @as(f64, @floatFromInt(async_result.average_latency_ns));
        const throughput_improvement = async_result.throughput_rps / sync_result.throughput_rps;

        std.debug.print("\n=== Performance Comparison ===\n", .{});
        std.debug.print("Latency Improvement: {d:>8.1}x faster\n", .{latency_improvement});
        std.debug.print("Throughput Gain:     {d:>8.1}x higher\n", .{throughput_improvement});
        std.debug.print(
            "Async Advantage:     {d:>8.1}% better overall\n",
            .{(throughput_improvement - 1.0) * 100.0},
        );
    }

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Async logging provides significant performance benefits\n", .{});
    std.debug.print("especially under high I/O latency conditions typical\n", .{});
    std.debug.print("in production environments with network logging,\n", .{});
    std.debug.print("slow disks, or high-throughput scenarios.\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
}
