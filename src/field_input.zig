const std = @import("std");
const assert = std.debug.assert;

const field = @import("field.zig");

pub fn fieldCount(comptime T: type) comptime_int {
    const type_info = @typeInfo(T);

    if (type_info == .@"struct") {
        return countStructFields(T);
    }

    if (type_info == .pointer and type_info.pointer.size == .one) {
        const pointed_type = type_info.pointer.child;
        const pointed_info = @typeInfo(pointed_type);

        if (pointed_info == .@"struct") {
            return countStructFields(pointed_type);
        }

        if (pointed_info == .array and pointed_info.array.child == field.Field) {
            return pointed_info.array.len;
        }
    }

    if (type_info == .pointer and
        type_info.pointer.size == .slice and
        type_info.pointer.child == field.Field)
    {
        @compileError("Cannot determine field count for slice at compile time");
    }

    @compileError(
        "Expected struct, pointer to struct, or field array, got " ++
            @typeName(T),
    );
}

pub fn structToFields(
    comptime max_fields: u16,
    fields_struct: anytype,
) [fieldCount(@TypeOf(fields_struct))]field.Field {
    const T = @TypeOf(fields_struct);
    const type_info = @typeInfo(T);

    if (type_info != .@"struct") {
        @compileError("Expected struct, got " ++ @typeName(T));
    }

    const field_count = comptime fieldCount(T);
    comptime {
        if (field_count > max_fields) {
            @compileError(
                "Too many flattened fields: " ++
                    std.fmt.comptimePrint("{}", .{field_count}) ++
                    " > max_fields: " ++
                    std.fmt.comptimePrint("{}", .{max_fields}),
            );
        }
    }

    var result: [field_count]field.Field = undefined;
    var field_index: usize = 0;
    appendStructFields("", fields_struct, result[0..], &field_index);

    assert(field_index == result.len);
    return result;
}

pub fn isFieldArray(comptime T: type) bool {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == field.Field) {
                return true;
            }

            if (pointer_info.size == .one) {
                const pointed_info = @typeInfo(pointer_info.child);
                if (pointed_info == .array and pointed_info.array.child == field.Field) {
                    return true;
                }
            }

            return false;
        },
        else => return false,
    }
}

pub fn fieldSliceFromInput(fields_input: anytype) []const field.Field {
    const InputType = @TypeOf(fields_input);
    const input_info = @typeInfo(InputType);

    if (input_info.pointer.size == .slice) {
        return fields_input;
    }

    assert(input_info.pointer.size == .one);

    const pointed_info = @typeInfo(input_info.pointer.child);
    assert(pointed_info == .array);
    assert(pointed_info.array.child == field.Field);
    return fields_input[0..];
}

fn countStructFields(comptime T: type) comptime_int {
    const struct_info = @typeInfo(T);
    assert(struct_info == .@"struct");

    var field_count: comptime_int = 0;
    inline for (struct_info.@"struct".fields) |struct_field| {
        field_count += countValueFields(struct_field.type);
    }

    return field_count;
}

fn countValueFields(comptime T: type) comptime_int {
    if (T == field.Field) {
        return 1;
    }

    const type_info = @typeInfo(T);
    switch (type_info) {
        .@"struct" => return countStructFields(T),
        .pointer => |pointer_info| {
            if (pointer_info.size == .one) {
                const pointed_type = pointer_info.child;
                const pointed_info = @typeInfo(pointed_type);
                if (pointed_info == .@"struct") {
                    return countStructFields(pointed_type);
                }
            }
            return 1;
        },
        else => return 1,
    }
}

fn appendStructFields(
    comptime key_prefix: []const u8,
    fields_struct: anytype,
    target: []field.Field,
    field_index: *usize,
) void {
    const struct_info = @typeInfo(@TypeOf(fields_struct));
    assert(struct_info == .@"struct");

    inline for (struct_info.@"struct".fields) |struct_field| {
        const field_value = @field(fields_struct, struct_field.name);
        appendValueField(key_prefix, struct_field.name, field_value, target, field_index);
    }
}

