const std = @import("std");
const assert = std.debug.assert;

/// Log level enumeration ordered by severity.
pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    /// Returns the string representation of the log level.
    pub fn string(self: Level) []const u8 {
        assert(@intFromEnum(self) <= @intFromEnum(Level.fatal));
        const result = switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
        assert(result.len > 0);
        return result;
    }

    /// Returns the JSON string representation of the log level.
    pub fn json_string(self: Level) []const u8 {
        assert(@intFromEnum(self) <= @intFromEnum(Level.fatal));
        const result = switch (self) {
            .trace => "Trace",
            .debug => "Debug",
            .info => "Info",
            .warn => "Warn",
            .err => "Error",
            .fatal => "Fatal",
        };
        assert(result.len > 0);
        return result;
    }
};

/// Field represents a key-value pair for structured logging.
pub const Field = struct {
    key: []const u8,
    value: Value,

    /// Value types supported by the logger.
    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        boolean: bool,
        null: void,
    };

    /// Creates a string field.
    pub fn string(key: []const u8, value: []const u8) Field {
        assert(key.len > 0);
        assert(value.len < 1024 * 1024); // Reasonable string size limit
        return .{ .key = key, .value = .{ .string = value } };
    }

    /// Creates an integer field.
    pub fn int(key: []const u8, value: i64) Field {
        assert(key.len > 0);
        assert(value >= std.math.minInt(i64));
        return .{ .key = key, .value = .{ .int = value } };
    }

    /// Creates an unsigned integer field.
    pub fn uint(key: []const u8, value: u64) Field {
        assert(key.len > 0);
        assert(value <= std.math.maxInt(u64));
        return .{ .key = key, .value = .{ .uint = value } };
    }

    /// Creates a float field.
    pub fn float(key: []const u8, value: f64) Field {
        assert(key.len > 0);
        assert(!std.math.isNan(value));
        return .{ .key = key, .value = .{ .float = value } };
    }

    /// Creates a boolean field.
    pub fn boolean(key: []const u8, value: bool) Field {
        assert(key.len > 0);
        assert(@TypeOf(value) == bool); // Ensure type safety
        return .{ .key = key, .value = .{ .boolean = value } };
    }

    /// Creates a null field.
    pub fn null_value(key: []const u8) Field {
        assert(key.len > 0);
        assert(key.len < 256); // Reasonable key length limit
        return .{ .key = key, .value = .{ .null = {} } };
    }
};

/// Configuration for the logger, set at compile time.
pub const Config = struct {
    /// Minimum level to log. Messages below this level are discarded.
    level: Level = .info,
    /// Maximum number of fields per log message.
    max_fields: u16 = 32,
    /// Buffer size for formatting log messages.
    buffer_size: u32 = 4096,
};

