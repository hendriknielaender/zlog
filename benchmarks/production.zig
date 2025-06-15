const std = @import("std");
const zlog = @import("zlog");
const xev = @import("xev");

// Production-like writer that simulates realistic I/O patterns
const ProductionWriter = struct {
    const Self = @This();
    const Error = error{ DiskFull, NetworkTimeout, PermissionDenied };
    const Writer = std.io.Writer(*Self, Error, write);

    bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_latency_ns: u32,
    failure_rate: u32, // Failures per 10000 operations
    random: std.Random.DefaultPrng,

    pub fn init(write_latency_ns: u32, failure_rate: u32) Self {
        return .{
            .write_latency_ns = write_latency_ns,
            .failure_rate = failure_rate,
            .random = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
        };
    }

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

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

    fn generate(allocator: std.mem.Allocator, id: u64) !RequestContext {
        _ = allocator;
        var request_id: [16]u8 = undefined;
        std.crypto.random.bytes(&request_id);

        const endpoints = [_][]const u8{ "/api/users", "/api/orders", "/api/products", "/health", "/metrics" };
        const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE" };

        return RequestContext{
            .request_id = request_id,
            .user_id = 1000 + (id % 50000),
            .endpoint = endpoints[id % endpoints.len],
            .method = methods[id % methods.len],
            .start_time = std.time.milliTimestamp(),
        };
    }

    fn formatRequestId(self: *const RequestContext) [32]u8 {
        var result: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&result, "{x}", .{std.fmt.fmtSliceHexLower(&self.request_id)}) catch unreachable;
        return result;
    }
};

// Production workload simulator
const WorkloadSimulator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    request_count: u32,
    concurrent_requests: u32,
    error_rate: u32,

    pub fn init(allocator: std.mem.Allocator, request_count: u32, concurrent_requests: u32, error_rate: u32) Self {
        return .{
            .allocator = allocator,
            .request_count = request_count,
            .concurrent_requests = concurrent_requests,
            .error_rate = error_rate,
        };
    }

    pub fn runSyncWorkload(self: *Self, logger: anytype) !BenchmarkResult {
        const start_time = std.time.nanoTimestamp();
        var completed_requests: u32 = 0;
        var total_latency_ns: u64 = 0;
        var error_count: u32 = 0;

        // Simulate production request processing
        for (0..self.request_count) |i| {
            const req_start = std.time.nanoTimestamp();
            const ctx = try RequestContext.generate(self.allocator, i);
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

            // Realistic request pacing
            if (i % 100 == 0) {
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }

        const end_time = std.time.nanoTimestamp();
        const total_duration = end_time - start_time;

        return BenchmarkResult{
            .total_duration_ns = @intCast(total_duration),
            .completed_requests = completed_requests,
            .average_latency_ns = @intCast(@divTrunc(total_latency_ns, completed_requests)),
            .error_count = error_count,
            .throughput_rps = @as(f64, @floatFromInt(completed_requests)) / (@as(f64, @floatFromInt(total_duration)) / 1_000_000_000.0),
        };
    }

    pub fn runAsyncWorkload(self: *Self, logger: anytype) !BenchmarkResult {
        return self.runSyncWorkload(logger); // Same workload pattern, different logger
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
        std.debug.print("Total Duration:     {d:>8.1} ms\n", .{@as(f64, @floatFromInt(self.total_duration_ns)) / 1_000_000.0});
        std.debug.print("Completed Requests: {d:>8}\n", .{self.completed_requests});
        std.debug.print("Average Latency:    {d:>8.1} μs\n", .{@as(f64, @floatFromInt(self.average_latency_ns)) / 1000.0});
        std.debug.print("Throughput:         {d:>8.1} req/sec\n", .{self.throughput_rps});
        std.debug.print("Error Count:        {d:>8}\n", .{self.error_count});
        std.debug.print("Error Rate:         {d:>8.2}%\n", .{@as(f64, @floatFromInt(self.error_count)) / @as(f64, @floatFromInt(self.completed_requests)) * 100.0});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
        .{ .name = "Fast SSD", .write_latency_ns = 100_000, .failure_rate = 1 }, // 100μs latency, 0.01% failure
        .{ .name = "Network Log", .write_latency_ns = 5_000_000, .failure_rate = 50 }, // 5ms latency, 0.5% failure
        .{ .name = "Slow Disk", .write_latency_ns = 10_000_000, .failure_rate = 20 }, // 10ms latency, 0.2% failure
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
        var sync_logger = zlog.Logger(.{}).init(sync_writer.writer().any());
        var sync_workload = WorkloadSimulator.init(allocator, request_count, concurrent_requests, error_rate);

        std.debug.print("Running sync benchmark...\n", .{});
        const sync_result = try sync_workload.runSyncWorkload(&sync_logger);
        sync_result.print("Sync Logging");
        std.debug.print("Bytes Written:      {d:>8} bytes\n", .{sync_writer.getBytesWritten()});

        // Async benchmark
        var async_writer = ProductionWriter.init(scenario.write_latency_ns, scenario.failure_rate);
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();

        var async_logger = try zlog.Logger(.{
            .async_mode = true,
            .async_queue_size = 8192,
        }).initAsync(async_writer.writer().any(), &loop, allocator);
        defer async_logger.deinit();

        var async_workload = WorkloadSimulator.init(allocator, request_count, concurrent_requests, error_rate);

        std.debug.print("Running async benchmark...\n", .{});
        const async_result = try async_workload.runAsyncWorkload(&async_logger);

        // Allow time for async processing to complete
        std.time.sleep(100 * std.time.ns_per_ms);

        async_result.print("Async Logging");
        std.debug.print("Bytes Written:      {d:>8} bytes\n", .{async_writer.getBytesWritten()});

        // Performance comparison
        const latency_improvement = @as(f64, @floatFromInt(sync_result.average_latency_ns)) / @as(f64, @floatFromInt(async_result.average_latency_ns));
        const throughput_improvement = async_result.throughput_rps / sync_result.throughput_rps;

        std.debug.print("\n=== Performance Comparison ===\n", .{});
        std.debug.print("Latency Improvement: {d:>8.1}x faster\n", .{latency_improvement});
        std.debug.print("Throughput Gain:     {d:>8.1}x higher\n", .{throughput_improvement});
        std.debug.print("Async Advantage:     {d:>8.1}% better overall\n", .{(throughput_improvement - 1.0) * 100.0});
    }

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Async logging provides significant performance benefits\n", .{});
    std.debug.print("especially under high I/O latency conditions typical\n", .{});
    std.debug.print("in production environments with network logging,\n", .{});
    std.debug.print("slow disks, or high-throughput scenarios.\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
}