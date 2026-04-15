const std = @import("std");

pub const config = @import("config.zig");
const field_mod = @import("field.zig");
pub const trace = @import("trace.zig");
pub const correlation = @import("correlation.zig");
pub const redaction = @import("redaction.zig");
pub const event = @import("event.zig");
pub const logger = @import("logger.zig");
pub const otel = @import("otel.zig");
pub const EventLoop = @import("event_loop.zig").EventLoop;
pub const otel_logger = @import("otel_logger.zig");
pub const otlp_exporter = @import("otlp_exporter.zig");
pub const semantic_conventions = @import("semantic_conventions.zig");

pub const Config = config.Config;
pub const Level = config.Level;
pub const Field = field_mod.Field;

pub const TraceContext = trace.TraceContext;
pub const TraceFlags = trace.TraceFlags;
pub const TraceError = trace.TraceError;

pub const TaskContext = correlation.TaskContext;
pub const Span = correlation.Span;
pub const getCurrentTaskContext = correlation.getCurrentTaskContext;
pub const setTaskContext = correlation.setTaskContext;
pub const createChildTaskContext = correlation.createChildTaskContext;

pub const RedactionOptions = redaction.RedactionOptions;
pub const RedactionConfig = redaction.RedactionConfig;

pub const LogEvent = event.LogEvent;

pub const Logger = logger.Logger;
pub const LoggerWithRedaction = logger.LoggerWithRedaction;

pub const OTelConfig = otel.OTelConfig;
pub const OTelLogger = otel_logger.OTelLogger;
pub const OTelLoggerWithRedaction = otel_logger.OTelLoggerWithRedaction;
pub const Resource = otel.Resource;
pub const InstrumentationScope = otel.InstrumentationScope;
pub const LogRecord = otel.LogRecord;
pub const SeverityNumber = otel.SeverityNumber;
pub const OTLPExporter = otlp_exporter.OTLPExporter;
pub const SemanticConventions = semantic_conventions.SemanticConventions;
pub const SemConv = semantic_conventions.OTel;
pub const CommonFields = semantic_conventions.CommonFields;

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn default(allocator: std.mem.Allocator) !Logger(.{ .async_mode = true }) {
    return Logger(.{ .async_mode = true }).initAsyncOwnedStderr(allocator, defaultIo());
}

pub fn defaultWithEventLoop(
    event_loop: *EventLoop,
    allocator: std.mem.Allocator,
) !Logger(.{ .async_mode = true }) {
    return Logger(.{ .async_mode = true }).initAsyncOwnedStderrWithIo(allocator, event_loop.io());
}

pub fn loggerWithConfig(
    comptime custom_config: Config,
    output_writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) !Logger(custom_config) {
    if (custom_config.async_mode) {
        return Logger(custom_config).initAsync(output_writer, allocator);
    }
    return Logger(custom_config).init(output_writer);
}

pub fn loggerWithConfigAndEventLoop(
    comptime custom_config: Config,
    output_writer: *std.Io.Writer,
    event_loop: *EventLoop,
    allocator: std.mem.Allocator,
) !Logger(custom_config) {
    if (custom_config.async_mode) {
        return Logger(custom_config).initAsyncWithEventLoop(output_writer, event_loop, allocator);
    }
    return Logger(custom_config).init(output_writer);
}

pub fn loggerWithRedaction(comptime redaction_options: RedactionOptions) LoggerWithRedaction(.{}, redaction_options) {
    return LoggerWithRedaction(.{}, redaction_options).initOwnedStderrWithRedaction(
        std.heap.page_allocator,
        defaultIo(),
        null,
    ) catch @panic("failed to initialize redacted default logger");
}

pub fn otelLogger(allocator: std.mem.Allocator) !OTelLogger(.{ .base_config = .{ .async_mode = true } }) {
    return OTelLogger(.{ .base_config = .{ .async_mode = true } }).initAsyncOwnedStderr(allocator, defaultIo());
}

pub fn otelLoggerWithEventLoop(
    event_loop: *EventLoop,
    allocator: std.mem.Allocator,
) !OTelLogger(.{ .base_config = .{ .async_mode = true } }) {
    return OTelLogger(.{ .base_config = .{ .async_mode = true } }).initAsyncOwnedStderrWithIo(
        allocator,
        event_loop.io(),
    );
}

pub fn otelLoggerWithConfig(
    comptime otel_config: OTelConfig,
    event_loop: *EventLoop,
    allocator: std.mem.Allocator,
) !OTelLogger(otel_config) {
    if (!otel_config.base_config.async_mode) {
        @compileError("otelLoggerWithConfig requires async_mode = true in the base config");
    }
    return OTelLogger(otel_config).initAsyncOwnedStderrWithIo(allocator, event_loop.io());
}

pub const generateTraceId = trace.generate_trace_id;
pub const generateSpanId = trace.generate_span_id;
pub const isAllZeroId = trace.is_all_zero_id;
pub const bytesToHex = trace.bytes_to_hex_lowercase;

pub const field = field_mod.Field;

const testing = std.testing;

test "sync logger integration" {
    var sink_buffer: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    var log = Logger(.{}).init(&sink);
    defer log.deinit();

    log.info("Test message", .{
        .key1 = "value1",
        .key2 = @as(i64, 42),
    });

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"Test message\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"key1\":\"value1\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"key2\":42") != null);
}

test "async logger integration" {
    var sink_buffer: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    var log = try Logger(.{ .async_mode = true }).initAsync(&sink, testing.allocator);
    defer log.deinit();

    log.info("Async test", .{ .kind = "integration" });
    try log.runEventLoopUntilDone();

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"Async test\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"kind\":\"integration\"") != null);
}

test "runtime redaction integration" {
    var sink_buffer: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    var redaction_storage: [4][]const u8 = undefined;
    var redaction_cfg = RedactionConfig.init(&redaction_storage);
    defer redaction_cfg.deinit();
    try redaction_cfg.addKey("password");

    var log = Logger(.{}).initWithRedaction(&sink, &redaction_cfg);
    defer log.deinit();

    log.info("User login", .{
        .username = "alice",
        .password = "secret123",
    });

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, output, "secret123") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[REDACTED:string]") != null);
}
