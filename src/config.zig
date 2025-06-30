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

const testing = std.testing;

test "Level.string returns correct strings" {
    try testing.expectEqualStrings("TRACE", Level.trace.string());
    try testing.expectEqualStrings("DEBUG", Level.debug.string());
    try testing.expectEqualStrings("INFO", Level.info.string());
    try testing.expectEqualStrings("WARN", Level.warn.string());
    try testing.expectEqualStrings("ERROR", Level.err.string());
    try testing.expectEqualStrings("FATAL", Level.fatal.string());
}

test "Level.json_string returns correct JSON strings" {
    try testing.expectEqualStrings("Trace", Level.trace.json_string());
    try testing.expectEqualStrings("Debug", Level.debug.json_string());
    try testing.expectEqualStrings("Info", Level.info.json_string());
    try testing.expectEqualStrings("Warn", Level.warn.json_string());
    try testing.expectEqualStrings("Error", Level.err.json_string());
    try testing.expectEqualStrings("Fatal", Level.fatal.json_string());
}

test "Level enum ordering" {
    try testing.expect(@intFromEnum(Level.trace) < @intFromEnum(Level.debug));
    try testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.info));
    try testing.expect(@intFromEnum(Level.info) < @intFromEnum(Level.warn));
    try testing.expect(@intFromEnum(Level.warn) < @intFromEnum(Level.err));
    try testing.expect(@intFromEnum(Level.err) < @intFromEnum(Level.fatal));
}

test "Config default values" {
    const config = Config{};
    try testing.expect(config.level == .info);
    try testing.expect(config.max_fields == 32);
    try testing.expect(config.buffer_size == 4096);
    try testing.expect(config.async_mode == false);
    try testing.expect(config.async_queue_size == 65536);
    try testing.expect(config.batch_size == 256);
    try testing.expect(config.enable_logging == true);
    try testing.expect(config.enable_simd == true);
}

test "Config custom values" {
    const config = Config{
        .level = .debug,
        .max_fields = 64,
        .buffer_size = 8192,
        .async_mode = true,
        .async_queue_size = 32768,
        .batch_size = 128,
        .enable_logging = false,
        .enable_simd = false,
    };

    try testing.expect(config.level == .debug);
    try testing.expect(config.max_fields == 64);
    try testing.expect(config.buffer_size == 8192);
    try testing.expect(config.async_mode == true);
    try testing.expect(config.async_queue_size == 32768);
    try testing.expect(config.batch_size == 128);
    try testing.expect(config.enable_logging == false);
    try testing.expect(config.enable_simd == false);
}
