pub const Level = enum {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Fatal,

    pub fn toString(self: Level) []const u8 {
        return @tagName(self);
    }
};
