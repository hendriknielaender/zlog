const std = @import("std");
const config = @import("config.zig");
const testing = std.testing;

const backend_supports_vectors = switch (@import("builtin").zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

pub fn write(comptime cfg: config.Config, writer: anytype, input: []const u8) !void {
    if (comptime cfg.enable_simd and backend_supports_vectors) {
        return writeSimd(writer, input);
    } else {
        return writeScalar(writer, input);
    }
}

fn writeScalar(writer: anytype, input: []const u8) !void {
    std.debug.assert(input.len < 1024 * 1024);
    std.debug.assert(@TypeOf(writer).Error != void);

    var safe_batch_start: u32 = 0;

    for (input, 0..) |current_char, char_index| {
        if (characterNeedsEscaping(current_char)) {
            if (char_index > safe_batch_start) {
                try writer.writeAll(input[safe_batch_start..char_index]);
            }

            try writeEscapedCharacter(writer, current_char);
            safe_batch_start = @intCast(char_index + 1);
        }
    }

    if (safe_batch_start < input.len) {
        try writer.writeAll(input[safe_batch_start..]);
        std.debug.assert(safe_batch_start <= input.len);
    }
}

fn writeSimd(writer: anytype, input: []const u8) !void {
    std.debug.assert(input.len < 1024 * 1024);
    std.debug.assert(@TypeOf(writer).Error != void);

    if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
        var remaining = input;
        var total_processed: usize = 0;

        const quote_vec: @Vector(vector_len, u8) = @splat('"');
        const backslash_vec: @Vector(vector_len, u8) = @splat('\\');
        const newline_vec: @Vector(vector_len, u8) = @splat('\n');
        const return_vec: @Vector(vector_len, u8) = @splat('\r');
        const tab_vec: @Vector(vector_len, u8) = @splat('\t');
        const backspace_vec: @Vector(vector_len, u8) = @splat(0x08);
        const formfeed_vec: @Vector(vector_len, u8) = @splat(0x0C);
        const space_vec: @Vector(vector_len, u8) = @splat(0x20);

        var safe_batch_start: usize = 0;

        while (remaining.len >= vector_len) {
            const chunk: @Vector(vector_len, u8) = remaining[0..vector_len].*;

            const needs_escape = @reduce(.Or, chunk == quote_vec) or
                @reduce(.Or, chunk == backslash_vec) or
                @reduce(.Or, chunk == newline_vec) or
                @reduce(.Or, chunk == return_vec) or
                @reduce(.Or, chunk == tab_vec) or
                @reduce(.Or, chunk == backspace_vec) or
                @reduce(.Or, chunk == formfeed_vec) or
                @reduce(.Or, chunk < space_vec);

            if (needs_escape) {
                for (0..vector_len) |i| {
                    const char = remaining[i];
                    const absolute_index = total_processed + i;

                    if (characterNeedsEscaping(char)) {
                        if (absolute_index > safe_batch_start) {
                            try writer.writeAll(input[safe_batch_start..absolute_index]);
                        }
                        try writeEscapedCharacter(writer, char);
                        safe_batch_start = absolute_index + 1;
                    }
                }
            }

            remaining = remaining[vector_len..];
            total_processed += vector_len;
        }

        for (remaining, 0..) |char, i| {
            const absolute_index = total_processed + i;
            if (characterNeedsEscaping(char)) {
                if (absolute_index > safe_batch_start) {
                    try writer.writeAll(input[safe_batch_start..absolute_index]);
                }
                try writeEscapedCharacter(writer, char);
                safe_batch_start = absolute_index + 1;
            }
        }

        if (safe_batch_start < input.len) {
            try writer.writeAll(input[safe_batch_start..]);
        }
    } else {
        return writeScalar(writer, input);
    }
}

inline fn characterNeedsEscaping(input_char: u8) bool {
    std.debug.assert(input_char <= 255);

    const needs_escaping = switch (input_char) {
        '"', '\\', '\n', '\r', '\t', 0x08, 0x0C => true,
        else => input_char < 0x20,
    };

    std.debug.assert(@TypeOf(needs_escaping) == bool);
    return needs_escaping;
}

inline fn writeEscapedCharacter(writer: anytype, input_char: u8) !void {
    std.debug.assert(input_char <= 255);
    std.debug.assert(@TypeOf(writer).Error != void);

    switch (input_char) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        else => {
            if (input_char < 0x20) {
                try writer.print("\\u{x:0>4}", .{input_char});
            } else {
                try writer.writeByte(input_char);
            }
        },
    }
}

