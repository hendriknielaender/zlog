const Level = @import("level.zig").Level;
const Handler = @import("handler.zig").Handler;

pub const Logger = struct {
    level: Level,
    handler: *const Handler,

    pub fn log(self: *Logger, level: Level, message: []const u8) void {
        if (level.toInt() >= self.level.toInt()) {
            self.handler(level, message);
        }
    }
};
