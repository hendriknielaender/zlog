const std = @import("std");
const Level = @import("level.zig").Level;
const KeyValue = @import("kv.zig").KeyValue;
const ZlogError = @import("errors.zig").ZlogError;

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

        pub fn init(_: *std.mem.Allocator, level: Level, outputFormat: OutputFormat, handler: HandlerType) ZlogError!Logger(HandlerType) {
            return Logger(HandlerType){
                .level = level,
                .outputFormat = outputFormat,
                .handler = handler,
            };
        }

        pub fn setLevel(self: *Logger(HandlerType), newLevel: Level) ZlogError!void {
            if (!std.meta.enumsHaveMember(Level, newLevel)) {
                return error.InvalidLevel;
            }
            self.level = newLevel;
            return self;
        }

        pub fn info(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) ZlogError!void {
            if (kv) |keyValues| {
                try self.log(Level.Info, msg, keyValues);
            } else {
                try self.log(Level.Info, msg, null);
            }
        }

        pub fn warn(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) ZlogError!void {
            if (kv) |keyValues| {
                try self.log(Level.Warn, msg, keyValues);
            } else {
                try self.log(Level.Warn, msg, null);
            }
        }

        pub fn err(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) ZlogError!void {
            if (kv) |keyValues| {
                try self.log(Level.Error, msg, keyValues);
            } else {
                try self.log(Level.Error, msg, null);
            }
        }

        pub fn debug(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) ZlogError!void {
            if (kv) |keyValues| {
                try self.log(Level.Debug, msg, keyValues);
            } else {
                try self.log(Level.Debug, msg, null);
            }
        }

        pub fn trace(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) ZlogError!void {
            if (kv) |keyValues| {
                try self.log(Level.Trace, msg, keyValues);
            } else {
                try self.log(Level.Trace, msg, null);
            }
        }

        pub fn log(self: *Logger(HandlerType), msg: []const u8, kv: ?[]const KeyValue) ZlogError!void {
            if (kv) |keyValues| {
                // Handle structured logging with key-values
                self.handler.log(Level.Info, msg, keyValues) catch {
                    return error.HandlerFailure;
                };
            } else {
                // Handle simple logging without key-values
                self.handler.log(Level.Info, msg, null) catch {
                    return error.HandlerFailure;
                };
            }
        }
    };
}
