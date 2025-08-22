const std = @import("std");
const assert = std.debug.assert;

pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        boolean: bool,
        null: void,
        redacted: RedactedValue,
    };

    pub const RedactedValue = struct {
        value_type: RedactedType,
        hint: ?[]const u8,
    };

    pub const RedactedType = enum {
        string,
        int,
        uint,
        float,
        any,
    };

    pub fn string(field_key: []const u8, field_string_value: []const u8) Field {
        assert(field_key.len > 0);
        assert(field_key.len < 256);
        assert(field_string_value.len < 1024 * 1024);
        assert(@TypeOf(field_key) == []const u8);
        assert(@TypeOf(field_string_value) == []const u8);

        const field_result = Field{ .key = field_key, .value = .{ .string = field_string_value } };
        assert(field_result.key.len > 0);
        assert(field_result.value == .string);
        return field_result;
    }

    pub fn int(field_key: []const u8, field_int_value: i64) Field {
        assert(field_key.len > 0);
        assert(field_key.len < 256);
        assert(field_int_value >= std.math.minInt(i64));
        assert(field_int_value <= std.math.maxInt(i64));
        const field_result = Field{ .key = field_key, .value = .{ .int = field_int_value } };
        assert(field_result.key.len > 0);
        return field_result;
    }

    pub fn uint(field_key: []const u8, field_uint_value: u64) Field {
        assert(field_key.len > 0);
        assert(field_key.len < 256);
        assert(field_uint_value <= std.math.maxInt(u64));
        const field_result = Field{ .key = field_key, .value = .{ .uint = field_uint_value } };
        assert(field_result.key.len > 0);
        assert(field_result.value.uint == field_uint_value);
        return field_result;
    }

    pub fn float(field_key: []const u8, field_float_value: f64) Field {
        assert(field_key.len > 0);
        assert(field_key.len < 256);
        assert(!std.math.isNan(field_float_value));
        assert(!std.math.isInf(field_float_value));
        const field_result = Field{ .key = field_key, .value = .{ .float = field_float_value } };
        assert(field_result.key.len > 0);
        assert(!std.math.isNan(field_result.value.float));
        return field_result;
    }

    pub fn boolean(field_key: []const u8, field_bool_value: bool) Field {
        assert(field_key.len > 0);
        assert(field_key.len < 256);
        assert(@TypeOf(field_bool_value) == bool);
        const field_result = Field{ .key = field_key, .value = .{ .boolean = field_bool_value } };
        assert(field_result.key.len > 0);
        assert(@TypeOf(field_result.value.boolean) == bool);
        return field_result;
    }

    pub fn null_value(field_key: []const u8) Field {
        assert(field_key.len > 0);
        assert(field_key.len < 256);
        const field_result = Field{ .key = field_key, .value = .{ .null = {} } };
        assert(field_result.key.len > 0);
        assert(field_result.value == .null);
        return field_result;
    }
};

const testing = std.testing;

test "Field.string creates valid string field" {
    const field = Field.string("test_key", "test_value");
    try testing.expectEqualStrings("test_key", field.key);
    try testing.expectEqualStrings("test_value", field.value.string);
    try testing.expect(field.value == .string);
}

test "Field.int creates valid int field" {
    const field = Field.int("count", -42);
    try testing.expectEqualStrings("count", field.key);
    try testing.expect(field.value.int == -42);
    try testing.expect(field.value == .int);

    const max_field = Field.int("max", std.math.maxInt(i64));
    try testing.expect(max_field.value.int == std.math.maxInt(i64));

    const min_field = Field.int("min", std.math.minInt(i64));
    try testing.expect(min_field.value.int == std.math.minInt(i64));
}

test "Field.uint creates valid uint field" {
    const field = Field.uint("size", 42);
    try testing.expectEqualStrings("size", field.key);
    try testing.expect(field.value.uint == 42);
    try testing.expect(field.value == .uint);

    const max_field = Field.uint("max", std.math.maxInt(u64));
    try testing.expect(max_field.value.uint == std.math.maxInt(u64));

    const zero_field = Field.uint("zero", 0);
    try testing.expect(zero_field.value.uint == 0);
}

test "Field.float creates valid float field" {
    const field = Field.float("ratio", 3.14159);
    try testing.expectEqualStrings("ratio", field.key);
    try testing.expect(field.value.float == 3.14159);
    try testing.expect(field.value == .float);

    const negative_field = Field.float("negative", -2.5);
    try testing.expect(negative_field.value.float == -2.5);

    const zero_field = Field.float("zero", 0.0);
    try testing.expect(zero_field.value.float == 0.0);
}

test "Field.boolean creates valid boolean field" {
    const true_field = Field.boolean("active", true);
    try testing.expectEqualStrings("active", true_field.key);
    try testing.expect(true_field.value.boolean == true);
    try testing.expect(true_field.value == .boolean);

    const false_field = Field.boolean("inactive", false);
    try testing.expectEqualStrings("inactive", false_field.key);
    try testing.expect(false_field.value.boolean == false);
    try testing.expect(false_field.value == .boolean);
}

test "Field.null_value creates valid null field" {
    const field = Field.null_value("empty");
    try testing.expectEqualStrings("empty", field.key);
    try testing.expect(field.value == .null);
}

test "Field value union type discrimination" {
    const string_field = Field.string("str", "value");
    const int_field = Field.int("int", 42);
    const uint_field = Field.uint("uint", 42);
    const float_field = Field.float("float", 3.14);
    const bool_field = Field.boolean("bool", true);
    const null_field = Field.null_value("null");

    try testing.expect(string_field.value == .string);
    try testing.expect(int_field.value == .int);
    try testing.expect(uint_field.value == .uint);
    try testing.expect(float_field.value == .float);
    try testing.expect(bool_field.value == .boolean);
    try testing.expect(null_field.value == .null);
}

test "Field key length constraints" {
    const valid_field = Field.string("a", "value");
    try testing.expect(valid_field.key.len == 1);

    const long_key = "a" ** 255;
    const long_key_field = Field.string(long_key, "value");
    try testing.expect(long_key_field.key.len == 255);
}
