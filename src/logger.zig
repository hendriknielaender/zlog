const std = @import("std");
const Level = @import("level.zig").Level;
const KeyValue = @import("kv.zig").KeyValue;
pub const OutputFormat = enum { PlainText, JSON };

pub const LogRecord = struct {
    level: Level,
    msg: []const u8,
    kv: ?[]const KeyValue,
};

pub fn Logger(comptime HandlerType: type) type {
    return struct {
        level: Level,
        outputFormat: OutputFormat,
        handler: HandlerType,

        pub fn init(_: *std.mem.Allocator, level: Level, outputFormat: OutputFormat, handler: HandlerType) !@This() {
            // Potential initialization logic, if any.
            return @This(){ .level = level, .outputFormat = outputFormat, .handler = handler };
        }

        pub fn info(self: *@This(), msg: []const u8, kv: ?[]const KeyValue) !void {
            try self.log(Level.Info, msg, kv);
        }

        pub fn err(self: *@This(), msg: []const u8, kv: ?[]const KeyValue) !void {
            try self.log(Level.Error, msg, kv);
        }

        fn log(self: *@This(), level: Level, msg: []const u8, kv: ?[]const KeyValue) !void {
            if (@intFromEnum(level) < @intFromEnum(self.level)) return;
            //try self.handler.log(self.handler, level, msg, kv);
            try self.handler.log(level, msg, kv);
        }
    };
}
