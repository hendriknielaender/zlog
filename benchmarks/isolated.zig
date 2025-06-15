const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    const N = 10_000;
    const buf_len = 1024;

    // Null writer for I/O measurement
    var null_writer = struct {
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
    }{};

    std.debug.print("=== Isolated Performance Analysis ===\n\n", .{});

    // Phase A: Pure JSON formatting (no I/O, no mutex)
    std.debug.print("Phase A: Pure JSON Serialization\n", .{});
    var serialize_ns: u64 = 0;
    for (0..N) |i| {
        var buf: [buf_len]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        const t0 = std.time.nanoTimestamp();

        // Direct formatting
        _ = formatLogRecord(writer, .info, "User action", &.{
            zlog.field.string("user_id", "12345"),
            zlog.field.string("action", "login"),
            zlog.field.int("ts", @intCast(i)),
        }) catch 0;

        const t1 = std.time.nanoTimestamp();
        serialize_ns += @intCast(t1 - t0);
    }

    // Phase B: Pure I/O (no formatting)
    std.debug.print("Phase B: Pure I/O\n", .{});
    var write_ns: u64 = 0;
    var dummy: [buf_len]u8 = undefined;
    @memset(&dummy, 'x');
    const dummy_json = "{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"12345\",\"action\":\"login\",\"ts\":1234}\n";

    for (0..N) |_| {
        const t0 = std.time.nanoTimestamp();
        _ = null_writer.writer().write(dummy_json) catch 0;
        const t1 = std.time.nanoTimestamp();
        write_ns += @intCast(t1 - t0);
    }

    // Phase C: Mutex overhead
    std.debug.print("Phase C: Mutex Overhead\n", .{});
    var mutex_ns: u64 = 0;
    var mutex = std.Thread.Mutex{};

    for (0..N) |_| {
        const t0 = std.time.nanoTimestamp();
        mutex.lock();
        // Simulate minimal work inside critical section
        std.mem.doNotOptimizeAway(dummy_json.len);
        mutex.unlock();
        const t1 = std.time.nanoTimestamp();
        mutex_ns += @intCast(t1 - t0);
    }

    // Phase D: Level filtering
    std.debug.print("Phase D: Level Filtering\n", .{});
    var filter_ns: u64 = 0;
    const current_level = zlog.Level.info;
    const test_level = zlog.Level.debug;

    for (0..N) |_| {
        const t0 = std.time.nanoTimestamp();
        const should_log = @intFromEnum(test_level) >= @intFromEnum(current_level);
        std.mem.doNotOptimizeAway(should_log);
        const t1 = std.time.nanoTimestamp();
        filter_ns += @intCast(t1 - t0);
    }

    // Phase E: Complete logger call (for comparison)
    std.debug.print("Phase E: Complete Logger Pipeline\n", .{});
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());
    var complete_ns: u64 = 0;

    for (0..N) |i| {
        const t0 = std.time.nanoTimestamp();
        logger.info("User action", &.{
            zlog.field.string("user_id", "12345"),
            zlog.field.string("action", "login"),
            zlog.field.int("ts", @intCast(i)),
        });
        const t1 = std.time.nanoTimestamp();
        complete_ns += @intCast(t1 - t0);
    }

    // Results
    std.debug.print("\n=== Results (per operation) ===\n", .{});
    std.debug.print("Serialization:     {d:>6} ns ({d:>4.1} μs)\n", .{ serialize_ns / N, @as(f64, @floatFromInt(serialize_ns)) / @as(f64, @floatFromInt(N)) / 1000.0 });
    std.debug.print("I/O:               {d:>6} ns ({d:>4.1} μs)\n", .{ write_ns / N, @as(f64, @floatFromInt(write_ns)) / @as(f64, @floatFromInt(N)) / 1000.0 });
    std.debug.print("Mutex:             {d:>6} ns ({d:>4.1} μs)\n", .{ mutex_ns / N, @as(f64, @floatFromInt(mutex_ns)) / @as(f64, @floatFromInt(N)) / 1000.0 });
    std.debug.print("Level filtering:   {d:>6} ns ({d:>4.1} μs)\n", .{ filter_ns / N, @as(f64, @floatFromInt(filter_ns)) / @as(f64, @floatFromInt(N)) / 1000.0 });
    std.debug.print("Complete pipeline: {d:>6} ns ({d:>4.1} μs)\n", .{ complete_ns / N, @as(f64, @floatFromInt(complete_ns)) / @as(f64, @floatFromInt(N)) / 1000.0 });

    // Analysis
    const overhead = complete_ns - serialize_ns - write_ns;
    std.debug.print("\n=== Analysis ===\n", .{});
    std.debug.print("Core work (serialize + I/O): {d} ns\n", .{(serialize_ns + write_ns) / N});
    std.debug.print("Overhead (mutex + other):     {d} ns\n", .{overhead / N});
    std.debug.print("Overhead percentage:          {d:.1}%\n", .{@as(f64, @floatFromInt(overhead)) / @as(f64, @floatFromInt(complete_ns)) * 100.0});

    // Throughput calculations
    std.debug.print("\n=== Throughput ===\n", .{});
    const complete_ops_per_sec = @as(f64, 1_000_000_000.0) / (@as(f64, @floatFromInt(complete_ns)) / @as(f64, @floatFromInt(N)));
    const serialize_ops_per_sec = @as(f64, 1_000_000_000.0) / (@as(f64, @floatFromInt(serialize_ns)) / @as(f64, @floatFromInt(N)));

    std.debug.print("Complete pipeline: {d:>8.0} ops/sec\n", .{complete_ops_per_sec});
    std.debug.print("Pure serialization: {d:>8.0} ops/sec\n", .{serialize_ops_per_sec});
}

// Direct formatting function (extracted from zlog internals)
fn formatLogRecord(
    writer: anytype,
    level: zlog.Level,
    message: []const u8,
    fields: []const zlog.Field,
) !usize {
    const start_pos = try writer.context.getPos();

    try writer.writeByte('{');

    // Write level field
    try writer.writeAll("\"level\":\"");
    try writer.writeAll(level.json_string());
    try writer.writeByte('"');

    // Write message field
    try writer.writeAll(",\"message\":\"");
    try writeEscapedString(writer, message);
    try writer.writeByte('"');

    // Write additional fields
    for (fields) |field| {
        try writer.writeByte(',');
        try writer.writeByte('"');
        try writeEscapedString(writer, field.key);
        try writer.writeAll("\":");

        switch (field.value) {
            .string => |s| {
                try writer.writeByte('"');
                try writeEscapedString(writer, s);
                try writer.writeByte('"');
            },
            .int => |i| try writer.print("{d}", .{i}),
            .uint => |u| try writer.print("{d}", .{u}),
            .float => |f| try writer.print("{d}", .{f}),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => try writer.writeAll("null"),
        }
    }

    try writer.writeAll("}\n");

    const end_pos = try writer.context.getPos();
    return end_pos - start_pos;
}

fn writeEscapedString(writer: anytype, string: []const u8) !void {
    for (string) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (char < 0x20) {
                    try writer.print("\\u{x:0>4}", .{char});
                } else {
                    try writer.writeByte(char);
                }
            },
        }
    }
}
