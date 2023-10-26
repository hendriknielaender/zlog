const std = @import("std");
const zlog = @import("logger.zig");
const Level = @import("level.zig").Level;
const handler = @import("handler.zig");

test "log at Info level" {
    var logger = zlog.Logger{
        .level = Level.Info,
        .handler = &handler.consoleHandler,
    };
    logger.log(Level.Info, "This is an info message");
}

test "log at Error level" {
    var logger = zlog.Logger{
        .level = Level.Error,
        .handler = &handler.consoleHandler,
    };
    logger.log(Level.Error, "This is an error message");
}
