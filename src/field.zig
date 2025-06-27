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
        const field_result = Field{ .key = field_key, .value = .{ .string = field_string_value } };
        assert(field_result.key.len > 0);
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