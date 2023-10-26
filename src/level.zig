pub const Level = enum {
    Debug,
    Info,
    Warning,
    Error,
    Fatal,

    pub fn toInt(self: Level) u8 {
        return @intFromEnum(self);
    }

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .Debug => "Debug",
            .Info => "Info",
            .Warning => "Warning",
            .Error => "Error",
            .Fatal => "Fatal",
        };
    }
};
