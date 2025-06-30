const std = @import("std");
const xev = @import("xev");

pub const config = @import("config.zig");
const field_mod = @import("field.zig");
pub const trace = @import("trace.zig");
pub const correlation = @import("correlation.zig");
pub const redaction = @import("redaction.zig");
pub const event = @import("event.zig");
pub const logger = @import("logger.zig");

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

pub fn default() Logger(.{}) {
    const stderr_file = std.io.getStdErr();
    const stderr_any_writer = stderr_file.writer().any();

    std.debug.assert(@TypeOf(stderr_any_writer) == std.io.AnyWriter);
    std.debug.assert(@TypeOf(stderr_file) == std.fs.File);

    const default_logger = Logger(.{}).init(stderr_any_writer);
    std.debug.assert(@intFromEnum(default_logger.level) <= @intFromEnum(Level.fatal));
    return default_logger;
}

pub fn defaultAsync(event_loop_ptr: *xev.Loop, memory_allocator: std.mem.Allocator) !Logger(.{ .async_mode = true }) {
    const stderr_file = std.io.getStdErr();
    const stderr_any_writer = stderr_file.writer().any();

    std.debug.assert(@TypeOf(stderr_any_writer) == std.io.AnyWriter);
    std.debug.assert(@TypeOf(stderr_file) == std.fs.File);
    std.debug.assert(@TypeOf(event_loop_ptr.*) == xev.Loop);
    std.debug.assert(@TypeOf(memory_allocator) == std.mem.Allocator);

    const async_logger_result = try Logger(.{ .async_mode = true }).initAsync(stderr_any_writer, event_loop_ptr, memory_allocator);
    std.debug.assert(@intFromEnum(async_logger_result.level) <= @intFromEnum(Level.fatal));
    return async_logger_result;
}

pub fn asyncLogger(comptime custom_config: Config, output_writer: std.io.AnyWriter, event_loop_ptr: *xev.Loop, memory_allocator: std.mem.Allocator) !Logger(custom_config) {
    comptime {
        if (!custom_config.async_mode) {
            @compileError("asyncLogger() requires async_mode = true in config");
        }
        std.debug.assert(custom_config.max_fields > 0);
        std.debug.assert(custom_config.buffer_size >= 256);
        std.debug.assert(custom_config.async_queue_size > 0);
    }

    std.debug.assert(@TypeOf(output_writer) == std.io.AnyWriter);
    std.debug.assert(@TypeOf(event_loop_ptr.*) == xev.Loop);
    std.debug.assert(@TypeOf(memory_allocator) == std.mem.Allocator);

    const custom_async_logger = try Logger(custom_config).initAsync(output_writer, event_loop_ptr, memory_allocator);
    std.debug.assert(@intFromEnum(custom_async_logger.level) <= @intFromEnum(Level.fatal));
    return custom_async_logger;
}

pub fn loggerWithRedaction(comptime redaction_options: RedactionOptions) LoggerWithRedaction(.{}, redaction_options) {
    const stderr_file = std.io.getStdErr();
    const stderr_any_writer = stderr_file.writer().any();

    std.debug.assert(@TypeOf(stderr_any_writer) == std.io.AnyWriter);
    std.debug.assert(@TypeOf(stderr_file) == std.fs.File);

    const logger_result = LoggerWithRedaction(.{}, redaction_options).init(stderr_any_writer);
    std.debug.assert(@intFromEnum(logger_result.level) <= @intFromEnum(Level.fatal));
    return logger_result;
}

pub const generateTraceId = trace.generate_trace_id;
pub const generateSpanId = trace.generate_span_id;
pub const isAllZeroId = trace.is_all_zero_id;
pub const bytesToHex = trace.bytes_to_hex_lowercase;

// For backward compatibility
pub const field = field_mod.Field;

const testing = std.testing;

test "JSON serialization with basic message" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());
    log.info("Test message", &.{});

    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"INFO\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Test message\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"trace\":"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"span\":"));
}

