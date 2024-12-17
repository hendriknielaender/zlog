const std = @import("std");
const LogMessage = @import("logger.zig").LogRecord;
const Level = @import("level.zig").Level;
const kv = @import("kv.zig");

fn appendFormattedInt(buffer: *std.ArrayList(u8), value: i64) !void {
    var tmpBuf: [20]u8 = undefined; // Buffer for integer formatting
    const formatted = try std.fmt.bufPrint(&tmpBuf, "{}", .{value});
    try buffer.appendSlice(formatted);
}

fn appendFormattedFloat(buffer: *std.ArrayList(u8), value: f64) !void {
    var tmpBuf: [32]u8 = undefined; // Buffer for float formatting
    const formatted = try std.fmt.bufPrint(&tmpBuf, "{d:.2}", .{value});
    try buffer.appendSlice(formatted);
}

fn appendLevel(buffer: *std.ArrayList(u8), level: Level) !void {
    const levelStr = switch (level) {
        .Info => "Info",
        .Warn => "Warn",
        .Error => "Error",
        .Debug => "Debug",
        .Trace => "Trace",
        .Fatal => "Fatal", // Handling the 'Fatal' case
    };
    try buffer.appendSlice(levelStr);
}

pub fn serializeLogMessage(log: LogMessage) ![]u8 {
    var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buffer.deinit();

    try buffer.appendSlice("{\"level\": \"");
    try appendLevel(&buffer, log.level);
    try buffer.appendSlice("\", \"message\": \"");
    try buffer.appendSlice(log.msg);
    try buffer.appendSlice("\"");

    if (log.kv) |kvPairs| {
        for (kvPairs) |pair| {
            try buffer.appendSlice(", \"");
            try buffer.appendSlice(pair.key);
            try buffer.appendSlice("\": ");
            switch (pair.value) {
                .String => |s| {
                    try buffer.appendSlice("\"");
                    try buffer.appendSlice(s);
                    try buffer.appendSlice("\"");
                },
                .Int => |i| try appendFormattedInt(&buffer, i),
                .Float => |f| try appendFormattedFloat(&buffer, f),
                // Add more cases for other types as needed
            }
        }
    }

    try buffer.appendSlice("}");
    return buffer.toOwnedSlice();
}

test "JSON Serialization Test - Level and Message" {
    const logMsg = LogMessage{
        .level = Level.Info,
        .msg = "Test message",
        .kv = &[_]kv.KeyValue{
            kv.KeyValue{ .key = "key1", .value = kv.Value{ .String = "value1" } },
            kv.KeyValue{ .key = "key2", .value = kv.Value{ .Int = 42 } },
            kv.KeyValue{ .key = "key3", .value = kv.Value{ .Float = 3.14 } },
            // Add more key-value pairs as needed
        },
    };

    const serializedMsg = try serializeLogMessage(logMsg);

    try std.testing.expectEqualStrings("{\"level\": \"Info\", \"message\": \"Test message\", \"key1\": \"value1\", \"key2\": 42, \"key3\": 3.14}", serializedMsg);
}