/// Logger provides structured logging with zero allocations.
pub fn Logger(comptime config: Config) type {
    comptime {
        assert(config.max_fields > 0);
        assert(config.buffer_size >= 256);
        assert(config.buffer_size <= 65536);
    }

    return struct {
        const Self = @This();
        const max_fields = config.max_fields;
        const buffer_size = config.buffer_size;

        writer: std.io.AnyWriter,
        mutex: std.Thread.Mutex = .{},
        level: Level,

        /// Initialize a new logger with the given writer.
        pub fn init(writer: std.io.AnyWriter) Self {
            assert(@TypeOf(writer) == std.io.AnyWriter);
            assert(@intFromEnum(config.level) <= @intFromEnum(Level.fatal));
            return .{
                .writer = writer,
                .level = config.level,
            };
        }

        /// Log a message at the trace level.
        pub fn trace(self: *Self, message: []const u8, fields: []const Field) void {
            assert(message.len < buffer_size);
            assert(fields.len <= 1024); // Sanity check upper bound
            self.log(.trace, message, fields);
        }

        /// Log a message at the debug level.
        pub fn debug(self: *Self, message: []const u8, fields: []const Field) void {
            assert(message.len < buffer_size);
            assert(fields.len <= 1024); // Sanity check upper bound
            self.log(.debug, message, fields);
        }

        /// Log a message at the info level.
        pub fn info(self: *Self, message: []const u8, fields: []const Field) void {
            assert(message.len < buffer_size);
            assert(fields.len <= 1024); // Sanity check upper bound
            self.log(.info, message, fields);
        }

        /// Log a message at the warn level.
        pub fn warn(self: *Self, message: []const u8, fields: []const Field) void {
            assert(message.len < buffer_size);
            assert(fields.len <= 1024); // Sanity check upper bound
            self.log(.warn, message, fields);
        }

        /// Log a message at the error level.
        pub fn err(self: *Self, message: []const u8, fields: []const Field) void {
            assert(message.len < buffer_size);
            assert(fields.len <= 1024); // Sanity check upper bound
            self.log(.err, message, fields);
        }

        /// Log a message at the fatal level.
        pub fn fatal(self: *Self, message: []const u8, fields: []const Field) void {
            assert(message.len < buffer_size);
            assert(fields.len <= 1024); // Sanity check upper bound
            self.log(.fatal, message, fields);
        }

        /// Internal logging function that performs level filtering and formatting.
        fn log(self: *Self, level: Level, message: []const u8, fields: []const Field) void {
            assert(@intFromEnum(level) <= @intFromEnum(Level.fatal));
            assert(fields.len <= 1024); // Sanity check upper bound
            var buffer: [buffer_size]u8 = undefined;
            executeLoggingPipelineStandalone(
                level,
                self.level,
                message,
                fields,
                max_fields,
                buffer_size,
                self.writer,
                &self.mutex,
                &buffer,
            );
        }

        fn validateFieldCount(self: *const Self, field_length: usize) u16 {
            assert(field_length <= 1024);
            assert(max_fields > 0);
            _ = self;
            return validateFieldCountStandalone(field_length, max_fields);
        }

        fn writeLogMessage(
            self: *Self,
            level: Level,
            message: []const u8,
            fields: []const Field,
            buffer: []u8,
        ) void {
            assert(buffer.len == buffer_size);
            assert(fields.len <= max_fields);
            writeLogMessageStandalone(
                level,
                message,
                fields,
                buffer,
                max_fields,
                buffer_size,
                self.writer,
                &self.mutex,
            );
        }

        /// Format a log record as JSON into the provided writer.
        fn format_json(
            self: *const Self,
            writer: anytype,
            level: Level,
            message: []const u8,
            fields: []const Field,
        ) !usize {
            assert(fields.len <= max_fields);
            assert(@intFromEnum(level) <= @intFromEnum(Level.fatal));
            _ = self;
            return format_json_record(writer, level, message, fields, max_fields, buffer_size);
        }
    };
}

/// Validate field count and return clamped count within bounds.
fn validateFieldCountStandalone(field_length: usize, max_fields_limit: u16) u16 {
    assert(field_length <= 1024); // Reasonable upper bound check
    assert(max_fields_limit > 0);

    const field_count: u16 = @intCast(@min(field_length, max_fields_limit));
    if (field_length > max_fields_limit) {
        std.debug.print(
            "zlog: field count {} exceeds max_fields {}\n",
            .{ field_length, max_fields_limit },
        );
    }
    return field_count;
}