test "JSON serialization with multiple fields" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());
    log.info("Test message", &.{
        Field.string("key1", "value1"),
        Field.int("key2", 42),
        Field.float("key3", 3.14),
    });

    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"INFO\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Test message\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"key1\":\"value1\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"key2\":42"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"key3\":3.14"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"trace\":"));
}

test "JSON escaping in strings" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());
    log.info("Message with \"quotes\" and \\backslash\\", &.{
        Field.string("special", "Line\nbreak\tand\rcarriage"),
    });

    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"INFO\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Message with"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"special\":"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"trace\":"));
}

test "All field types" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());
    log.info("All types", &.{
        Field.string("str", "hello"),
        Field.int("int", -42),
        Field.uint("uint", 42),
        Field.float("float", 3.14159),
        Field.boolean("bool_true", true),
        Field.boolean("bool_false", false),
        Field.null_value("null_field"),
    });

    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"INFO\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"All types\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"str\":\"hello\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"int\":-42"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"uint\":42"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"float\":3.14159"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"bool_true\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"bool_false\":false"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"null_field\":null"));
}

test "Level filtering" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{ .level = .warn }).init(buffer.writer().any());

    log.trace("Trace message", &.{});
    log.debug("Debug message", &.{});
    log.info("Info message", &.{});

    log.warn("Warning message", &.{});
    log.err("Error message", &.{});
    log.fatal("Fatal message", &.{});

    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"WARN\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Warning message\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"ERROR\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Error message\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"FATAL\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Fatal message\""));
    try testing.expect(!std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Trace message\""));
    try testing.expect(!std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Debug message\""));
    try testing.expect(!std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Info message\""));
}

test "Empty fields array" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());
    log.info("Empty fields", &.{});

    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"INFO\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Empty fields\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"trace\":"));
}

test "Field limit enforcement" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{ .max_fields = 3 }).init(buffer.writer().any());

    var fields: [5]Field = undefined;
    inline for (0..5) |i| {
        fields[i] = Field.int(std.fmt.comptimePrint("field{}", .{i}), @as(i64, @intCast(i)));
    }

    log.info("Limited fields", &fields);

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"field0\":0"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"field1\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"field2\":2"));
}

test "Control characters escaping" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());

    const test_string = "Bell:\x07 Backspace:\x08 Tab:\t Newline:\n FormFeed:\x0C Return:\r Escape:\x1B";
    log.info("Control test", &.{
        Field.string("control_chars", test_string),
    });

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\\u0007"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\\b"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\\t"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\\n"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\\f"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\\r"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\\u001b"));
}

test "All log levels" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{ .level = .trace }).init(buffer.writer().any());

    log.trace("Trace msg", &.{});
    log.debug("Debug msg", &.{});
    log.info("Info msg", &.{});
    log.warn("Warn msg", &.{});
    log.err("Error msg", &.{});
    log.fatal("Fatal msg", &.{});

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"level\":\"TRACE\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"level\":\"DEBUG\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"level\":\"INFO\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"level\":\"WARN\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"level\":\"ERROR\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"level\":\"FATAL\""));
}

test "Large message within buffer" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{ .buffer_size = 1024 }).init(buffer.writer().any());

    const large_msg = "A" ** 500;
    log.info(large_msg, &.{});

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, large_msg));
}

test "Unicode characters" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());

    log.info("Unicode test", &.{
        Field.string("emoji", "🦎"),
        Field.string("chinese", "你好"),
        Field.string("special", "café"),
    });

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "🦎"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "你好"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "café"));
}

test "Default logger creation" {
    const log = default();
    _ = log;
}

test "Custom configuration" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const custom_config = Config{
        .level = .debug,
        .max_fields = 10,
        .buffer_size = 2048,
    };

    var log = Logger(custom_config).init(buffer.writer().any());
    log.debug("Custom config test", &.{});

    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"level\":\"DEBUG\""));
}

test "Field convenience functions" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var log = Logger(.{}).init(buffer.writer().any());

    log.info("Field test", &.{
        Field.string("name", "test"),
        Field.int("count", -123),
        Field.uint("size", 456),
        Field.float("ratio", 1.23),
        Field.boolean("active", true),
        Field.null_value("empty"),
    });

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"name\":\"test\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"count\":-123"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"size\":456"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"ratio\":1.23"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"active\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"empty\":null"));
}

