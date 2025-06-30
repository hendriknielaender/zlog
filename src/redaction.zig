const std = @import("std");
const assert = std.debug.assert;

pub const RedactionOptions = struct {
    redacted_fields: []const []const u8 = &.{},
};

pub const RedactionConfig = struct {
    const Self = @This();

    redacted_keys: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .redacted_keys = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.redacted_keys.deinit();
    }

    pub fn addKey(self: *Self, key: []const u8) !void {
        assert(key.len > 0);
        assert(key.len < 512);
        try self.redacted_keys.put(key, {});
    }

    pub fn shouldRedact(self: *const Self, key: []const u8) bool {
        return self.redacted_keys.contains(key);
    }

    pub fn count(self: *const Self) u32 {
        return @intCast(self.redacted_keys.count());
    }
};
