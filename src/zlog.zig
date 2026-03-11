const std = @import("std");

pub const config = @import("config.zig");
const field_mod = @import("field.zig");
pub const trace = @import("trace.zig");
pub const correlation = @import("correlation.zig");
pub const redaction = @import("redaction.zig");
pub const event = @import("event.zig");
pub const logger = @import("logger.zig");
pub const otel = @import("otel.zig");
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
pub const clearTaskContext = correlation.clearTaskContext;
pub const createChildTaskContext = correlation.createChildTaskContext;

pub const RedactionOptions = redaction.RedactionOptions;
pub const RedactionConfig = redaction.RedactionConfig;

pub const LogEvent = event.LogEvent;

pub const Logger = logger.Logger;
pub const LoggerWithRedaction = logger.LoggerWithRedaction;

// OpenTelemetry support
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

pub fn default(
    output_writer: anytype,
    async_state: *Logger(.{ .async_mode = true }).AsyncState,
) Logger(.{ .async_mode = true }) {
    const async_logger_result = Logger(.{ .async_mode = true }).initAsync(output_writer, async_state);
    std.debug.assert(@intFromEnum(async_logger_result.level) <= @intFromEnum(Level.fatal));
    return async_logger_result;
}

pub fn loggerWithRedaction(
    comptime redaction_options: RedactionOptions,
    output_writer: anytype,
) LoggerWithRedaction(.{}, redaction_options) {
    const logger_result = LoggerWithRedaction(.{}, redaction_options).init(output_writer);
    std.debug.assert(@intFromEnum(logger_result.level) <= @intFromEnum(Level.fatal));
    return logger_result;
}

pub fn otelLogger(
    output_writer: anytype,
    async_state: *OTelLogger(.{ .base_config = .{ .async_mode = true } }).AsyncState,
) OTelLogger(.{ .base_config = .{ .async_mode = true } }) {
    const async_logger_result = OTelLogger(
        .{ .base_config = .{ .async_mode = true } },
    ).initAsync(output_writer, async_state);
    return async_logger_result;
}

/// Create an OpenTelemetry-compliant logger with custom configuration (async only).
pub fn otelLoggerWithConfig(
    comptime otel_config: OTelConfig,
    output_writer: anytype,
    async_state: *OTelLogger(otel_config).AsyncState,
) OTelLogger(otel_config) {
    comptime {
        if (!otel_config.base_config.async_mode) {
            @compileError(
                "otelLoggerWithConfig() requires async_mode = true in config. " ++
                    "Async is the only supported mode for the ergonomic API.",
            );
        }
    }

    const async_logger_result = OTelLogger(otel_config).initAsync(output_writer, async_state);
    return async_logger_result;
}

pub const generateTraceId = trace.generate_trace_id;
pub const generateSpanId = trace.generate_span_id;
pub const isAllZeroId = trace.is_all_zero_id;
pub const bytesToHex = trace.bytes_to_hex_lowercase;

// For backward compatibility
pub const field = field_mod.Field;

const testing = std.testing;
const test_output_capacity = 64 * 1024;

const TestOutput = struct {
    storage: [test_output_capacity]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn init() TestOutput {
        var output = TestOutput{};
        output.writer = std.Io.Writer.fixed(&output.storage);
        return output;
    }

    fn written(self: *TestOutput) []const u8 {
        return self.writer.buffered();
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.containsAtLeast(u8, haystack, 1, needle));
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(!std.mem.containsAtLeast(u8, haystack, 1, needle));
}

test "JSON serialization with basic message" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);
    log.info("Test message", &.{});

    try expectContains(buffer.written(), "\"level\":\"INFO\"");
    try expectContains(buffer.written(), "\"msg\":\"Test message\"");
    try expectContains(buffer.written(), "\"trace\":");
    try expectContains(buffer.written(), "\"span\":");
}

test "JSON serialization with multiple fields" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);
    log.info("Test message", &.{
        Field.string("key1", "value1"),
        Field.int("key2", 42),
        Field.float("key3", 3.14),
    });

    try expectContains(buffer.written(), "\"level\":\"INFO\"");
    try expectContains(buffer.written(), "\"msg\":\"Test message\"");
    try expectContains(buffer.written(), "\"key1\":\"value1\"");
    try expectContains(buffer.written(), "\"key2\":42");
    try expectContains(buffer.written(), "\"key3\":3.14");
    try expectContains(buffer.written(), "\"trace\":");
}

