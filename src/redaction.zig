const std = @import("std");
const assert = std.debug.assert;

pub const RedactionOptions = struct {
    redacted_fields: []const []const u8 = &.{},
};

pub const RedactionConfig = struct {
    const Self = @This();

    redacted_keys: [][]const u8,
    redacted_keys_len: u32 = 0,

    pub fn init(redacted_keys_storage: [][]const u8) Self {
        assert(redacted_keys_storage.len <= std.math.maxInt(u32));

        return Self{
            .redacted_keys = redacted_keys_storage,
        };
    }

    pub fn deinit(self: *Self) void {
        self.redacted_keys_len = 0;
    }

    pub fn addKey(self: *Self, key: []const u8) !void {
        assert(key.len > 0);
        assert(key.len < 512);

        if (self.shouldRedact(key)) {
            return;
        }

        if (self.redacted_keys_len == self.redacted_keys.len) {
            return error.OutOfCapacity;
        }

        const write_index: usize = @intCast(self.redacted_keys_len);
        assert(write_index < self.redacted_keys.len);

        self.redacted_keys[write_index] = key;
        self.redacted_keys_len += 1;
    }

    pub fn shouldRedact(self: *const Self, key: []const u8) bool {
        const configured_len: usize = @intCast(self.redacted_keys_len);
        assert(configured_len <= self.redacted_keys.len);

        for (self.redacted_keys[0..configured_len]) |configured_key| {
            if (std.mem.eql(u8, configured_key, key)) {
                return true;
            }
        }

        return false;
    }

    pub fn count(self: *const Self) u32 {
        assert(self.redacted_keys_len <= self.redacted_keys.len);
        return self.redacted_keys_len;
    }
};

const testing = std.testing;

test "RedactionConfig init and deinit" {
    var storage: [4][]const u8 = undefined;
    var config = RedactionConfig.init(&storage);
    defer config.deinit();

    try testing.expect(config.count() == 0);
}

test "RedactionConfig addKey and shouldRedact" {
    var storage: [4][]const u8 = undefined;
    var config = RedactionConfig.init(&storage);
    defer config.deinit();

    try config.addKey("password");
    try config.addKey("secret");

    try testing.expect(config.shouldRedact("password"));
    try testing.expect(config.shouldRedact("secret"));
    try testing.expect(!config.shouldRedact("username"));
    try testing.expect(config.count() == 2);
}

test "RedactionConfig multiple keys" {
    var storage: [8][]const u8 = undefined;
    var config = RedactionConfig.init(&storage);
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
