// test.zig
const std = @import("std");
const Logger = @import("logger.zig").Logger;
const Level = @import("level.zig").Level;
const LogHandler = @import("handler.zig").LogHandler;
const kv = @import("kv.zig");
const OutputFormat = @import("logger.zig").OutputFormat;

test "Logging different types" {
    var handler = LogHandler{};
    var logger = Logger(LogHandler){
        .level = Level.Info,
        .outputFormat = OutputFormat.PlainText,
        .handler = handler,
    };

    try logger.info("This is an info message.", null);
    var kv_pair = kv.kv("key", "value");
    try logger.err("This is an error message.", &[_]kv.KeyValue{kv_pair});
}

pub fn main() !void {}