test "JSON escaping in strings" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);
    log.info("Message with \"quotes\" and \\backslash\\", &.{
        Field.string("special", "Line\nbreak\tand\rcarriage"),
    });

    try expectContains(buffer.written(), "\"level\":\"INFO\"");
    try expectContains(buffer.written(), "\"msg\":\"Message with");
    try expectContains(buffer.written(), "\"special\":");
    try expectContains(buffer.written(), "\"trace\":");
}

test "flush writes buffered file output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("log.json", .{ .read = true });
    defer file.close();

    var file_buffer: [512]u8 = undefined;
    var file_writer = file.writer(&file_buffer);

    var log = Logger(.{}).init(&file_writer);
    defer log.deinit();

    log.info("Buffered message", .{
        .service = "writer-test",
    });
    try log.flush();

    try file.seekTo(0);

    var read_buffer: [512]u8 = undefined;
    const read_count = try file.readAll(&read_buffer);
    try testing.expect(read_count > 0);
    try expectContains(read_buffer[0..read_count], "\"Buffered message\"");
    try expectContains(read_buffer[0..read_count], "\"writer-test\"");
}

test "All field types" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);
    log.info("All types", &.{
        Field.string("str", "hello"),
        Field.int("int", -42),
        Field.uint("uint", 42),
        Field.float("float", 3.14159),
        Field.boolean("bool_true", true),
        Field.boolean("bool_false", false),
        Field.null_value("null_field"),
    });

    try expectContains(buffer.written(), "\"level\":\"INFO\"");
    try expectContains(buffer.written(), "\"msg\":\"All types\"");
    try expectContains(buffer.written(), "\"str\":\"hello\"");
    try expectContains(buffer.written(), "\"int\":-42");
    try expectContains(buffer.written(), "\"uint\":42");
    try expectContains(buffer.written(), "\"float\":3.14159");
    try expectContains(buffer.written(), "\"bool_true\":true");
    try expectContains(buffer.written(), "\"bool_false\":false");
    try expectContains(buffer.written(), "\"null_field\":null");
}

test "Level filtering" {
    var buffer = TestOutput.init();
    var log = Logger(.{ .level = .warn }).init(&buffer.writer);

    log.trace("Trace message", &.{});
    log.debug("Debug message", &.{});
    log.info("Info message", &.{});

    log.warn("Warning message", &.{});
    log.err("Error message", &.{});
    log.fatal("Fatal message", &.{});

    try expectContains(buffer.written(), "\"level\":\"WARN\"");
    try expectContains(buffer.written(), "\"msg\":\"Warning message\"");
    try expectContains(buffer.written(), "\"level\":\"ERROR\"");
    try expectContains(buffer.written(), "\"msg\":\"Error message\"");
    try expectContains(buffer.written(), "\"level\":\"FATAL\"");
    try expectContains(buffer.written(), "\"msg\":\"Fatal message\"");
    try expectNotContains(buffer.written(), "\"msg\":\"Trace message\"");
    try expectNotContains(buffer.written(), "\"msg\":\"Debug message\"");
    try expectNotContains(buffer.written(), "\"msg\":\"Info message\"");
}

test "Empty fields array" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);
    log.info("Empty fields", &.{});

    try expectContains(buffer.written(), "\"level\":\"INFO\"");
    try expectContains(buffer.written(), "\"msg\":\"Empty fields\"");
    try expectContains(buffer.written(), "\"trace\":");
}

test "Field limit enforcement" {
    var buffer = TestOutput.init();
    var log = Logger(.{ .max_fields = 3 }).init(&buffer.writer);

    var fields: [5]Field = undefined;
    inline for (0..5) |i| {
        fields[i] = Field.int(std.fmt.comptimePrint("field{}", .{i}), @as(i64, @intCast(i)));
    }

    log.info("Limited fields", &fields);

    const output = buffer.written();
    try expectContains(output, "\"field0\":0");
    try expectContains(output, "\"field1\":1");
    try expectContains(output, "\"field2\":2");
}

