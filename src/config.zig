const std = @import("std");

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn string(self: Level) []const u8 {
        std.debug.assert(@intFromEnum(self) <= @intFromEnum(Level.fatal));
        const level_string = switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
        std.debug.assert(level_string.len > 0);
        std.debug.assert(level_string.len <= 6);
        return level_string;
    }

    pub fn json_string(self: Level) []const u8 {
        std.debug.assert(@intFromEnum(self) <= @intFromEnum(Level.fatal));
        const json_level_string = switch (self) {
            .trace => "Trace",
            .debug => "Debug",
            .info => "Info",
            .warn => "Warn",
            .err => "Error",
            .fatal => "Fatal",
        };
        std.debug.assert(json_level_string.len > 0);
        std.debug.assert(json_level_string.len <= 5);
        return json_level_string;
    }
};

pub const Config = struct {
    level: Level = .info,
    max_fields: u16 = 32,
    buffer_size: u32 = 4096,
    async_mode: bool = false,
    async_queue_size: u32 = 65536,
    batch_size: u32 = 256,
    enable_logging: bool = true,
    enable_simd: bool = true,
};