test "Async logger creation and basic functionality" {
    const test_allocator = testing.allocator;
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var buffer = std.ArrayList(u8).init(test_allocator);
    defer buffer.deinit();

    var async_log = try Logger(.{ .async_mode = true }).initAsync(
        buffer.writer().any(),
        &loop,
        test_allocator,
    );
    defer async_log.deinit();

    async_log.info("Async test message", &.{
        Field.string("type", "async"),
        Field.int("count", 1),
    });

    // Process messages by running the event loop
    for (0..5) |_| {
        try loop.run(.no_wait);
        std.time.sleep(5 * std.time.ns_per_ms);
    }

    async_log.async_logger.?.flushPending();

    try testing.expect(buffer.items.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"msg\":\"Async test message\""));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "\"type\":\"async\""));
}

test "Async logger with high volume" {
    const test_allocator = testing.allocator;
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var buffer = std.ArrayList(u8).init(test_allocator);
    defer buffer.deinit();

    var async_log = try Logger(.{ .async_mode = true }).initAsync(
        buffer.writer().any(),
        &loop,
        test_allocator,
    );
    defer async_log.deinit();

    for (0..10) |i| {
        async_log.info("Bulk message", &.{
            Field.uint("index", i),
            Field.string("thread", "test"),
        });
    }

    // Process messages by running the event loop
    for (0..5) |_| {
        try loop.run(.no_wait);
        std.time.sleep(5 * std.time.ns_per_ms);
    }

    async_log.async_logger.?.flushPending();

    try testing.expect(buffer.items.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 10, "\"msg\":\"Bulk message\""));
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
    const test_allocator = testing.allocator;
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var buffer = std.ArrayList(u8).init(test_allocator);
    defer buffer.deinit();

    const async_config = Config{
        .async_mode = true,
        .async_queue_size = 1024,
        .batch_size = 16,
    };

    var async_log = try Logger(async_config).initAsync(
        buffer.writer().any(),
        &loop,
        test_allocator,
    );
    defer async_log.deinit();

    try testing.expect(async_log.async_logger != null);
}

test "Default async logger creation" {
    const test_allocator = testing.allocator;
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var async_log = try defaultAsync(&loop, test_allocator);
    defer async_log.deinit();

    var buffer = std.ArrayList(u8).init(test_allocator);
    defer buffer.deinit();

    async_log = try Logger(.{ .async_mode = true }).initAsync(
        buffer.writer().any(),
        &loop,
        test_allocator,
    );

    async_log.info("Default async test", &.{});
    async_log.async_logger.?.flushPending();
}

test "RedactionConfig context pattern" {
    const test_allocator = testing.allocator;

    var log_output = std.ArrayList(u8).init(test_allocator);
    defer log_output.deinit();

    var redaction_cfg = RedactionConfig.init(test_allocator);
    defer redaction_cfg.deinit();

    try redaction_cfg.addKey("password");
    try redaction_cfg.addKey("apiKey");

    var log = Logger(.{}).initWithRedaction(log_output.writer().any(), &redaction_cfg);

    log.info("User action", &.{
        Field.string("user", "alice"),
        Field.string("password", "super_secret"),
    });

    try testing.expect(std.mem.indexOf(u8, log_output.items, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, log_output.items, "super_secret") == null);
    try testing.expect(std.mem.indexOf(u8, log_output.items, "[REDACTED:string]") != null);
}

test "Context-based redaction in action" {
    const test_allocator = testing.allocator;

    var redaction_cfg = RedactionConfig.init(test_allocator);
    defer redaction_cfg.deinit();

    try redaction_cfg.addKey("password");
    try redaction_cfg.addKey("api_key");
    try redaction_cfg.addKey("ssn");

    var log_output = std.ArrayList(u8).init(test_allocator);
    defer log_output.deinit();

    var log = Logger(.{}).initWithRedaction(log_output.writer().any(), &redaction_cfg);

    log.info("User login", &.{
        Field.string("username", "alice"),
        Field.string("password", "secret123"),
        Field.string("ip", "192.168.1.1"),
    });

    const output = log_output.items;
    try testing.expect(std.mem.indexOf(u8, output, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, output, "192.168.1.1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "secret123") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[REDACTED:string]") != null);
}