test "Control characters escaping" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);

    const test_string =
        "Bell:\x07 Backspace:\x08 Tab:\t Newline:\n FormFeed:\x0C " ++
        "Return:\r Escape:\x1B";
    log.info("Control test", &.{
        Field.string("control_chars", test_string),
    });

    const output = buffer.written();
    try expectContains(output, "\\u0007");
    try expectContains(output, "\\b");
    try expectContains(output, "\\t");
    try expectContains(output, "\\n");
    try expectContains(output, "\\f");
    try expectContains(output, "\\r");
    try expectContains(output, "\\u001b");
}

test "All log levels" {
    var buffer = TestOutput.init();
    var log = Logger(.{ .level = .trace }).init(&buffer.writer);

    log.trace("Trace msg", &.{});
    log.debug("Debug msg", &.{});
    log.info("Info msg", &.{});
    log.warn("Warn msg", &.{});
    log.err("Error msg", &.{});
    log.fatal("Fatal msg", &.{});

    const output = buffer.written();
    try expectContains(output, "\"level\":\"TRACE\"");
    try expectContains(output, "\"level\":\"DEBUG\"");
    try expectContains(output, "\"level\":\"INFO\"");
    try expectContains(output, "\"level\":\"WARN\"");
    try expectContains(output, "\"level\":\"ERROR\"");
    try expectContains(output, "\"level\":\"FATAL\"");
}

test "Large message within buffer" {
    var buffer = TestOutput.init();
    var log = Logger(.{ .buffer_size = 1024 }).init(&buffer.writer);

    const large_msg = "A" ** 500;
    log.info(large_msg, &.{});

    const output = buffer.written();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, large_msg));
}

test "Escaped overflow increments dropped metrics" {
    var buffer = TestOutput.init();
    var log = Logger(.{ .buffer_size = 256 }).init(&buffer.writer);

    const oversized_message = "\"" ** 180;
    log.info(oversized_message, .{});

    const metrics = log.getMetrics();
    try testing.expect(metrics.logs_written == 0);
    try testing.expect(metrics.logs_dropped == 1);
    try testing.expect(metrics.write_failures == 0);
    try testing.expect(buffer.written().len == 0);
}

test "Unicode characters" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);

    log.info("Unicode test", &.{
        Field.string("emoji", "🦎"),
        Field.string("chinese", "你好"),
        Field.string("special", "café"),
    });

    const output = buffer.written();
    try expectContains(output, "🦎");
    try expectContains(output, "你好");
    try expectContains(output, "café");
}

test "Span lifecycle keeps task context in sync" {
    correlation.clearTaskContext();
    defer correlation.clearTaskContext();

    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);

    const request_span = log.spanStart("request", .{ .endpoint = "/checkout" });
    var current_context = correlation.getCurrentTaskContext();
    try testing.expect(current_context.currentSpan() != null);

    const db_span = log.spanStart("db", .{ .table = "orders" });
    current_context = correlation.getCurrentTaskContext();
    try testing.expect(current_context.currentSpan() != null);
    try testing.expect(db_span.parent_id.? == request_span.id);

    log.spanEnd(db_span, .{ .rows = 1 });
    current_context = correlation.getCurrentTaskContext();
    try testing.expect(current_context.currentSpan() != null);
    try testing.expect(std.mem.eql(
        u8,
        &current_context.currentSpan().?,
        &request_span.getSpanIdBytes(),
    ));

    log.spanEnd(request_span, .{ .status_code = 200 });
    current_context = correlation.getCurrentTaskContext();
    try testing.expect(current_context.currentSpan() == null);
}

test "Default logger creation" {
    var output = TestOutput.init();
    var async_state = Logger(.{ .async_mode = true }).AsyncState{};
    var log = default(&output.writer, &async_state);
    defer log.deinit();
}

test "Custom configuration" {
    var buffer = TestOutput.init();
    const custom_config = Config{
        .level = .debug,
        .max_fields = 10,
        .buffer_size = 2048,
    };

    var log = Logger(custom_config).init(&buffer.writer);
    log.debug("Custom config test", &.{});

    try expectContains(buffer.written(), "\"level\":\"DEBUG\"");
}

test "Field convenience functions" {
    var buffer = TestOutput.init();
    var log = Logger(.{}).init(&buffer.writer);

    log.info("Field test", &.{
        Field.string("name", "test"),
        Field.int("count", -123),
        Field.uint("size", 456),
        Field.float("ratio", 1.23),
        Field.boolean("active", true),
        Field.null_value("empty"),
    });

    const output = buffer.written();
    try expectContains(output, "\"name\":\"test\"");
    try expectContains(output, "\"count\":-123");
    try expectContains(output, "\"size\":456");
    try expectContains(output, "\"ratio\":1.23");
    try expectContains(output, "\"active\":true");
    try expectContains(output, "\"empty\":null");
}

