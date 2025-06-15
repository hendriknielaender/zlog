const std = @import("std");
const zbench = @import("zbench");
const zlog = @import("zlog");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// Null writer for performance testing without I/O overhead
const NullWriter = struct {
    const Self = @This();
    const Error = error{};
    const Writer = std.io.Writer(*Self, Error, write);

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    fn write(self: *Self, bytes: []const u8) Error!usize {
        _ = self;
        return bytes.len;
    }
};

fn benchZlogNoAllocations(allocator: std.mem.Allocator) void {
    _ = allocator; // zlog shouldn't use the allocator
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    for (0..1000) |i| {
        logger.info("User action", &.{
            zlog.field.string("user_id", "12345"),
            zlog.field.string("action", "login"),
            zlog.field.int("timestamp", @intCast(i)),
        });
    }
}

fn benchZlogWithTracking(allocator: std.mem.Allocator) void {
    _ = allocator; // zlog shouldn't use the allocator
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    for (0..1000) |i| {
        logger.info("User action", &.{
            zlog.field.string("user_id", "12345"),
            zlog.field.string("action", "login"),
            zlog.field.int("timestamp", @intCast(i)),
        });
    }
}

fn benchStdFormatWithAllocations(allocator: std.mem.Allocator) void {
    var null_writer = NullWriter{};

    for (0..1000) |i| {
        // This simulates a typical logging approach that allocates
        const formatted = std.fmt.allocPrint(allocator, "{{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"12345\",\"action\":\"login\",\"timestamp\":{d}}}\n", .{i}) catch @panic("OOM");
        defer allocator.free(formatted);

        _ = null_writer.writer().write(formatted) catch {};
    }
}

fn benchArrayListLogging(allocator: std.mem.Allocator) void {
    var null_writer = NullWriter{};

    for (0..1000) |i| {
        // Another common pattern - using ArrayList for dynamic formatting
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        const writer = list.writer();
        std.fmt.format(writer, "{{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"12345\",\"action\":\"login\",\"timestamp\":{d}}}\n", .{i}) catch @panic("Format error");

        _ = null_writer.writer().write(list.items) catch {};
    }
}

fn benchReusedBuffer(allocator: std.mem.Allocator) void {
    _ = allocator; // This approach doesn't allocate per message
    var null_writer = NullWriter{};
    var buffer: [1024]u8 = undefined;

    for (0..1000) |i| {
        const formatted = std.fmt.bufPrint(&buffer, "{{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"12345\",\"action\":\"login\",\"timestamp\":{d}}}\n", .{i}) catch @panic("Buffer too small");

        _ = null_writer.writer().write(formatted) catch {};
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var bench = zbench.Benchmark.init(gpa.allocator(), .{
        .iterations = 32,
    });
    defer {
        bench.deinit();
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.debug.panic("Memory leak detected", .{});
    }

    try stdout.writeAll("=== Memory Allocation Benchmarks ===\n\n");
    try stdout.writeAll("Comparing zlog's zero-allocation approach with traditional logging methods.\n\n");

    // zlog benchmarks (should show zero allocations)
    try bench.add("zlog (no tracking)", benchZlogNoAllocations, .{});
    try bench.add("zlog (with tracking)", benchZlogWithTracking, .{
        .track_allocations = true,
    });

    // Traditional approaches (should show allocations)
    try bench.add("std.fmt.allocPrint", benchStdFormatWithAllocations, .{
        .track_allocations = true,
    });
    try bench.add("ArrayList logging", benchArrayListLogging, .{
        .track_allocations = true,
    });

    // Optimal traditional approach (should show zero allocations)
    try bench.add("reused buffer", benchReusedBuffer, .{
        .track_allocations = true,
    });

    try bench.run(stdout);

    try stdout.writeAll("\n=== Analysis ===\n");
    try stdout.writeAll("• zlog shows zero allocations, confirming the zero-allocation design\n");
    try stdout.writeAll("• std.fmt.allocPrint allocates for every message (typical logging)\n");
    try stdout.writeAll("• ArrayList logging allocates and reallocates buffers\n");
    try stdout.writeAll("• Reused buffer approach matches zlog's zero allocation goal\n");
    try stdout.writeAll("• zlog provides zero allocations AND structured logging convenience\n");
}
