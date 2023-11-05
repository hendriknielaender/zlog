const std = @import("std");

pub fn kv(key: []const u8, value: []const u8) KeyValue {
    return KeyValue{ .key = key, .value = createValue(value) };
}

pub const KeyValue = struct {
    key: []const u8,
    value: Value,
};

pub fn createValue(value: []const u8) Value {
    switch (@TypeOf(value)) {
        []const u8 => return Value{ .String = value },
        i64 => return Value{ .Int = value },
        f64 => return Value{ .Float = value },
        else => {
            @compileError("Unsupported value type: " ++ @typeName(@TypeOf(value)));
        },
    }
}

pub const Value = union(enum) {
    String: []const u8,
    Int: i64,
    Float: f64,
};
