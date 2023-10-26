const std = @import("std");
const Logger = @import("logger.zig").Logger;
const Level = @import("level.zig").Level;
const handler = @import("handler.zig");

pub fn main() void {
    var logger = Logger{ .level = Level.Info, .handler = &handler.consoleHandler }; // Adjust this line
    logger.log(Level.Info, "This is an info message");
    logger.log(Level.Error, "This is an error message");
}
