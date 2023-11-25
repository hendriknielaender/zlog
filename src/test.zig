// test.zig
const std = @import("std");
const Logger = @import("logger.zig").Logger;
const Level = @import("level.zig").Level;
const LogHandler = @import("handler.zig").LogHandler;
const kv = @import("kv.zig");
const OutputFormat = @import("logger.zig").OutputFormat;

var globalAllocator = std.heap.page_allocator;

fn setupLogger(comptime HandlerType: type, logLevel: Level, format: OutputFormat, handler: *HandlerType) !Logger(HandlerType) {
    return Logger(HandlerType).init(&globalAllocator, logLevel, format, handler);
}

test "Benchmark different log levels" {
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
    const startSync = std.time.milliTimestamp();
    logger.info("Synchronous log message", null);
    const endSync = std.time.milliTimestamp();

    // Asynchronous Logging
    const startAsync = std.time.milliTimestamp();
    //logger.asyncLog("Asynchronous log message");
    const endAsync = std.time.milliTimestamp();

    std.debug.print("Synchronous Logging took {} ms\n", .{endSync - startSync});
    std.debug.print("Not Implemented - Asynchronous Logging took {} ms\n", .{endAsync - startAsync});
}

const MockLogHandler = struct {
    capturedOutput: std.ArrayList(u8),

    pub fn log(self: *MockLogHandler, _: Level, msg: []const u8, _: ?[]const kv.KeyValue) anyerror!void {
        //std.debug.print("Before appending, capturedOutput length: {}\n", .{self.capturedOutput.items.len});
        try self.capturedOutput.appendSlice(msg);
        //std.debug.print("After appending, capturedOutput length: {}\n", .{self.capturedOutput.items.len});
        //std.debug.print("Captured message: {s}\n", .{msg});
    }
};

test "JSON Logging Test" {
    var allocator = std.heap.page_allocator;
    var mockHandler = MockLogHandler{ .capturedOutput = std.ArrayList(u8).init(allocator) };
    defer mockHandler.capturedOutput.deinit();

    //std.debug.print("Test: Created MockLogHandler at address {}\n", .{@intFromPtr(&mockHandler)}); // Debug print

    var logger = try Logger(MockLogHandler).init(&allocator, Level.Info, OutputFormat.JSON, &mockHandler);
    //std.debug.print("Test: Created Logger at address {}\n", .{@intFromPtr(&logger)}); // Debug print

    const kvPairs = &[_]kv.KeyValue{
        kv.KeyValue{ .key = "key1", .value = kv.Value{ .String = "value1" } },
        kv.KeyValue{ .key = "key2", .value = kv.Value{ .Int = 42 } },
        kv.KeyValue{ .key = "key3", .value = kv.Value{ .Float = 3.14 } },
    };

    logger.info("Test message", kvPairs);

    //std.debug.print("MockLogHandler: capturedOutput length = {}\n", .{mockHandler.capturedOutput.items.len}); // Debug print
    const loggedJson = mockHandler.capturedOutput.items;

    //std.debug.print("MockLogHandler: loggedJson = {s}\n", .{loggedJson}); // Debug line

    try std.testing.expectEqualStrings("{\"level\": \"Info\", \"message\": \"Test message\", \"key1\": \"value1\", \"key2\": 42, \"key3\": 3.14}", loggedJson);
}

pub fn main() !void {}
