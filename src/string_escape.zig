const std = @import("std");
const config = @import("config.zig");
const testing = std.testing;

const backend_supports_vectors = switch (@import("builtin").zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

pub fn write(comptime cfg: config.Config, writer: *std.Io.Writer, input: []const u8) !void {
    if (comptime cfg.enable_simd and backend_supports_vectors) {
        return writeSimd(writer, input);
    }
    return writeScalar(writer, input);
}

fn writeScalar(writer: *std.Io.Writer, input: []const u8) !void {
    var safe_batch_start: usize = 0;

    for (input, 0..) |current_char, char_index| {
        if (characterNeedsEscaping(current_char)) {
            if (char_index > safe_batch_start) {
                try writer.writeAll(input[safe_batch_start..char_index]);
            }

            try writeEscapedCharacter(writer, current_char);
            safe_batch_start = char_index + 1;
        }
    }

    if (safe_batch_start < input.len) {
        try writer.writeAll(input[safe_batch_start..]);
    }
}

fn writeSimd(writer: *std.Io.Writer, input: []const u8) !void {
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
        return;
    }

    return writeScalar(writer, input);
}

inline fn characterNeedsEscaping(input_char: u8) bool {
    return switch (input_char) {
        '"', '\\', '\n', '\r', '\t', 0x08, 0x0C => true,
        else => input_char < 0x20,
    };
}

inline fn writeEscapedCharacter(writer: *std.Io.Writer, input_char: u8) !void {
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

fn escapeInto(
    comptime cfg: config.Config,
    buffer: []u8,
    input: []const u8,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try write(cfg, &writer, input);
    return writer.buffered();
}

test "string escaping scalar and simd agree" {
    const input = "mixed\"test\nwith\\special\tchars";
    var scalar_buffer: [256]u8 = undefined;
    var simd_buffer: [256]u8 = undefined;

    var scalar_writer: std.Io.Writer = .fixed(&scalar_buffer);
    var simd_writer: std.Io.Writer = .fixed(&simd_buffer);

    try writeScalar(&scalar_writer, input);
    try writeSimd(&simd_writer, input);

    try testing.expectEqualStrings(scalar_writer.buffered(), simd_writer.buffered());
    try testing.expectEqualStrings("mixed\\\"test\\nwith\\\\special\\tchars", scalar_writer.buffered());
}

test "string escaping handles control characters" {
    const input = "Bell:\x07 Backspace:\x08 Tab:\t Newline:\n Return:\r Escape:\x1B";
    var buffer: [512]u8 = undefined;

    const escaped = try escapeInto(config.Config{}, &buffer, input);
    try testing.expect(std.mem.indexOf(u8, escaped, "\\u0007") != null);
    try testing.expect(std.mem.indexOf(u8, escaped, "\\b") != null);
    try testing.expect(std.mem.indexOf(u8, escaped, "\\t") != null);
    try testing.expect(std.mem.indexOf(u8, escaped, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, escaped, "\\r") != null);
    try testing.expect(std.mem.indexOf(u8, escaped, "\\u001b") != null);
}

test "string escaping respects config flag" {
    const input = "test with \"quotes\" and \n newlines";
    var buffer_no_simd: [256]u8 = undefined;
    var buffer_with_simd: [256]u8 = undefined;

    const escaped_no_simd = try escapeInto(.{ .enable_simd = false }, &buffer_no_simd, input);
    const escaped_with_simd = try escapeInto(.{ .enable_simd = true }, &buffer_with_simd, input);

    try testing.expectEqualStrings(escaped_no_simd, escaped_with_simd);
    try testing.expectEqualStrings("test with \\\"quotes\\\" and \\n newlines", escaped_no_simd);
}
