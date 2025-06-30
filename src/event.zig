const std = @import("std");
const assert = std.debug.assert;
const trace_mod = @import("trace.zig");
const field = @import("field.zig");
const config = @import("config.zig");

pub const LogEvent = struct {
    level_str: [8]u8,
    message: []const u8,
    fields: []const field.Field,

    trace_id_hex: [32]u8,
    span_id_hex: [16]u8,
    parent_span_hex: ?[16]u8,

    timestamp_ms: u64,
    thread_id: u32,
    sampled: bool,

    pub fn init(
        log_level: config.Level,
        log_message: []const u8,
        log_fields: []const field.Field,
        trace_ctx: trace_mod.TraceContext,
    ) LogEvent {
        assert(@intFromEnum(log_level) <= @intFromEnum(config.Level.fatal));
        assert(log_message.len > 0);
        assert(log_message.len < 64 * 1024);
        assert(log_fields.len <= 64);
        assert(!trace_mod.is_all_zero_id(trace_ctx.trace_id[0..]));

        var level_str_buf: [8]u8 = undefined;
        const level_name = log_level.string();
        @memcpy(level_str_buf[0..level_name.len], level_name);
        @memset(level_str_buf[level_name.len..], ' ');

        const timestamp_ms: u64 = @intCast(@max(0, std.time.milliTimestamp()));
        const thread_id_current: u32 = @intCast(std.Thread.getCurrentId());

        const event_result = LogEvent{
            .level_str = level_str_buf,
            .message = log_message,
            .fields = log_fields,
            .trace_id_hex = trace_ctx.trace_id_hex,
            .span_id_hex = trace_ctx.span_id_hex,
            .parent_span_hex = trace_ctx.parent_span_hex,
            .timestamp_ms = timestamp_ms,
            .thread_id = thread_id_current,
            .sampled = trace_ctx.trace_flags.sampled,
        };

        assert(event_result.message.len > 0);
        assert(event_result.timestamp_ms > 0);
        return event_result;
    }
};

const testing = std.testing;

test "LogEvent.init creates valid event" {
    const trace_ctx = trace_mod.TraceContext.init(true);
    const fields = [_]field.Field{
        field.Field.string("key", "value"),
        field.Field.int("count", 42),
    };

    const event = LogEvent.init(.info, "Test message", &fields, trace_ctx);

    try testing.expectEqualStrings("Test message", event.message);
    try testing.expect(event.fields.len == 2);
    try testing.expect(event.sampled == true);
    try testing.expect(event.timestamp_ms > 0);
    try testing.expect(event.thread_id > 0);
    try testing.expect(event.trace_id_hex.len == 32);
    try testing.expect(event.span_id_hex.len == 16);
}

test "LogEvent level string formatting" {
    const trace_ctx = trace_mod.TraceContext.init(false);
    const event = LogEvent.init(.debug, "Debug test", &.{}, trace_ctx);

    const level_str = std.mem.sliceTo(&event.level_str, ' ');
    try testing.expectEqualStrings("DEBUG", level_str);
}
