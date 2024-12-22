// test.zig
const std = @import("std");
const Logger = @import("logger.zig").Logger;
const Level = @import("level.zig").Level;
const LogHandler = @import("handler.zig").LogHandler;
const kv = @import("kv.zig");
const OutputFormat = @import("logger.zig").OutputFormat;

var global_allocator = std.heap.page_allocator;

fn setupLogger(comptime HandlerType: type, log_level: Level, format: OutputFormat, handler: *HandlerType) !Logger(HandlerType) {
    return Logger(HandlerType).init(&global_allocator, log_level, format, handler);
}

test "Benchmark different log levels" {
    // do wyp p p
    var handler = LogHandler{};
    var logger = try setupLogger(LogHandler, Level.Info, OutputFormat.PlainText, &handler);

    const start = std.time.milliTimestamp();
    logger.info("This is an info log message", null);
    const end = std.time.milliTimestamp();

    std.debug.print("Info Level Logging took {} ms\n", .{end - start});
}

test "Benchmark Synchronous vs Asynchronous Logging" {
    var handler = LogHandler{};
    var logger = try setupLogger(LogHandler, Level.Error, OutputFormat.PlainText, &handler);

    // Synchronous Logging
    const start_sync = std.time.milliTimestamp();
    logger.info("Synchronous log message", null);
    const end_sync = std.time.milliTimestamp();

    // Asynchronous Logging
    const start_async = std.time.milliTimestamp();
    //logger.asyncLog("Asynchronous log message");
    const end_async = std.time.milliTimestamp();

    std.debug.print("Synchronous Logging took {} ms\n", .{end_sync - start_sync});
    std.debug.print("Not Implemented - Asynchronous Logging took {} ms\n", .{end_async - start_async});
}

const MockLogHandler = struct {
    captured_output: std.ArrayList(u8),

    pub fn log(self: *MockLogHandler, _: Level, msg: []const u8, _: ?[]const kv.KeyValue) anyerror!void {
        //std.debug.print("Before appending, capturedOutput length: {}\n", .{self.capturedOutput.items.len});
        try self.captured_output.appendSlice(msg);
        //std.debug.print("After appending, capturedOutput length: {}\n", .{self.capturedOutput.items.len});
        //std.debug.print("Captured message: {s}\n", .{msg});
    }
};

test "JSON Logging Test" {
    var allocator = std.heap.page_allocator;
    var mock_handler = MockLogHandler{ .captured_output = std.ArrayList(u8).init(allocator) };
    defer mock_handler.captured_output.deinit();

    //std.debug.print("Test: Created MockLogHandler at address {}\n", .{@intFromPtr(&mockHandler)}); // Debug print

    var logger = try Logger(MockLogHandler).init(&allocator, Level.Info, OutputFormat.JSON, &mock_handler);
    //std.debug.print("Test: Created Logger at address {}\n", .{@intFromPtr(&logger)}); // Debug print

    const kv_pairs = &.{
        kv.KeyValue{ .key = "key1", .value = kv.Value{ .String = "value1" } },
        kv.KeyValue{ .key = "key2", .value = kv.Value{ .Int = 42 } },
        kv.KeyValue{ .key = "key3", .value = kv.Value{ .Float = 3.14 } },
    };

    logger.info("Test message", kv_pairs);

    //std.debug.print("MockLogHandler: capturedOutput length = {}\n", .{mockHandler.capturedOutput.items.len}); // Debug print
    const logged_json = mock_handler.captured_output.items;

    //std.debug.print("MockLogHandler: loggedJson = {s}\n", .{loggedJson}); // Debug line

    try std.testing.expectEqualStrings("{\"level\": \"Info\", \"message\": \"Test message\", \"key1\": \"value1\", \"key2\": 42, \"key3\": 3.14}", logged_json);
}

pub fn main() !void {}
