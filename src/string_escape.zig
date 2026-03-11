const std = @import("std");
const config = @import("config.zig");
const testing = std.testing;

const backend_supports_vectors = switch (@import("builtin").zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

pub fn write(comptime cfg: config.Config, writer: *std.Io.Writer, input: []const u8) !void {
    if (comptime cfg.enable_simd) {
        if (comptime backend_supports_vectors) {
            return writeSimd(writer, input);
        }
    }

    return writeScalar(writer, input);
}

fn writeScalar(writer: *std.Io.Writer, input: []const u8) !void {
    std.debug.assert(input.len < 1024 * 1024);

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

fn writeSimd(writer: *std.Io.Writer, input: []const u8) !void {
    std.debug.assert(input.len < 1024 * 1024);

    if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
        return writeSimdVectorized(vector_len, writer, input);
    }

    return writeScalar(writer, input);
}

fn writeSimdVectorized(
    comptime vector_len: comptime_int,
    writer: *std.Io.Writer,
    input: []const u8,
) !void {
    var remaining = input;
    var total_processed: usize = 0;
    var safe_batch_start: usize = 0;

    while (remaining.len >= vector_len) {
        const chunk_bytes = remaining[0..vector_len];
        const chunk: @Vector(vector_len, u8) = chunk_bytes.*;

        if (simdChunkNeedsEscaping(vector_len, chunk)) {
            try writeSimdChunk(
                vector_len,
                writer,
                input,
                chunk_bytes,
                total_processed,
                &safe_batch_start,
            );
        }

        remaining = remaining[vector_len..];
        total_processed += vector_len;
    }

    try writeSimdTail(writer, input, remaining, total_processed, &safe_batch_start);
    try writePendingBatch(writer, input, safe_batch_start, input.len);
}

fn simdChunkNeedsEscaping(
    comptime vector_len: comptime_int,
    chunk: @Vector(vector_len, u8),
) bool {
    const quote_vec: @Vector(vector_len, u8) = @splat('"');
    const backslash_vec: @Vector(vector_len, u8) = @splat('\\');
    const newline_vec: @Vector(vector_len, u8) = @splat('\n');
    const return_vec: @Vector(vector_len, u8) = @splat('\r');
    const tab_vec: @Vector(vector_len, u8) = @splat('\t');
    const backspace_vec: @Vector(vector_len, u8) = @splat(0x08);
    const formfeed_vec: @Vector(vector_len, u8) = @splat(0x0C);
    const space_vec: @Vector(vector_len, u8) = @splat(0x20);

    if (@reduce(.Or, chunk == quote_vec)) return true;
    if (@reduce(.Or, chunk == backslash_vec)) return true;
    if (@reduce(.Or, chunk == newline_vec)) return true;
    if (@reduce(.Or, chunk == return_vec)) return true;
    if (@reduce(.Or, chunk == tab_vec)) return true;
    if (@reduce(.Or, chunk == backspace_vec)) return true;
    if (@reduce(.Or, chunk == formfeed_vec)) return true;
    return @reduce(.Or, chunk < space_vec);
}

fn writeSimdChunk(
    comptime vector_len: comptime_int,
    writer: *std.Io.Writer,
    input: []const u8,
    chunk_bytes: []const u8,
    total_processed: usize,
    safe_batch_start: *usize,
) !void {
    std.debug.assert(chunk_bytes.len == vector_len);

    for (0..vector_len) |index| {
        const input_char = chunk_bytes[index];
        const absolute_index = total_processed + index;

        if (characterNeedsEscaping(input_char)) {
            try writePendingBatch(writer, input, safe_batch_start.*, absolute_index);
            try writeEscapedCharacter(writer, input_char);
            safe_batch_start.* = absolute_index + 1;
        }
    }
}

fn writeSimdTail(
    writer: *std.Io.Writer,
    input: []const u8,
    remaining: []const u8,
    total_processed: usize,
    safe_batch_start: *usize,
) !void {
    for (remaining, 0..) |input_char, index| {
        const absolute_index = total_processed + index;

        if (characterNeedsEscaping(input_char)) {
            try writePendingBatch(writer, input, safe_batch_start.*, absolute_index);
            try writeEscapedCharacter(writer, input_char);
            safe_batch_start.* = absolute_index + 1;
        }
    }
}

fn writePendingBatch(
    writer: *std.Io.Writer,
    input: []const u8,
    batch_start: usize,
    batch_end: usize,
) !void {
    std.debug.assert(batch_start <= batch_end);
    std.debug.assert(batch_end <= input.len);

    if (batch_start < batch_end) {
        try writer.writeAll(input[batch_start..batch_end]);
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

inline fn writeEscapedCharacter(writer: *std.Io.Writer, input_char: u8) !void {
    std.debug.assert(input_char <= 255);

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

const test_output_capacity = 4096;

fn writeScalarBuffered(buffer: []u8, input: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeScalar(&writer, input);
    return writer.buffered();
}

fn writeSimdBuffered(buffer: []u8, input: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeSimd(&writer, input);
    return writer.buffered();
}

fn writeBuffered(
    comptime cfg: config.Config,
    buffer: []u8,
    input: []const u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try write(cfg, &writer, input);
    return writer.buffered();
}

test "string escaping - basic strings without special characters" {
    const test_cases = [_][]const u8{
        "hello world",
        "simple test",
        "no special chars here",
        "1234567890",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    };

    for (test_cases) |test_case| {
        var scalar_storage: [test_output_capacity]u8 = undefined;
        var simd_storage: [test_output_capacity]u8 = undefined;
        const scalar_result = try writeScalarBuffered(&scalar_storage, test_case);
        const simd_result = try writeSimdBuffered(&simd_storage, test_case);

        try testing.expectEqualStrings(test_case, scalar_result);
        try testing.expectEqualStrings(test_case, simd_result);
        try testing.expectEqualStrings(scalar_result, simd_result);
    }
}

test "string escaping - special characters" {
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
        .{
            .input = "mixed\"test\nwith\\special\tchars",
            .expected = "mixed\\\"test\\nwith\\\\special\\tchars",
        },
    };

    for (test_cases) |test_case| {
        var scalar_storage: [test_output_capacity]u8 = undefined;
        var simd_storage: [test_output_capacity]u8 = undefined;
        const scalar_result = try writeScalarBuffered(&scalar_storage, test_case.input);
        const simd_result = try writeSimdBuffered(&simd_storage, test_case.input);

        try testing.expectEqualStrings(test_case.expected, scalar_result);
        try testing.expectEqualStrings(test_case.expected, simd_result);
        try testing.expectEqualStrings(scalar_result, simd_result);
    }
}

test "string escaping - edge cases" {
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
        var scalar_storage: [test_output_capacity]u8 = undefined;
        var simd_storage: [test_output_capacity]u8 = undefined;
        const scalar_result = try writeScalarBuffered(&scalar_storage, test_case.input);
        const simd_result = try writeSimdBuffered(&simd_storage, test_case.input);

        try testing.expectEqualStrings(test_case.expected, scalar_result);
        try testing.expectEqualStrings(test_case.expected, simd_result);
        try testing.expectEqualStrings(scalar_result, simd_result);
    }
}

test "string escaping - long strings with mixed content" {
    const long_input =
        "This is a longer string with \"quotes\", \nnewlines\n, \ttabs\t, " ++
        "and other special chars like \\ backslashes. " ++
        "It should be long enough to test SIMD performance with multiple chunks. " ++
        "Adding more content here: \x01\x02\x03 control chars, more " ++
        "\"quotes\", and \r\n line endings.";

    var scalar_storage: [test_output_capacity]u8 = undefined;
    var simd_storage: [test_output_capacity]u8 = undefined;
    const scalar_result = try writeScalarBuffered(&scalar_storage, long_input);
    const simd_result = try writeSimdBuffered(&simd_storage, long_input);

    try testing.expectEqualStrings(scalar_result, simd_result);
}

test "string escaping - config flag behavior" {
    const test_input = "test with \"quotes\" and \n newlines";

    const config_simd_enabled = config.Config{ .enable_simd = true };
    const config_simd_disabled = config.Config{ .enable_simd = false };

    var no_simd_storage: [test_output_capacity]u8 = undefined;
    var simd_storage: [test_output_capacity]u8 = undefined;
    const result_no_simd = try writeBuffered(
        config_simd_disabled,
        &no_simd_storage,
        test_input,
    );
    const result_with_simd = try writeBuffered(
        config_simd_enabled,
        &simd_storage,
        test_input,
    );

    try testing.expectEqualStrings(result_no_simd, result_with_simd);
    try testing.expectEqualStrings("test with \\\"quotes\\\" and \\n newlines", result_no_simd);
}