/// Execute the complete logging pipeline without self parameter.
fn executeLoggingPipelineStandalone(
    level: Level,
    current_level: Level,
    message: []const u8,
    fields: []const Field,
    max_fields_limit: u16,
    buffer_size_limit: u32,
    writer: std.io.AnyWriter,
    mutex: *std.Thread.Mutex,
    buffer: []u8,
) void {
    assert(@intFromEnum(level) <= @intFromEnum(Level.fatal));
    assert(@intFromEnum(current_level) <= @intFromEnum(Level.fatal));
    assert(message.len < buffer_size_limit);
    assert(max_fields_limit > 0);
    assert(buffer_size_limit >= 256);
    assert(buffer.len >= buffer_size_limit);

    // Early return for filtered levels
    if (@intFromEnum(level) < @intFromEnum(current_level)) return;

    const field_count = validateFieldCountStandalone(fields.len, max_fields_limit);

    writeLogMessageStandalone(
        level,
        message,
        fields[0..field_count],
        buffer[0..buffer_size_limit],
        max_fields_limit,
        buffer_size_limit,
        writer,
        mutex,
    );
}

/// Write formatted log message to output without self parameter.
fn writeLogMessageStandalone(
    level: Level,
    message: []const u8,
    fields: []const Field,
    buffer: []u8,
    max_fields_limit: u16,
    buffer_size_limit: u32,
    writer: std.io.AnyWriter,
    mutex: *std.Thread.Mutex,
) void {
    assert(fields.len <= max_fields_limit);
    assert(message.len < buffer_size_limit / 2);

    var fbs = std.io.fixedBufferStream(buffer);
    const buffer_writer = fbs.writer();

    const format_bytes = format_json_record(
        buffer_writer,
        level,
        message,
        fields,
        max_fields_limit,
        buffer_size_limit,
    ) catch |format_err| {
        std.debug.print("zlog: format error: {}\n", .{format_err});
        return;
    };
    _ = format_bytes; // Acknowledge we don't need the value

    mutex.lock();
    defer mutex.unlock();

    const write_bytes = writer.write(fbs.getWritten()) catch |write_err| {
        std.debug.print("zlog: write error: {}\n", .{write_err});
        return;
    };
    _ = write_bytes; // Acknowledge we don't need the value
}

/// Format a log record as JSON into the provided writer.
fn format_json_record(
    writer: anytype,
    level: Level,
    message: []const u8,
    fields: []const Field,
    max_fields: u16,
    buffer_size: u32,
) !usize {
    assert(fields.len <= max_fields);
    assert(message.len < buffer_size / 2);

    const start_position = try writer.context.getPos();

    try writer.writeByte('{');

    // Write the level field.
    try writer.writeAll("\"level\":\"");
    try writer.writeAll(level.json_string());
    try writer.writeByte('"');

    // Write the message field.
    try writer.writeAll(",\"message\":\"");
    try write_escaped_string(writer, message);
    try writer.writeByte('"');

    // Write all additional fields.
    for (fields) |field_item| {
        try writer.writeByte(',');
        try writer.writeByte('"');
        try write_escaped_string(writer, field_item.key);
        try writer.writeAll("\":");

        switch (field_item.value) {
            .string => |string_content| {
                try writer.writeByte('"');
                try write_escaped_string(writer, string_content);
                try writer.writeByte('"');
            },
            .int => |signed_number| try std.fmt.formatInt(signed_number, 10, .lower, .{}, writer),
            .uint => |number_content| try std.fmt.formatInt(
                number_content,
                10,
                .lower,
                .{},
                writer,
            ),
            .float => |float_content| try writer.print("{d}", .{float_content}),
            .boolean => |bool_content| try writer.writeAll(if (bool_content) "true" else "false"),
            .null => try writer.writeAll("null"),
        }
    }

    try writer.writeAll("}\n");

    const end_position = try writer.context.getPos();
    return end_position - start_position;
}

/// Check if character needs JSON escaping.
inline fn characterNeedsEscaping(character: u8) bool {
    assert(character <= 255); // u8 range check
    const result = switch (character) {
        '"', '\\', '\n', '\r', '\t', 0x08, 0x0C => true,
        else => character < 0x20,
    };
    assert(@TypeOf(result) == bool); // Ensure return type
    return result;
}

