// test.zig
const std = @import("std");
const Logger = @import("logger.zig").Logger;
const Level = @import("level.zig").Level;
const LogHandler = @import("handler.zig").LogHandler;
const kv = @import("kv.zig");
const OutputFormat = @import("logger.zig").OutputFormat;

var globalAllocator = std.heap.page_allocator;

fn setupLogger(comptime HandlerType: type, logLevel: Level, format: OutputFormat, handler: HandlerType) !Logger(HandlerType) {
    return Logger(HandlerType).init(&globalAllocator, logLevel, format, handler);
}

test "Benchmark different log levels" {
    var handler = LogHandler{};
    var logger = try setupLogger(LogHandler, Level.Info, OutputFormat.PlainText, handler);

    const start = std.time.milliTimestamp();
    try logger.log("This is an info log message", null);
    const end = std.time.milliTimestamp();

    std.debug.print("Info Level Logging took {} ms\n", .{end - start});
}

test "Benchmark Synchronous vs Asynchronous Logging" {
    var handler = LogHandler{};
    var logger = try setupLogger(LogHandler, Level.Error, OutputFormat.PlainText, handler);

    // Synchronous Logging
    const startSync = std.time.milliTimestamp();
    try logger.log("Synchronous log message", null);
    const endSync = std.time.milliTimestamp();

    // Asynchronous Logging
    const startAsync = std.time.milliTimestamp();
    //logger.asyncLog("Asynchronous log message");
    const endAsync = std.time.milliTimestamp();

    std.debug.print("Synchronous Logging took {} ms\n", .{endSync - startSync});
    std.debug.print("Not Implemented - Asynchronous Logging took {} ms\n", .{endAsync - startAsync});
}

pub fn main() !void {}
