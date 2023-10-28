const std = @import("std");
const Logger = @import("logger.zig").Logger;
const Level = @import("level.zig").Level;
const LogHandler = @import("handler.zig").LogHandler;
const KeyValue = @import("kv.zig").KeyValue;

test "Logging different types" {
    var handler = LogHandler{};
    var logger = Logger.create(handler);
    try logger.log(Level.Info, "This is an info message.", null);
    var kv = [_]KeyValue{KeyValue{ .key = "key", .value = KeyValue.Value{ .String = "value" } }};
    try logger.log(Level.Error, "This is an error message.", kv[0..]);
}

pub fn main() void {
    _ = @import("std").testing.runTests();
}
