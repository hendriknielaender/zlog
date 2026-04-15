const std = @import("std");
const zlog = @import("zlog");
const support = @import("support.zig");

pub fn main() !void {
    const iterations = 10_000;
    const io = support.runtimeIo();

    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);

    std.debug.print("=== Isolated Performance Analysis ===\n\n", .{});

    var serialize_ns: u64 = 0;
    for (0..iterations) |i| {
        var buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        const start = support.nowNs();
        _ = formatLogRecord(&writer, .info, "User action", &.{
            zlog.field.string("user_id", "12345"),
            zlog.field.string("action", "login"),
            zlog.field.int("ts", @as(i64, @intCast(i))),
        }) catch @panic("isolated serialization buffer overflow");
        serialize_ns += @as(u64, @intCast(support.nowNs() - start));
    }

    const dummy_json = "{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"12345\",\"action\":\"login\",\"ts\":1234}\n";
    var write_ns: u64 = 0;
    for (0..iterations) |_| {
        const start = support.nowNs();
        sink.writer.writeAll(dummy_json) catch unreachable;
        write_ns += @as(u64, @intCast(support.nowNs() - start));
    }

    var mutex_ns: u64 = 0;
    var mutex: std.Io.Mutex = .init;
    for (0..iterations) |_| {
        const start = support.nowNs();
        mutex.lock(io) catch @panic("isolated mutex lock failed");
        std.mem.doNotOptimizeAway(dummy_json.len);
        mutex.unlock(io);
        mutex_ns += @as(u64, @intCast(support.nowNs() - start));
    }

    var filter_ns: u64 = 0;
    for (0..iterations) |_| {
        const start = support.nowNs();
        const should_log = @intFromEnum(zlog.Level.debug) >= @intFromEnum(zlog.Level.info);
        std.mem.doNotOptimizeAway(should_log);
        filter_ns += @as(u64, @intCast(support.nowNs() - start));
    }

    var logger = zlog.Logger(.{}).init(&sink.writer);
    defer logger.deinit();

    var complete_ns: u64 = 0;
    for (0..iterations) |i| {
        const start = support.nowNs();
        logger.info("User action", .{
            .user_id = "12345",
            .action = "login",
            .ts = @as(i64, @intCast(i)),
        });
        complete_ns += @as(u64, @intCast(support.nowNs() - start));
    }

    const overhead = complete_ns - serialize_ns - write_ns;

    std.debug.print("Serialization:     {d:>6} ns\n", .{serialize_ns / iterations});
    std.debug.print("I/O:               {d:>6} ns\n", .{write_ns / iterations});
    std.debug.print("Mutex:             {d:>6} ns\n", .{mutex_ns / iterations});
    std.debug.print("Level filtering:   {d:>6} ns\n", .{filter_ns / iterations});
    std.debug.print("Complete pipeline: {d:>6} ns\n", .{complete_ns / iterations});
    std.debug.print("\nEstimated overhead beyond format+write: {d} ns/op\n", .{overhead / iterations});
}

fn formatLogRecord(
    writer: *std.Io.Writer,
    level: zlog.Level,
    message: []const u8,
    fields: []const zlog.Field,
) !usize {
    const start_len = writer.buffered().len;

    try writer.writeByte('{');
    try writer.writeAll("\"level\":\"");
    try writer.writeAll(level.json_string());
    try writer.writeAll("\",\"message\":\"");
    try writeEscapedString(writer, message);
    try writer.writeByte('"');

    for (fields) |field| {
        try writer.writeByte(',');
        try writer.writeByte('"');
        try writeEscapedString(writer, field.key);
        try writer.writeAll("\":");

        switch (field.value) {
            .string => |value| {
                try writer.writeByte('"');
                try writeEscapedString(writer, value);
                try writer.writeByte('"');
            },
            .int => |value| try writer.print("{d}", .{value}),
            .uint => |value| try writer.print("{d}", .{value}),
            .float => |value| try writer.print("{d}", .{value}),
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
            .null => try writer.writeAll("null"),
            .redacted => |value| {
                try writer.writeByte('"');
                try writer.writeAll("[REDACTED:");
                try writer.writeAll(@tagName(value.value_type));
                if (value.hint) |hint| {
                    try writer.writeByte(':');
                    try writeEscapedString(writer, hint);
                }
                try writer.writeAll("]\"");
            },
        }
    }

    try writer.writeAll("}\n");
    return writer.buffered().len - start_len;
}

fn writeEscapedString(writer: *std.Io.Writer, string: []const u8) !void {
    for (string) |char| switch (char) {
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
    };
}
