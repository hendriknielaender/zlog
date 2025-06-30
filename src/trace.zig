const std = @import("std");
const assert = std.debug.assert;

const hex_chars_lower = "0123456789abcdef";

pub const TraceError = error{
    InvalidLength,
    InvalidVersion,
    InvalidTraceId,
    InvalidParentId,
    InvalidFlags,
    InvalidFormat,
    InvalidHexChar,
    AllZeroId,
};

pub const TraceFlags = packed struct {
    sampled: bool,
    reserved_1: bool = false,
    reserved_2: bool = false,
    reserved_3: bool = false,
    reserved_4: bool = false,
    reserved_5: bool = false,
    reserved_6: bool = false,
    reserved_7: bool = false,

    pub fn fromU8(flags_byte: u8) TraceFlags {
        assert(flags_byte <= 255);
        return @bitCast(flags_byte);
    }

    pub fn toU8(self: TraceFlags) u8 {
        const flags_byte: u8 = @bitCast(self);
        assert(flags_byte <= 255);
        return flags_byte;
    }

    pub fn sampled_only(is_sampled: bool) TraceFlags {
        assert(@TypeOf(is_sampled) == bool);
        return TraceFlags{ .sampled = is_sampled };
    }
};

pub const TraceContext = struct {
    version: u8,
    trace_id: [16]u8,
    parent_id: [8]u8,
    trace_flags: TraceFlags,

    trace_id_hex: [32]u8,
    span_id_hex: [16]u8,
    parent_span_hex: ?[16]u8,

    pub fn init(sampling_decision: bool) TraceContext {
        assert(@TypeOf(sampling_decision) == bool);

        const trace_id_generated = generate_trace_id();
        const parent_id_generated = generate_span_id();
        const flags_created = TraceFlags.sampled_only(sampling_decision);

        var trace_id_hexadecimal_buffer: [32]u8 = undefined;
        var span_id_hexadecimal_buffer: [16]u8 = undefined;

        _ = bytes_to_hex_lowercase(&trace_id_generated, &trace_id_hexadecimal_buffer) catch
            @panic("hex conversion failed with correct buffer size");
        _ = bytes_to_hex_lowercase(&parent_id_generated, &span_id_hexadecimal_buffer) catch
            @panic("hex conversion failed with correct buffer size");
        const trace_context_result = TraceContext{
            .version = 0x00,
            .trace_id = trace_id_generated,
            .parent_id = parent_id_generated,
            .trace_flags = flags_created,
            .trace_id_hex = trace_id_hexadecimal_buffer,
            .span_id_hex = span_id_hexadecimal_buffer,
            .parent_span_hex = null,
        };

        assert(trace_context_result.version == 0x00);
        assert(!is_all_zero_id(trace_context_result.trace_id[0..]));
        assert(!is_all_zero_id(trace_context_result.parent_id[0..]));
        return trace_context_result;
    }

    pub fn createChild(self: *const TraceContext, child_sampling: bool) TraceContext {
        assert(self.version == 0x00);
        assert(!is_all_zero_id(self.trace_id[0..]));
        assert(@TypeOf(child_sampling) == bool);

        const child_parent_id = generate_span_id();
        const child_flags = TraceFlags.sampled_only(child_sampling);

        var child_span_hex_buf: [16]u8 = undefined;
        var parent_span_hex_buf: [16]u8 = undefined;

        _ = bytes_to_hex_lowercase(&child_parent_id, &child_span_hex_buf) catch @panic("hex conversion failed with correct buffer size");
        _ = bytes_to_hex_lowercase(&self.parent_id, &parent_span_hex_buf) catch @panic("hex conversion failed with correct buffer size");

        const child_trace_context = TraceContext{
            .version = self.version,
            .trace_id = self.trace_id,
            .parent_id = child_parent_id,
            .trace_flags = child_flags,
            .trace_id_hex = self.trace_id_hex,
            .span_id_hex = child_span_hex_buf,
            .parent_span_hex = parent_span_hex_buf,
        };

        assert(std.mem.eql(u8, &child_trace_context.trace_id, &self.trace_id));
        assert(!std.mem.eql(u8, &child_trace_context.parent_id, &self.parent_id));
        assert(!is_all_zero_id(child_trace_context.parent_id[0..]));
        return child_trace_context;
    }
};