/// Write escaped character to writer.
inline fn writeEscapedCharacter(writer: anytype, character: u8) !void {
    assert(character <= 255); // u8 range check
    assert(@TypeOf(writer).Error != void); // Ensure proper error type
    switch (character) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        else => {
            if (character < 0x20) {
                try writer.print("\\u{x:0>4}", .{character});
            } else {
                try writer.writeByte(character);
            }
        },
    }
}

/// Write a string with JSON escaping optimized for batching.
fn write_escaped_string(writer: anytype, string: []const u8) !void {
    assert(string.len < 1024 * 1024); // Sanity check: prevent extremely large strings
    assert(@TypeOf(writer).Error != void); // Ensure writer has proper error type

    var start_index: usize = 0;

    for (string, 0..) |character, index| {
        if (characterNeedsEscaping(character)) {
            // Write safe characters in batch
            if (index > start_index) {
                try writer.writeAll(string[start_index..index]);
            }

            // Write escaped character
            try writeEscapedCharacter(writer, character);
            start_index = index + 1;
        }
    }

    // Write remaining safe characters
    if (start_index < string.len) {
        try writer.writeAll(string[start_index..]);
    }
}

/// Creates a logger with default configuration writing to stderr.
pub fn default() Logger(.{}) {
    const stderr_writer = std.io.getStdErr().writer().any();
    assert(@TypeOf(stderr_writer) == std.io.AnyWriter);
    assert(@TypeOf(std.io.getStdErr()) == std.fs.File);
    return Logger(.{}).init(stderr_writer);
}

// Re-export commonly used types for convenience.
pub const field = Field;

// Test suite for zlog functionality.
const testing = std.testing;

test "JSON serialization with basic message" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{}).init(buffer.writer().any());
    logger.info("Test message", &.{});

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"Test message\"}\n",
        buffer.items,
    );
}

test "JSON serialization with multiple fields" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{}).init(buffer.writer().any());
    logger.info("Test message", &.{
        field.string("key1", "value1"),
        field.int("key2", 42),
        field.float("key3", 3.14),
    });

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"Test message\"," ++
            "\"key1\":\"value1\",\"key2\":42,\"key3\":3.14}\n",
        buffer.items,
    );
}

test "JSON escaping in strings" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{}).init(buffer.writer().any());
    logger.info("Message with \"quotes\" and \\backslash\\", &.{
        field.string("special", "Line\nbreak\tand\rcarriage"),
    });

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"Message with \\\"quotes\\\" and \\\\backslash\\\\\"," ++
            "\"special\":\"Line\\nbreak\\tand\\rcarriage\"}\n",
        buffer.items,
    );
}

test "All field types" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{}).init(buffer.writer().any());
    logger.info("All types", &.{
        field.string("str", "hello"),
        field.int("int", -42),
        field.uint("uint", 42),
        field.float("float", 3.14159),
        field.boolean("bool_true", true),
        field.boolean("bool_false", false),
        field.null_value("null_field"),
    });

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"All types\",\"str\":\"hello\",\"int\":-42," ++
            "\"uint\":42,\"float\":3.14159,\"bool_true\":true,\"bool_false\":false," ++
            "\"null_field\":null}\n",
        buffer.items,
    );
}

test "Level filtering" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{ .level = .warn }).init(buffer.writer().any());

    // These messages should be filtered out by level.
    logger.trace("Trace message", &.{});
    logger.debug("Debug message", &.{});
    logger.info("Info message", &.{});

    // These messages should pass through the filter.
    logger.warn("Warning message", &.{});
    logger.err("Error message", &.{});
    logger.fatal("Fatal message", &.{});

    const expected =
        "{\"level\":\"Warn\",\"message\":\"Warning message\"}\n" ++
        "{\"level\":\"Error\",\"message\":\"Error message\"}\n" ++
        "{\"level\":\"Fatal\",\"message\":\"Fatal message\"}\n";

    try testing.expectEqualStrings(expected, buffer.items);
}

