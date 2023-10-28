const std = @import("std");
const Level = @import("level.zig").Level;
const KeyValue = @import("kv.zig").KeyValue;

pub const LogHandler = struct {
    pub fn levelToString(level: Level) []const u8 {
        return switch (level) {
            .Trace => "Trace",
            .Debug => "Debug",
            .Info => "Info",
            .Warn => "Warn",
            .Error => "Error",
            .Fatal => "Fatal",
        };
    }

    pub fn log(_: *LogHandler, level: Level, msg: []const u8, kv: ?[]const KeyValue) !void {
        var buffer: [256]u8 = undefined;
        const level_str = levelToString(level);
        std.debug.print("{s}: {s}\n", .{ level_str, msg });
        if (kv) |values| {
            for (values) |entry| {
                const valueString = switch (entry.value) {
                    .String => entry.value.String,
                    .Int => try std.fmt.bufPrint(&buffer, "{}", .{entry.value.Int}),
                    .Float => try std.fmt.bufPrint(&buffer, "{}", .{entry.value.Float}),
                };
                std.debug.print("{s}={s}\n", .{ entry.key, valueString });
            }
        }
    }
};

pub const FileHandler = struct {
    // ... file-specific fields ...

    pub fn log(_: *FileHandler, _: Level, _: []const u8, _: ?[]const KeyValue) !void {
        return error.NotImplemented;
    }

    pub fn rotate(_: *FileHandler) !void {
        return error.NotImplemented;
    }
};

pub const NetworkHandler = struct {
    // ... network-specific fields ...

    pub fn log(_: *NetworkHandler, _: Level, _: []const u8, _: ?[]const KeyValue) !void {
        return error.NotImplemented;
    }
};

pub const AsyncLogHandler = struct {
    // ... fields for queue, worker thread, etc. ...

    pub fn log(_: *AsyncLogHandler, _: Level, _: []const u8, _: ?[]const KeyValue) !void {
        // ... enqueue log message for processing by a separate worker thread ...
        return error.NotImplemented;
    }
};
