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

const testing = std.testing;

test "RedactionConfig init and deinit" {
    var config = RedactionConfig.init(testing.allocator);
    defer config.deinit();

    try testing.expect(config.count() == 0);
}

test "RedactionConfig addKey and shouldRedact" {
    var config = RedactionConfig.init(testing.allocator);
    defer config.deinit();

    try config.addKey("password");
    try config.addKey("secret");

    try testing.expect(config.shouldRedact("password"));
    try testing.expect(config.shouldRedact("secret"));
    try testing.expect(!config.shouldRedact("username"));
    try testing.expect(config.count() == 2);
}

test "RedactionConfig multiple keys" {
    var config = RedactionConfig.init(testing.allocator);
    defer config.deinit();

    const keys = [_][]const u8{ "api_key", "token", "auth", "credential" };
    for (keys) |key| {
        try config.addKey(key);
    }

    try testing.expect(config.count() == 4);
    for (keys) |key| {
        try testing.expect(config.shouldRedact(key));
    }

    try testing.expect(!config.shouldRedact("public_data"));
}

test "RedactionOptions default values" {
    const options = RedactionOptions{};
    try testing.expect(options.redacted_fields.len == 0);
}

test "RedactionOptions with fields" {
    const options = RedactionOptions{
        .redacted_fields = &.{ "password", "secret" },
    };
    try testing.expect(options.redacted_fields.len == 2);
    try testing.expectEqualStrings("password", options.redacted_fields[0]);
    try testing.expectEqualStrings("secret", options.redacted_fields[1]);
}