test "Empty fields array" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{}).init(buffer.writer().any());
    logger.info("No fields", &.{});

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"No fields\"}\n",
        buffer.items,
    );
}

test "Field limit enforcement" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{ .max_fields = 3 }).init(buffer.writer().any());

    const fields = [_]Field{
        field.int("f1", 1),
        field.int("f2", 2),
        field.int("f3", 3),
        field.int("f4", 4), // This field should be truncated.
        field.int("f5", 5), // This field should be truncated.
    };

    logger.info("Limited fields", &fields);

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"Limited fields\",\"f1\":1,\"f2\":2,\"f3\":3}\n",
        buffer.items,
    );
}

test "Control characters escaping" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{}).init(buffer.writer().any());
    const control_chars = [_]u8{ 0x01, 0x08, 0x0C, 0x1F };
    logger.info("Control", &.{
        field.string("ctrl", &control_chars),
    });

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"Control\",\"ctrl\":\"\\u0001\\b\\f\\u001f\"}\n",
        buffer.items,
    );
}

test "All log levels" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{ .level = .trace }).init(buffer.writer().any());

    logger.trace("Trace", &.{});
    logger.debug("Debug", &.{});
    logger.info("Info", &.{});
    logger.warn("Warn", &.{});
    logger.err("Error", &.{});
    logger.fatal("Fatal", &.{});

    const expected =
        "{\"level\":\"Trace\",\"message\":\"Trace\"}\n" ++
        "{\"level\":\"Debug\",\"message\":\"Debug\"}\n" ++
        "{\"level\":\"Info\",\"message\":\"Info\"}\n" ++
        "{\"level\":\"Warn\",\"message\":\"Warn\"}\n" ++
        "{\"level\":\"Error\",\"message\":\"Error\"}\n" ++
        "{\"level\":\"Fatal\",\"message\":\"Fatal\"}\n";

    try testing.expectEqualStrings(expected, buffer.items);
}

test "Large message within buffer" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{ .buffer_size = 512 }).init(buffer.writer().any());

    const long_msg = "A" ** 100;
    const long_value = "B" ** 100;
    logger.info(long_msg, &.{
        field.string("data", long_value),
    });

    const expected = "{\"level\":\"Info\",\"message\":\"" ++
        long_msg ++ "\",\"data\":\"" ++ long_value ++ "\"}\n";
    try testing.expectEqualStrings(expected, buffer.items);
}

test "Unicode characters" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{}).init(buffer.writer().any());
    logger.info("Unicode test 🚀", &.{
        field.string("emoji", "🔥"),
    });

    try testing.expectEqualStrings(
        "{\"level\":\"Info\",\"message\":\"Unicode test 🚀\",\"emoji\":\"🔥\"}\n",
        buffer.items,
    );
}

test "Default logger creation" {
    const logger = default();
    try testing.expect(logger.level == .info);
}

test "Custom configuration" {
    const custom_config = Config{
        .level = .debug,
        .max_fields = 10,
        .buffer_size = 1024,
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(custom_config).init(buffer.writer().any());
    try testing.expect(logger.level == .debug);

    logger.debug("Debug enabled", &.{});
    try testing.expectEqualStrings(
        "{\"level\":\"Debug\",\"message\":\"Debug enabled\"}\n",
        buffer.items,
    );
}

test "Field convenience functions" {
    const str_field = field.string("str", "value");
    try testing.expectEqualStrings("str", str_field.key);
    try testing.expect(str_field.value == .string);

    const int_field = field.int("int", -42);
    try testing.expect(int_field.value.int == -42);

    const uint_field = field.uint("uint", 42);
    try testing.expect(uint_field.value.uint == 42);

    const float_field = field.float("float", 3.14);
    try testing.expect(float_field.value.float == 3.14);

    const bool_field = field.boolean("bool", true);
    try testing.expect(bool_field.value.boolean == true);

    const null_field = field.null_value("null");
    try testing.expect(null_field.value == .null);
}
