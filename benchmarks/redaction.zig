const std = @import("std");
const zlog = @import("zlog");
const support = @import("support.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    std.debug.print("=== Redaction Benchmark ===\n\n", .{});

    const baseline_ns = benchmarkBaseline(150_000);
    const redacted_ns = benchmarkWithRedaction(150_000);
    const dense_redaction_ns = benchmarkDenseRedaction(150_000);

    printCase("baseline", 150_000, baseline_ns);
    printCase("runtime redaction", 150_000, redacted_ns);
    printCase("many protected keys", 150_000, dense_redaction_ns);
}

fn benchmarkBaseline(iterations: usize) i128 {
    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var logger = zlog.Logger(.{}).init(&sink.writer);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace("user activity", trace_ctx, .{
            .username = "john.doe@example.com",
            .password = "super_secret_password_123",
            .api_key = "sk_live_abcdef123456789",
            .attempt = @as(u64, @intCast(i)),
            .success = true,
        });
    }
    return support.nowNs() - start;
}

fn benchmarkWithRedaction(iterations: usize) i128 {
    var redaction_storage: [8][]const u8 = undefined;
    var redaction_config = zlog.RedactionConfig.init(&redaction_storage);
    defer redaction_config.deinit();
    redaction_config.addKey("password") catch unreachable;
    redaction_config.addKey("api_key") catch unreachable;

    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var logger = zlog.Logger(.{}).initWithRedaction(&sink.writer, &redaction_config);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace("user activity", trace_ctx, .{
            .username = "john.doe@example.com",
            .password = "super_secret_password_123",
            .api_key = "sk_live_abcdef123456789",
            .attempt = @as(u64, @intCast(i)),
            .success = true,
        });
    }
    return support.nowNs() - start;
}

fn benchmarkDenseRedaction(iterations: usize) i128 {
    var redaction_storage: [16][]const u8 = undefined;
    var redaction_config = zlog.RedactionConfig.init(&redaction_storage);
    defer redaction_config.deinit();
    for ([_][]const u8{ "ssn", "credit_card", "cvv", "pin", "password", "api_key", "secret_token" }) |key| {
        redaction_config.addKey(key) catch unreachable;
    }

    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var logger = zlog.Logger(.{}).initWithRedaction(&sink.writer, &redaction_config);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.infoWithTrace("payment update", trace_ctx, .{
            .ssn = "123-45-6789",
            .credit_card = "4532123456789012",
            .cvv = "123",
            .pin = "1234",
            .password = "mypassword123",
            .api_key = "sk_live_abc123",
            .secret_token = "token_xyz789",
            .request_id = @as(u64, @intCast(i)),
            .verified = true,
        });
    }
    return support.nowNs() - start;
}

fn printCase(name: []const u8, iterations: usize, duration_ns: i128) void {
    std.debug.print(
        "{s:>18}: {d:>8.2} ms  ({d:>10.0} msg/s)\n",
        .{ name, support.nsToMs(duration_ns), support.perSecond(iterations, duration_ns) },
    );
}