test "Compile-time redaction - zero cost filtering" {
    const test_allocator = testing.allocator;

    const CompileTimeLogger = LoggerWithRedaction(.{}, .{
        .redacted_fields = &.{ "password", "api_key", "secret" },
    });

    var log_output = std.ArrayList(u8).init(test_allocator);
    defer log_output.deinit();

    var log = CompileTimeLogger.init(log_output.writer().any());

    log.info("Security test", &.{
        Field.string("username", "bob"),
        Field.string("password", "compile_time_secret"),
        Field.string("api_key", "ct_api_key_123"),
        Field.string("email", "bob@example.com"),
    });

    const output = log_output.items;
    try testing.expect(std.mem.indexOf(u8, output, "bob") != null);
    try testing.expect(std.mem.indexOf(u8, output, "bob@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, output, "compile_time_secret") == null);
    try testing.expect(std.mem.indexOf(u8, output, "ct_api_key_123") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[REDACTED:string]") != null);
}

test "Hybrid redaction - compile-time + runtime" {
    const test_allocator = testing.allocator;

    var runtime_redaction = RedactionConfig.init(test_allocator);
    defer runtime_redaction.deinit();
    try runtime_redaction.addKey("runtime_secret");
    try runtime_redaction.addKey("dynamic_key");

    const HybridLogger = LoggerWithRedaction(.{}, .{
        .redacted_fields = &.{ "password", "api_key" },
    });

    var log_output = std.ArrayList(u8).init(test_allocator);
    defer log_output.deinit();

    var log = HybridLogger.initWithRedaction(log_output.writer().any(), &runtime_redaction);

    log.info("Hybrid test", &.{
        Field.string("username", "charlie"),
        Field.string("password", "compile_time_filtered"),
        Field.string("api_key", "compile_time_api"),
        Field.string("runtime_secret", "runtime_filtered"),
        Field.string("dynamic_key", "runtime_dynamic"),
        Field.string("visible_field", "not_redacted"),
    });

    const output = log_output.items;
    try testing.expect(std.mem.indexOf(u8, output, "charlie") != null);
    try testing.expect(std.mem.indexOf(u8, output, "not_redacted") != null);
    try testing.expect(std.mem.indexOf(u8, output, "compile_time_filtered") == null);
    try testing.expect(std.mem.indexOf(u8, output, "compile_time_api") == null);
    try testing.expect(std.mem.indexOf(u8, output, "runtime_filtered") == null);
    try testing.expect(std.mem.indexOf(u8, output, "runtime_dynamic") == null);
}

test "Convenience constructor for compile-time redaction" {
    const test_allocator = testing.allocator;

    var output = std.ArrayList(u8).init(test_allocator);
    defer output.deinit();

    const log_factory = loggerWithRedaction(.{
        .redacted_fields = &.{ "token", "auth_header" },
    });
    _ = log_factory;

    var custom_log = LoggerWithRedaction(.{}, .{
        .redacted_fields = &.{ "token", "auth_header" },
    }).init(output.writer().any());

    custom_log.info("Auth flow", &.{
        Field.string("user", "admin"),
        Field.string("token", "bearer_abc123"),
        Field.string("auth_header", "Basic dXNlcjpwYXNz"),
        Field.string("endpoint", "/api/login"),
    });

    const result = output.items;
    try testing.expect(std.mem.indexOf(u8, result, "admin") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/api/login") != null);
    try testing.expect(std.mem.indexOf(u8, result, "bearer_abc123") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Basic dXNlcjpwYXNz") == null);
    try testing.expect(std.mem.indexOf(u8, result, "[REDACTED:string]") != null);
}
