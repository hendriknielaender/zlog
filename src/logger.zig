const std = @import("std");
const Level = @import("level.zig").Level;
const KeyValue = @import("kv.zig").KeyValue;
const ZlogError = @import("errors.zig").ZlogError;
const json = @import("json.zig");

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
        handler: *HandlerType, // Ensure this is a pointer

        pub fn init(_: *std.mem.Allocator, level: Level, outputFormat: OutputFormat, handler: *HandlerType) ZlogError!Logger(HandlerType) {
            return Logger(HandlerType){
                .level = level,
                .outputFormat = outputFormat,
                .handler = handler, // Store the pointer directly
            };
        }

        pub fn setLevel(self: *Logger(HandlerType), newLevel: Level) ZlogError!void {
            if (!std.meta.enumsHaveMember(Level, newLevel)) {
                return error.InvalidLevel;
            }
            self.level = newLevel;
            return self;
        }

        pub fn info(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |logErr| {
                std.debug.print("Log error: {}\n", .{logErr});
                return;
            };
        }

        pub fn warn(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |logErr| {
                std.debug.print("Log error: {}\n", .{logErr});
                return;
            };
        }

        pub fn err(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |logErr| {
                std.debug.print("Log error: {}\n", .{logErr});
                return;
            };
        }

        pub fn debug(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |logErr| {
                std.debug.print("Log error: {}\n", .{logErr});
                return;
            };
        }

        pub fn trace(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |logErr| {
                std.debug.print("Log error: {}\n", .{logErr});
                return;
            };
        }

        pub fn log(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) anyerror!void {
            // Debug print to show the handler's address
            //std.debug.print("Logger: Logging with Logger instance at address {}\n", .{@intFromPtr(self)}); // Updated line

            if (self.outputFormat == OutputFormat.JSON) {
                const logMsg = LogRecord{ .level = self.level, .msg = msg, .kv = kv };
                const serializedMsg = json.serializeLogMessage(logMsg) catch |JsonErr| {
                    std.debug.print("Error serializing log message: {}\n", .{JsonErr});
                    return error.HandlerFailure;
                };

                // Pass the serialized message slice directly
                try self.handler.log(self.level, serializedMsg, null);
            } else {
                // Handle non-JSON formats as before
                if (kv) |keyValues| {
                    // Use 'try' as self.handler.log can return an error
                    try self.handler.log(self.level, msg, keyValues);
                } else {
                    // Use 'try' as self.handler.log can return an error
                    try self.handler.log(self.level, msg, null);
                }
            }
        }
    };
}