test "Async logger creation and basic functionality" {
    var buffer = TestOutput.init();
    var async_state = Logger(.{ .async_mode = true }).AsyncState{};
    var async_log = Logger(.{ .async_mode = true }).initAsync(&buffer.writer, &async_state);
    defer async_log.deinit();

    async_log.info("Async test message", &.{
        Field.string("type", "async"),
        Field.int("count", 1),
    });

    async_log.drain();
    try async_log.flush();

    try testing.expect(buffer.written().len > 0);
    try expectContains(buffer.written(), "\"msg\":\"Async test message\"");
    try expectContains(buffer.written(), "\"type\":\"async\"");
}

test "Async logger with high volume" {
    var buffer = TestOutput.init();
    var async_state = Logger(.{ .async_mode = true }).AsyncState{};
    var async_log = Logger(.{ .async_mode = true }).initAsync(&buffer.writer, &async_state);
    defer async_log.deinit();

    for (0..10) |i| {
        async_log.info("Bulk message", &.{
            Field.uint("index", i),
            Field.string("thread", "test"),
        });
    }

    async_log.drain();
    try async_log.flush();

    try testing.expect(buffer.written().len > 0);
    try testing.expect(std.mem.containsAtLeast(
        u8,
        buffer.written(),
        10,
        "\"msg\":\"Bulk message\"",
    ));
}

test "LogEvent creation" {
    const ctx = TraceContext.init(true);
    const evt = LogEvent.init(
        .info,
        "Test event",
        &.{Field.string("key", "value")},
        ctx,
    );

    try testing.expect(evt.message.len == 10);
    try testing.expect(evt.fields.len == 1);
    try testing.expect(evt.sampled == true);
}

test "Async mode configuration validation" {
    var buffer = TestOutput.init();
    const async_config = Config{
        .async_mode = true,
        .async_queue_size = 1024,
        .batch_size = 16,
    };

    var async_state = Logger(async_config).AsyncState{};
    var async_log = Logger(async_config).initAsync(&buffer.writer, &async_state);
    defer async_log.deinit();

    try testing.expect(async_log.getMetrics().queue_size == 0);
}

test "Default async logger creation" {
    var buffer = TestOutput.init();
    var default_state = Logger(.{ .async_mode = true }).AsyncState{};
    var async_log = default(&buffer.writer, &default_state);
    async_log.deinit();

    var async_state = Logger(.{ .async_mode = true }).AsyncState{};
    async_log = Logger(.{ .async_mode = true }).initAsync(&buffer.writer, &async_state);
    defer async_log.deinit();

    async_log.info("Default async test", &.{});
    try async_log.flush();
}

test "OTel logger with custom config instantiates" {
    const otel_config = comptime OTelConfig{
        .base_config = .{
            .async_mode = true,
            .level = .debug,
        },
        .resource = Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = InstrumentationScope.init("test-logger"),
    };

    var async_state = OTelLogger(otel_config).AsyncState{};
    var output = TestOutput.init();

    var otel_log = otelLoggerWithConfig(
        otel_config,
        &output.writer,
        &async_state,
    );
    defer otel_log.deinit();

    otel_log.info("async otel", .{ .component = "instantiation_test" });
    otel_log.drain();
    try otel_log.flush();
    try expectContains(output.written(), "\"async otel\"");
}

test "RedactionConfig context pattern" {
    var log_output = TestOutput.init();
    var redaction_storage: [8][]const u8 = undefined;
    var redaction_cfg = RedactionConfig.init(&redaction_storage);
    defer redaction_cfg.deinit();

    try redaction_cfg.addKey("password");
    try redaction_cfg.addKey("apiKey");

    var log = Logger(.{}).initWithRedaction(&log_output.writer, &redaction_cfg);

    log.info("User action", &.{
        Field.string("user", "alice"),
        Field.string("password", "super_secret"),
    });

    try testing.expect(std.mem.indexOf(u8, log_output.written(), "alice") != null);
    try testing.expect(std.mem.indexOf(u8, log_output.written(), "super_secret") == null);
    try testing.expect(std.mem.indexOf(u8, log_output.written(), "[REDACTED:string]") != null);
}

