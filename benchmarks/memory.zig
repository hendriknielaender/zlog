const std = @import("std");
const zlog = @import("zlog");
const support = @import("support.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Memory-Oriented Logging Benchmark ===\n\n", .{});

    const iterations = 50_000;
    const zlog_ns = benchZlog(iterations);
    const alloc_print_ns = try benchAllocPrint(allocator, iterations);
    const buf_print_ns = try benchBufPrint(iterations);

    printCase("zlog sync logger", iterations, zlog_ns);
    printCase("std.fmt.allocPrint", iterations, alloc_print_ns);
    printCase("std.fmt.bufPrint", iterations, buf_print_ns);

    std.debug.print(
        "\nallocPrint remains the allocation-heavy baseline, while zlog and bufPrint stay on stack or caller-managed buffers.\n",
        .{},
    );
}

fn benchZlog(iterations: usize) i128 {
    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var logger = zlog.Logger(.{}).init(&sink.writer);
    defer logger.deinit();

    const start = support.nowNs();
    for (0..iterations) |i| {
        logger.info("User action", .{
            .user_id = "12345",
            .action = "login",
            .timestamp = @as(i64, @intCast(i)),
        });
    }
    return support.nowNs() - start;
}

fn benchAllocPrint(allocator: std.mem.Allocator, iterations: usize) !i128 {
    const start = support.nowNs();
    for (0..iterations) |i| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"12345\",\"action\":\"login\",\"timestamp\":{d}}}\n",
            .{i},
        );
        allocator.free(line);
    }
    return support.nowNs() - start;
}

fn benchBufPrint(iterations: usize) !i128 {
    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    var line_buffer: [160]u8 = undefined;

    const start = support.nowNs();
    for (0..iterations) |i| {
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "{{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"12345\",\"action\":\"login\",\"timestamp\":{d}}}\n",
            .{i},
        );
        try sink.writer.writeAll(line);
    }
    return support.nowNs() - start;
}

fn printCase(name: []const u8, iterations: usize, duration_ns: i128) void {
    std.debug.print(
        "{s:>20}: {d:>8.2} ms  ({d:>10.0} msg/s)\n",
        .{ name, support.nsToMs(duration_ns), support.perSecond(iterations, duration_ns) },
    );
}