pub fn generate_trace_id() [16]u8 {
    var trace_id_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&trace_id_bytes);

    if (is_all_zero_id(trace_id_bytes[0..])) {
        trace_id_bytes[15] = 0x01;
    }

    assert(!is_all_zero_id(trace_id_bytes[0..]));
    assert(trace_id_bytes.len == 16);
    return trace_id_bytes;
}

pub fn generate_span_id() [8]u8 {
    var span_id_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&span_id_bytes);

    if (is_all_zero_id(span_id_bytes[0..])) {
        span_id_bytes[7] = 0x01;
    }

    assert(!is_all_zero_id(span_id_bytes[0..]));
    assert(span_id_bytes.len == 8);
    return span_id_bytes;
}

pub fn expand_short_to_trace_id(short_id: u64) [16]u8 {
    assert(short_id > 0);

    var trace_id_expanded: [16]u8 = [_]u8{0} ** 16;

    trace_id_expanded[8] = @intCast((short_id >> 56) & 0xFF);
    trace_id_expanded[9] = @intCast((short_id >> 48) & 0xFF);
    trace_id_expanded[10] = @intCast((short_id >> 40) & 0xFF);
    trace_id_expanded[11] = @intCast((short_id >> 32) & 0xFF);
    trace_id_expanded[12] = @intCast((short_id >> 24) & 0xFF);
    trace_id_expanded[13] = @intCast((short_id >> 16) & 0xFF);
    trace_id_expanded[14] = @intCast((short_id >> 8) & 0xFF);
    trace_id_expanded[15] = @intCast(short_id & 0xFF);

    assert(!is_all_zero_id(trace_id_expanded[0..]));
    assert(extract_short_from_trace_id(trace_id_expanded) == short_id);
    return trace_id_expanded;
}

pub fn extract_short_from_trace_id(trace_id: [16]u8) u64 {
    assert(!is_all_zero_id(trace_id[0..]));

    const short_id: u64 = (@as(u64, trace_id[8]) << 56) |
        (@as(u64, trace_id[9]) << 48) |
        (@as(u64, trace_id[10]) << 40) |
        (@as(u64, trace_id[11]) << 32) |
        (@as(u64, trace_id[12]) << 24) |
        (@as(u64, trace_id[13]) << 16) |
        (@as(u64, trace_id[14]) << 8) |
        @as(u64, trace_id[15]);

    assert(short_id > 0 or !is_all_zero_id(trace_id[0..8]));
    return short_id;
}

pub fn should_sample_from_trace_id(trace_id: [16]u8, sample_rate_percent: u8) bool {
    assert(!is_all_zero_id(trace_id[0..]));
    assert(sample_rate_percent <= 100);

    if (sample_rate_percent == 0) return false;
    if (sample_rate_percent == 100) return true;

    const sample_byte = trace_id[15];
    const threshold = (@as(u16, sample_rate_percent) * 256) / 100;

    const should_sample = sample_byte < threshold;
    assert(@TypeOf(should_sample) == bool);
    return should_sample;
}

pub fn is_all_zero_id(id_bytes: []const u8) bool {
    assert(id_bytes.len > 0);
    assert(id_bytes.len <= 16);

    for (id_bytes) |byte_value| {
        if (byte_value != 0) return false;
    }
    return true;
}

pub fn bytes_to_hex_lowercase(bytes_input: []const u8, hexadecimal_buffer: []u8) ![]const u8 {
    assert(bytes_input.len > 0);
    assert(hexadecimal_buffer.len >= bytes_input.len * 2);

    for (bytes_input, 0..) |byte_value, byte_index| {
        const hex_start_index = byte_index * 2;
        hexadecimal_buffer[hex_start_index] = hex_chars_lower[byte_value >> 4];
        hexadecimal_buffer[hex_start_index + 1] = hex_chars_lower[byte_value & 0x0F];
    }

    const hex_result = hexadecimal_buffer[0 .. bytes_input.len * 2];
    assert(hex_result.len == bytes_input.len * 2);
    return hex_result;
}

const testing = std.testing;

