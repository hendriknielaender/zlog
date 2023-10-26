const std = @import("std");
const Level = @import("level.zig").Level;

pub const Handler = fn (level: Level, message: []const u8) void;

pub fn consoleHandler(level: Level, message: []const u8) void {
    std.debug.print("{s}: {s}\n", .{ Level.toString(level), message });
}
