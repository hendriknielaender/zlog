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
        output_format: OutputFormat,
        handler: *HandlerType, // Ensure this is a pointer

        const Self = @This();

        pub fn init(_: *std.mem.Allocator, level: Level, outputFormat: OutputFormat, handler: *HandlerType) ZlogError!Self {
            return Self{
                .level = level,
                .output_format = outputFormat,
                .handler = handler, // Store the pointer directly
            };
        }

        pub fn setLevel(self: *Self, new_level: Level) ZlogError!void {
            self.level = new_level;
            return self;
        }

        pub fn info(self: *Self, msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |log_err| {
                std.debug.print("Log error: {}\n", .{log_err});
                return;
            };
        }

        pub fn warn(self: *Self, msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |log_err| {
                std.debug.print("Log error: {}\n", .{log_err});
                return;
            };
        }

        pub fn err(self: *Self, msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |log_err| {
                std.debug.print("Log error: {}\n", .{log_err});
                return;
            };
        }

        pub fn debug(self: *Self, msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |log_err| {
                std.debug.print("Log error: {}\n", .{log_err});
                return;
            };
        }

        pub fn trace(self: *Self, msg: []const u8, kv: ?[]const KeyValue) void {
            self.log(msg, kv) catch |log_err| {
                std.debug.print("Log error: {}\n", .{log_err});
                return;
            };
        }

        pub fn log(self: *Self, msg: []const u8, kv: ?[]const KeyValue) anyerror!void {
            // Debug print to show the handler's address
            //std.debug.print("Logger: Logging with Logger instance at address {}\n", .{@intFromPtr(self)}); // Updated line

            if (self.output_format == OutputFormat.JSON) {
                const log_msg = LogRecord{ .level = self.level, .msg = msg, .kv = kv };
                const serialized_msg = json.serializeLogMessage(log_msg) catch |json_err| {
                    std.debug.print("Error serializing log message: {}\n", .{json_err});
                    return error.HandlerFailure;
                };

                // Pass the serialized message slice directly
                try self.handler.log(self.level, serialized_msg, null);
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