test "TraceFlags fromU8 and toU8 conversion" {
    const flags_byte: u8 = 0b00000001;
    const flags = TraceFlags.fromU8(flags_byte);
    try testing.expect(flags.sampled == true);
    try testing.expect(flags.toU8() == flags_byte);
}

test "TraceFlags sampled_only constructor" {
    const sampled_flags = TraceFlags.sampled_only(true);
    try testing.expect(sampled_flags.sampled == true);
    try testing.expect(sampled_flags.reserved_1 == false);

    const unsampled_flags = TraceFlags.sampled_only(false);
    try testing.expect(unsampled_flags.sampled == false);
}

test "TraceContext init creates valid context" {
    const ctx = TraceContext.init(true);
    try testing.expect(ctx.version == 0x00);
    try testing.expect(ctx.trace_flags.sampled == true);
    try testing.expect(!is_all_zero_id(ctx.trace_id[0..]));
    try testing.expect(!is_all_zero_id(ctx.parent_id[0..]));
    try testing.expect(ctx.trace_id_hex.len == 32);
    try testing.expect(ctx.span_id_hex.len == 16);
    try testing.expect(ctx.parent_span_hex == null);
}

test "TraceContext createChild maintains trace_id" {
    const parent_ctx = TraceContext.init(true);
    const child_ctx = parent_ctx.createChild(false);

    try testing.expect(std.mem.eql(u8, &child_ctx.trace_id, &parent_ctx.trace_id));
    try testing.expect(!std.mem.eql(u8, &child_ctx.parent_id, &parent_ctx.parent_id));
    try testing.expect(child_ctx.trace_flags.sampled == false);
    try testing.expect(child_ctx.parent_span_hex != null);
    try testing.expect(!is_all_zero_id(child_ctx.parent_id[0..]));
}

test "generate_trace_id produces valid IDs" {
    const trace_id1 = generate_trace_id();
    const trace_id2 = generate_trace_id();

    try testing.expect(trace_id1.len == 16);
    try testing.expect(trace_id2.len == 16);
    try testing.expect(!is_all_zero_id(trace_id1[0..]));
    try testing.expect(!is_all_zero_id(trace_id2[0..]));
    try testing.expect(!std.mem.eql(u8, &trace_id1, &trace_id2));
}

test "generate_span_id produces valid IDs" {
    const span_id1 = generate_span_id();
    const span_id2 = generate_span_id();

    try testing.expect(span_id1.len == 8);
    try testing.expect(span_id2.len == 8);
    try testing.expect(!is_all_zero_id(span_id1[0..]));
    try testing.expect(!is_all_zero_id(span_id2[0..]));
    try testing.expect(!std.mem.eql(u8, &span_id1, &span_id2));
}

test "expand_short_to_trace_id and extract_short_from_trace_id roundtrip" {
    const short_id: u64 = 0x123456789ABCDEF0;
    const expanded = expand_short_to_trace_id(short_id);
    const extracted = extract_short_from_trace_id(expanded);

    try testing.expect(extracted == short_id);
    try testing.expect(expanded.len == 16);
    try testing.expect(!is_all_zero_id(expanded[0..]));
}

test "should_sample_from_trace_id with different rates" {
    const trace_id = generate_trace_id();

    try testing.expect(should_sample_from_trace_id(trace_id, 0) == false);
    try testing.expect(should_sample_from_trace_id(trace_id, 100) == true);

    const sample_50 = should_sample_from_trace_id(trace_id, 50);
    try testing.expect(@TypeOf(sample_50) == bool);
}

test "is_all_zero_id detects zero arrays" {
    const zero_array = [_]u8{0} ** 16;
    const non_zero_array = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 0 };

    try testing.expect(is_all_zero_id(zero_array[0..]));
    try testing.expect(!is_all_zero_id(non_zero_array[0..]));
}

test "bytes_to_hex_lowercase conversion" {
    const bytes = [_]u8{ 0x00, 0xFF, 0xAB, 0xCD };
    var hex_buffer: [8]u8 = undefined;

    const hex_result = try bytes_to_hex_lowercase(&bytes, &hex_buffer);
    try testing.expectEqualStrings("00ffabcd", hex_result);
    try testing.expect(hex_result.len == 8);
}
