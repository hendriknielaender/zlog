const Level = @import("level.zig").Level;
const KeyValue = @import("kv.zig").KeyValue;
const LogHandler = @import("handler.zig").LogHandler;

pub const Logger = struct {
    handler: LogHandler,
    min_level: Level,

    pub fn create(handler: LogHandler) Logger {
        return Logger{ .handler = handler, .min_level = Level.Info };
    }

    pub fn setLogLevel(self: *Logger, level: Level) void {
        self.min_level = level;
    }

    pub fn log(self: *Logger, level: Level, msg: []const u8, kv: ?[]const KeyValue) !void {
        if (@intFromEnum(level) >= @intFromEnum(self.min_level)) {
            try self.handler.log(level, msg, kv);
        }
    }
};