test "string escaping - basic strings without special characters" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const test_cases = [_][]const u8{
        "hello world",
        "simple test",
        "no special chars here",
        "1234567890",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    };

    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();

        try writeScalar(buffer.writer(), test_case);
        const scalar_result = try buffer.toOwnedSlice();
        defer testing.allocator.free(scalar_result);

        buffer.clearRetainingCapacity();
        try writeSimd(buffer.writer(), test_case);
        const simd_result = try buffer.toOwnedSlice();
        defer testing.allocator.free(simd_result);

        try testing.expectEqualStrings(test_case, scalar_result);
        try testing.expectEqualStrings(test_case, simd_result);
        try testing.expectEqualStrings(scalar_result, simd_result);
    }
}

test "string escaping - special characters" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "\"hello\"", .expected = "\\\"hello\\\"" },
        .{ .input = "line\nbreak", .expected = "line\\nbreak" },
        .{ .input = "tab\there", .expected = "tab\\there" },
        .{ .input = "return\rhere", .expected = "return\\rhere" },
        .{ .input = "back\\slash", .expected = "back\\\\slash" },
        .{ .input = "form\x0Cfeed", .expected = "form\\ffeed" },
        .{ .input = "back\x08space", .expected = "back\\bspace" },
        .{ .input = "\x01\x02\x03", .expected = "\\u0001\\u0002\\u0003" },
        .{ .input = "mixed\"test\nwith\\special\tchars", .expected = "mixed\\\"test\\nwith\\\\special\\tchars" },
    };

    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();
        try writeScalar(buffer.writer(), test_case.input);
        const scalar_result = try buffer.toOwnedSlice();
        defer testing.allocator.free(scalar_result);

        buffer.clearRetainingCapacity();
        try writeSimd(buffer.writer(), test_case.input);
        const simd_result = try buffer.toOwnedSlice();
        defer testing.allocator.free(simd_result);

        try testing.expectEqualStrings(test_case.expected, scalar_result);
        try testing.expectEqualStrings(test_case.expected, simd_result);
        try testing.expectEqualStrings(scalar_result, simd_result);
    }
}

test "string escaping - edge cases" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "", .expected = "" },
        .{ .input = "a", .expected = "a" },
        .{ .input = "\"", .expected = "\\\"" },
        .{ .input = "\\", .expected = "\\\\" },
        .{ .input = "\n", .expected = "\\n" },
        .{ .input = "\x00", .expected = "\\u0000" },
        .{ .input = "\x1F", .expected = "\\u001f" },
    };

    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();
        try writeScalar(buffer.writer(), test_case.input);
        const scalar_result = try buffer.toOwnedSlice();
        defer testing.allocator.free(scalar_result);

        buffer.clearRetainingCapacity();
        try writeSimd(buffer.writer(), test_case.input);
        const simd_result = try buffer.toOwnedSlice();
        defer testing.allocator.free(simd_result);

        try testing.expectEqualStrings(test_case.expected, scalar_result);
        try testing.expectEqualStrings(test_case.expected, simd_result);
        try testing.expectEqualStrings(scalar_result, simd_result);
    }
}

test "string escaping - long strings with mixed content" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const long_input = "This is a longer string with \"quotes\", \nnewlines\n, \ttabs\t, and other special chars like \\ backslashes. " ++
        "It should be long enough to test SIMD performance with multiple chunks. " ++
        "Adding more content here: \x01\x02\x03 control chars, more \"quotes\", and \r\n line endings.";

    buffer.clearRetainingCapacity();
    try writeScalar(buffer.writer(), long_input);
    const scalar_result = try buffer.toOwnedSlice();
    defer testing.allocator.free(scalar_result);

    buffer.clearRetainingCapacity();
    try writeSimd(buffer.writer(), long_input);
    const simd_result = try buffer.toOwnedSlice();
    defer testing.allocator.free(simd_result);

    try testing.expectEqualStrings(scalar_result, simd_result);
}

test "string escaping - config flag behavior" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const test_input = "test with \"quotes\" and \n newlines";

    const config_simd_enabled = config.Config{ .enable_simd = true };
    const config_simd_disabled = config.Config{ .enable_simd = false };

    buffer.clearRetainingCapacity();
    try write(config_simd_disabled, buffer.writer(), test_input);
    const result_no_simd = try buffer.toOwnedSlice();
    defer testing.allocator.free(result_no_simd);

    buffer.clearRetainingCapacity();
    try write(config_simd_enabled, buffer.writer(), test_input);
    const result_with_simd = try buffer.toOwnedSlice();
    defer testing.allocator.free(result_with_simd);

    try testing.expectEqualStrings(result_no_simd, result_with_simd);
    try testing.expectEqualStrings("test with \\\"quotes\\\" and \\n newlines", result_no_simd);
}
