const std = @import("std");
const Level = @import("level.zig").Level;
const KeyValue = @import("kv.zig").KeyValue;
const builtin = @import("builtin");

pub const LogHandler = struct {
    pub fn log(_: *LogHandler, level: Level, msg: []const u8, kv: ?[]const KeyValue) !void {
        var buffer: [256]u8 = undefined;
        const level_str = level.toString();
        if (!builtin.is_test) {
            try std.io.getStdOut().writer().print("{s}: {s}\n", .{ level_str, msg });
        }
        //std.debug.print("{s}: {s}\n", .{ level_str, msg });
        if (kv) |values| {
            for (values) |entry| {
                const value_string = switch (entry.value) {
                    .String => entry.value.String,
                    .Int => try std.fmt.bufPrint(&buffer, "{}", .{entry.value.Int}),
                    .Float => try std.fmt.bufPrint(&buffer, "{}", .{entry.value.Float}),
                };
                std.debug.print("{s}={s}\n", .{ entry.key, value_string });
            }
        }
    }
};

pub const FileHandler = struct {
    // ... file-specific fields ...

    pub fn log(_: *FileHandler, _: Level, _: []const u8, _: ?[]const KeyValue) !void {
        @compileError("not implemented");
    }

    pub fn rotate(_: *FileHandler) !void {
        @compileError("not implemented");
    }
};

pub const NetworkHandler = struct {
    // ... network-specific fields ...

    pub fn log(_: *NetworkHandler, _: Level, _: []const u8, _: ?[]const KeyValue) !void {
        @compileError("not implemented");
    }
};

pub const AsyncLogHandler = struct {
    // ... fields for queue, worker thread, etc. ...

    pub fn log(_: *AsyncLogHandler, _: Level, _: []const u8, _: ?[]const KeyValue) !void {
        // ... enqueue log message for processing by a separate worker thread ...
        @compileError("not implemented");
    }
};