test "Context-based redaction in action" {
    var redaction_storage: [8][]const u8 = undefined;
    var redaction_cfg = RedactionConfig.init(&redaction_storage);
    defer redaction_cfg.deinit();

    try redaction_cfg.addKey("password");
    try redaction_cfg.addKey("api_key");
    try redaction_cfg.addKey("ssn");

    var log_output = TestOutput.init();
    var log = Logger(.{}).initWithRedaction(&log_output.writer, &redaction_cfg);

    log.info("User login", &.{
        Field.string("username", "alice"),
        Field.string("password", "secret123"),
        Field.string("ip", "192.168.1.1"),
    });

    const output = log_output.written();
    try testing.expect(std.mem.indexOf(u8, output, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, output, "192.168.1.1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "secret123") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[REDACTED:string]") != null);
}

test "Compile-time redaction - zero cost filtering" {
    const CompileTimeLogger = LoggerWithRedaction(.{}, .{
        .redacted_fields = &.{ "password", "api_key", "secret" },
    });

    var log_output = TestOutput.init();
    var log = CompileTimeLogger.init(&log_output.writer);

    log.info("Security test", &.{
        Field.string("username", "bob"),
        Field.string("password", "compile_time_secret"),
        Field.string("api_key", "ct_api_key_123"),
        Field.string("email", "bob@example.com"),
    });

    const output = log_output.written();
    try testing.expect(std.mem.indexOf(u8, output, "bob") != null);
    try testing.expect(std.mem.indexOf(u8, output, "bob@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, output, "compile_time_secret") == null);
    try testing.expect(std.mem.indexOf(u8, output, "ct_api_key_123") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[REDACTED:string]") != null);
}

test "Hybrid redaction - compile-time + runtime" {
    var redaction_storage: [8][]const u8 = undefined;
    var runtime_redaction = RedactionConfig.init(&redaction_storage);
    defer runtime_redaction.deinit();
    try runtime_redaction.addKey("runtime_secret");
    try runtime_redaction.addKey("dynamic_key");

    const HybridLogger = LoggerWithRedaction(.{}, .{
        .redacted_fields = &.{ "password", "api_key" },
    });

    var log_output = TestOutput.init();
    var log = HybridLogger.initWithRedaction(&log_output.writer, &runtime_redaction);

    log.info("Hybrid test", &.{
        Field.string("username", "charlie"),
        Field.string("password", "compile_time_filtered"),
        Field.string("api_key", "compile_time_api"),
        Field.string("runtime_secret", "runtime_filtered"),
        Field.string("dynamic_key", "runtime_dynamic"),
        Field.string("visible_field", "not_redacted"),
    });

    const output = log_output.written();
    try testing.expect(std.mem.indexOf(u8, output, "charlie") != null);
    try testing.expect(std.mem.indexOf(u8, output, "not_redacted") != null);
    try testing.expect(std.mem.indexOf(u8, output, "compile_time_filtered") == null);
    try testing.expect(std.mem.indexOf(u8, output, "compile_time_api") == null);
    try testing.expect(std.mem.indexOf(u8, output, "runtime_filtered") == null);
    try testing.expect(std.mem.indexOf(u8, output, "runtime_dynamic") == null);
}

test "Convenience constructor for compile-time redaction" {
    var output = TestOutput.init();

    const log_factory = loggerWithRedaction(.{
        .redacted_fields = &.{ "token", "auth_header" },
    }, &output.writer);
    _ = log_factory;

    var custom_log = LoggerWithRedaction(.{}, .{
        .redacted_fields = &.{ "token", "auth_header" },
    }).init(&output.writer);

    custom_log.info("Auth flow", &.{
        Field.string("user", "admin"),
        Field.string("token", "bearer_abc123"),
        Field.string("auth_header", "Basic dXNlcjpwYXNz"),
        Field.string("endpoint", "/api/login"),
    });

    const result = output.written();
    try testing.expect(std.mem.indexOf(u8, result, "admin") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/api/login") != null);
    try testing.expect(std.mem.indexOf(u8, result, "bearer_abc123") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Basic dXNlcjpwYXNz") == null);
    try testing.expect(std.mem.indexOf(u8, result, "[REDACTED:string]") != null);
}