fn appendValueField(
    comptime key_prefix: []const u8,
    comptime field_name: []const u8,
    value: anytype,
    target: []field.Field,
    field_index: *usize,
) void {
    const T = @TypeOf(value);
    if (T == field.Field) {
        appendField(target, field_index, value);
        return;
    }

    const type_info = @typeInfo(T);
    if (type_info == .@"struct") {
        appendStructFields(qualifyKey(key_prefix, field_name), value, target, field_index);
        return;
    }

    if (type_info == .pointer and type_info.pointer.size == .one) {
        const pointed_type = type_info.pointer.child;
        const pointed_info = @typeInfo(pointed_type);
        if (pointed_info == .@"struct") {
            appendStructFields(
                qualifyKey(key_prefix, field_name),
                value.*,
                target,
                field_index,
            );
            return;
        }
    }

    appendField(
        target,
        field_index,
        convertToField(qualifyKey(key_prefix, field_name), value),
    );
}

fn appendField(target: []field.Field, field_index: *usize, field_item: field.Field) void {
    assert(field_index.* < target.len);
    target[field_index.*] = field_item;
    field_index.* += 1;
}

fn qualifyKey(comptime key_prefix: []const u8, comptime field_name: []const u8) []const u8 {
    assert(field_name.len > 0);
    assert(field_name.len < 256);

    if (key_prefix.len == 0) {
        return field_name;
    }

    const qualified_key = std.fmt.comptimePrint("{s}.{s}", .{ key_prefix, field_name });
    comptime {
        assert(qualified_key.len > 0);
        assert(qualified_key.len < 256);
    }
    return qualified_key;
}

fn convertToField(comptime name: []const u8, value: anytype) field.Field {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .pointer => |pointer_info| switch (pointer_info.size) {
            .slice => if (pointer_info.child == u8)
                field.Field.string(name, value)
            else
                @compileError("Unsupported slice type: " ++ @typeName(T)),
            .one => {
                const child_info = @typeInfo(pointer_info.child);
                if (child_info == .array and child_info.array.child == u8) {
                    return field.Field.string(name, value);
                }

                @compileError("Unsupported pointer type: " ++ @typeName(T));
            },
            else => @compileError("Unsupported pointer type: " ++ @typeName(T)),
        },
        .array => |array_info| if (array_info.child == u8)
            field.Field.string(name, &value)
        else
            @compileError("Unsupported array type: " ++ @typeName(T)),
        .int => |int_info| switch (int_info.signedness) {
            .signed => field.Field.int(name, @as(i64, @intCast(value))),
            .unsigned => field.Field.uint(name, @as(u64, @intCast(value))),
        },
        .comptime_int => convertComptimeIntToField(name, value),
        .float => field.Field.float(name, @as(f64, @floatCast(value))),
        .comptime_float => field.Field.float(name, @as(f64, value)),
        .bool => field.Field.boolean(name, value),
        .optional => if (value) |unwrapped_value|
            convertToField(name, unwrapped_value)
        else
            field.Field.null_value(name),
        .null => field.Field.null_value(name),
        else => @compileError(
            "Unsupported field type: " ++ @typeName(T) ++
                " for field '" ++ name ++ "'",
        ),
    };
}

fn convertComptimeIntToField(comptime name: []const u8, comptime value: comptime_int) field.Field {
    if (value < 0) {
        return field.Field.int(name, @as(i64, value));
    }

    if (value <= std.math.maxInt(i64)) {
        return field.Field.int(name, @as(i64, value));
    }

    if (value <= std.math.maxInt(u64)) {
        return field.Field.uint(name, @as(u64, value));
    }

    @compileError(
        "Unsupported comptime integer for field '" ++ name ++
            "': value exceeds u64 range",
    );
}
