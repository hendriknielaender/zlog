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

    pub fn initLegacy(
        log_level: config.Level,
        log_message: []const u8,
        log_fields: []const field.Field,
        task_context_id: u64,
        span_context_id: ?u64,
    ) LogEvent {
        assert(@intFromEnum(log_level) <= @intFromEnum(config.Level.fatal));
        assert(log_message.len > 0);
        assert(log_message.len < 64 * 1024);
        assert(log_fields.len <= 64);
        assert(task_context_id >= 1);
        assert(span_context_id == null or span_context_id.? >= 1);

        const trace_id_expanded = trace_mod.expand_short_to_trace_id(task_context_id);
        const parent_id_generated = trace_mod.generate_span_id();

        var trace_id_hex_buf: [32]u8 = undefined;
        var span_id_hex_buf: [16]u8 = undefined;

        _ = trace_mod.bytes_to_hex_lowercase(&trace_id_expanded, &trace_id_hex_buf) catch @panic("hex conversion failed with correct buffer size");
        _ = trace_mod.bytes_to_hex_lowercase(&parent_id_generated, &span_id_hex_buf) catch @panic("hex conversion failed with correct buffer size");

        var parent_span_hex_opt: ?[16]u8 = null;
        if (span_context_id) |sid| {
            var span_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &span_bytes, sid, .big);
            var parent_hex_buf: [16]u8 = undefined;
            _ = trace_mod.bytes_to_hex_lowercase(&span_bytes, &parent_hex_buf) catch @panic("hex conversion failed with correct buffer size");
            parent_span_hex_opt = parent_hex_buf;
        }

        const fake_trace_ctx = trace_mod.TraceContext{
            .version = 0x00,
            .trace_id = trace_id_expanded,
            .parent_id = parent_id_generated,
            .trace_flags = trace_mod.TraceFlags.sampled_only(false),
            .trace_id_hex = trace_id_hex_buf,
            .span_id_hex = span_id_hex_buf,
            .parent_span_hex = parent_span_hex_opt,
        };

        return init(log_level, log_message, log_fields, fake_trace_ctx);
    }
};
