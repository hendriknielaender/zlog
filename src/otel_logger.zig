const std = @import("std");
const assert = std.debug.assert;
const xev = @import("xev");

const config = @import("config.zig");
const field = @import("field.zig");
const trace_mod = @import("trace.zig");
const otel = @import("otel.zig");
const escape = @import("string_escape.zig");
const redaction = @import("redaction.zig");

/// OpenTelemetry-compliant logger that outputs logs according to OTel log data model
pub fn OTelLogger(comptime otel_config: otel.OTelConfig) type {
    return OTelLoggerWithRedaction(otel_config, .{});
}

pub fn OTelLoggerWithRedaction(comptime otel_config: otel.OTelConfig, comptime redaction_options: redaction.RedactionOptions) type {
    const cfg = otel_config.base_config;

    comptime {
        assert(cfg.max_fields > 0);
        assert(cfg.buffer_size >= 256);
        assert(cfg.buffer_size <= 65536);
    }

    return struct {
        const Self = @This();
        const max_fields = cfg.max_fields;
        const buffer_size = cfg.buffer_size;
        const async_mode = cfg.async_mode;
        const compile_time_redacted_fields = redaction_options.redacted_fields;

        writer: std.io.AnyWriter,
        mutex: std.Thread.Mutex = std.Thread.Mutex{},
        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,
        resource: otel.Resource,
        instrumentation_scope: otel.InstrumentationScope,
        async_logger: if (async_mode) ?OTelAsyncLogger(otel_config) else void = if (async_mode) null else {},
        managed_event_loop: if (async_mode) ?*xev.Loop else void = if (async_mode) null else {},

        pub fn init(output_writer: std.io.AnyWriter) Self {
            return initWithRedaction(output_writer, null);
        }

        pub fn initWithRedaction(output_writer: std.io.AnyWriter, redaction_cfg: ?*const redaction.RedactionConfig) Self {
            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@intFromEnum(cfg.level) <= @intFromEnum(config.Level.fatal));

            return Self{
                .writer = output_writer,
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
                .async_logger = if (async_mode) null else {},
                .managed_event_loop = if (async_mode) null else {},
            };
        }

        /// Initialize async OTel logger with managed event loop (recommended)
        pub fn initAsync(
            output_writer: std.io.AnyWriter,
            memory_allocator: std.mem.Allocator,
        ) !Self {
            // Create managed event loop
            const managed_loop = try memory_allocator.create(xev.Loop);
            managed_loop.* = try xev.Loop.init(.{});

            var logger = try initAsyncWithRedaction(output_writer, managed_loop, memory_allocator, null);
            logger.managed_event_loop = managed_loop;
            return logger;
        }

        /// Initialize async OTel logger with existing event loop (advanced usage)
        pub fn initAsyncWithEventLoop(
            output_writer: std.io.AnyWriter,
            event_loop: *xev.Loop,
            memory_allocator: std.mem.Allocator,
        ) !Self {
            var logger = try initAsyncWithRedaction(output_writer, event_loop, memory_allocator, null);
            logger.managed_event_loop = null; // User manages the event loop
            return logger;
        }

        fn initAsyncWithRedaction(
            output_writer: std.io.AnyWriter,
            event_loop: *xev.Loop,
            memory_allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            comptime {
                if (!async_mode) {
                    @compileError("initAsyncWithRedaction() requires async_mode = true in config");
                }
            }

            const async_logger_instance = try OTelAsyncLogger(otel_config).init(memory_allocator, output_writer, event_loop);

            return Self{
                .writer = output_writer,
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
                .async_logger = async_logger_instance,
                .managed_event_loop = null, // Will be set by calling functions
            };
        }

        /// Initialize async OTel logger with redaction and managed event loop
        pub fn initAsyncWithRedactionManaged(
            output_writer: std.io.AnyWriter,
            memory_allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            // Create managed event loop
            const managed_loop = try memory_allocator.create(xev.Loop);
            managed_loop.* = try xev.Loop.init(.{});

            var logger = try initAsyncWithRedaction(output_writer, managed_loop, memory_allocator, redaction_cfg);
            logger.managed_event_loop = managed_loop;
            return logger;
        }

        /// Initialize async OTel logger with redaction and existing event loop
        pub fn initAsyncWithRedactionAndEventLoop(
            output_writer: std.io.AnyWriter,
            event_loop: *xev.Loop,
            memory_allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            var logger = try initAsyncWithRedaction(output_writer, event_loop, memory_allocator, redaction_cfg);
            logger.managed_event_loop = null; // User manages the event loop
            return logger;
        }

        pub fn deinit(self: *Self) void {
            if (async_mode) {
                if (self.async_logger) |*async_logger| {
                    async_logger.deinit();
                }

                // Clean up managed event loop if we created one
                if (self.managed_event_loop) |managed_loop| {
                    managed_loop.deinit();
                    // Note: We don't free the loop here because we need the allocator
                    // Users should call deinitWithAllocator if they used managed event loop
                }
            }
        }

        /// Deinitialize OTel logger with allocator (needed for managed event loop cleanup)
        pub fn deinitWithAllocator(self: *Self, allocator: std.mem.Allocator) void {
            if (async_mode) {
                if (self.async_logger) |*async_logger| {
                    async_logger.deinit();
                }

                // Clean up managed event loop if we created one
                if (self.managed_event_loop) |managed_loop| {
                    managed_loop.deinit();
                    allocator.destroy(managed_loop);
                }
            }
        }

        /// Run the managed event loop once (non-blocking)
        /// Only works if logger was initialized with managed event loop
        pub fn runEventLoop(self: *Self) !void {
            if (async_mode) {
                if (self.managed_event_loop) |managed_loop| {
                    try managed_loop.run(.no_wait);
                } else {
                    return error.NoManagedEventLoop;
                }
            }
        }

        /// Run the managed event loop until completion
        /// Only works if logger was initialized with managed event loop
        pub fn runEventLoopUntilDone(self: *Self) !void {
            if (async_mode) {
                if (self.managed_event_loop) |managed_loop| {
                    try managed_loop.run(.until_done);
                } else {
                    return error.NoManagedEventLoop;
                }
            }
        }

        fn shouldRedact(self: *const Self, key: []const u8) bool {
            inline for (compile_time_redacted_fields) |redacted_field| {
                if (std.mem.eql(u8, redacted_field, key)) return true;
            }
            return if (self.redaction_config) |rc| rc.shouldRedact(key) else false;
        }

        pub fn trace(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.trace, message, null, fields_struct);
        }

        pub fn debug(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.debug, message, null, fields_struct);
        }

        pub fn info(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.info, message, null, fields_struct);
        }

        pub fn infoWithTrace(self: *Self, message: []const u8, trace_ctx: trace_mod.TraceContext, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.info, message, trace_ctx, fields_struct);
        }

        pub fn warn(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.warn, message, null, fields_struct);
        }

        pub fn err(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.err, message, null, fields_struct);
        }

        pub fn fatal(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.fatal, message, null, fields_struct);
        }

        /// Core OTel logging implementation - anonymous structs only for simplicity
        fn logInternal(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: ?trace_mod.TraceContext,
            fields_input: anytype,
        ) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            const InputType = @TypeOf(fields_input);
            const input_info = @typeInfo(InputType);

            // Handle field arrays (slices or pointers to arrays of Field)
            if (comptime isFieldArray(InputType)) {
                self.logWithTrace(level, message, trace_ctx, fields_input);
                return;
            }

            // Handle anonymous structs
            if (input_info == .@"struct") {
                const fields_array = self.structToFields(fields_input);
                self.logWithTrace(level, message, trace_ctx, &fields_array);
                return;
            }

            // Handle pointers to structs/tuples
            if (input_info == .pointer and input_info.pointer.size == .one) {
                const pointed_type = input_info.pointer.child;
                const pointed_info = @typeInfo(pointed_type);

                if (pointed_info == .@"struct") {
                    // It's a pointer to struct - dereference and convert
                    const fields_array = self.structToFields(fields_input.*);
                    self.logWithTrace(level, message, trace_ctx, &fields_array);
                    return;
                }

                // Handle pointers to arrays of Fields
                if (pointed_info == .array and pointed_info.array.child == field.Field) {
                    self.logWithTrace(level, message, trace_ctx, fields_input);
                    return;
                }
            }

            @compileError("Expected struct or field array, got " ++ @typeName(InputType));
        }

        /// Check if a type is a field array (slice or pointer to array of Field)
        fn isFieldArray(comptime T: type) bool {
            const type_info = @typeInfo(T);
            switch (type_info) {
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == field.Field) {
                        return true;
                    }
                    if (ptr.size == .one) {
                        const pointed_info = @typeInfo(ptr.child);
                        if (pointed_info == .array and pointed_info.array.child == field.Field) {
                            return true;
                        }
                    }
                    return false;
                },
                else => return false,
            }
        }

        fn logWithTrace(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: ?trace_mod.TraceContext,
            attributes: []const field.Field,
        ) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(attributes.len <= max_fields);

            if (@intFromEnum(level) < @intFromEnum(self.level)) return;

            // Create OTel LogRecord
            const log_record = otel.LogRecord.init(
                level,
                message,
                attributes,
                trace_ctx,
                self.resource,
                self.instrumentation_scope,
            );

            if (async_mode) {
                if (self.async_logger) |*async_logger| {
                    async_logger.logAsync(log_record) catch |async_err| {
                        // TODO: Consider incrementing a dropped_logs counter for monitoring
                        // For now, we silently drop logs to prevent blocking the caller
                        _ = async_err;
                        return;
                    };
                    return;
                }
            }

            self.formatAndWrite(log_record);
        }

        // ========================================
        // ERGONOMIC API - Anonymous Struct Fields
        // ========================================

        /// Convert anonymous struct to field array at compile time.
        /// This enables ergonomic logging syntax like:
        /// logger.info("message", .{ .user_id = "123", .success = true });
        fn structToFields(self: *const Self, fields_struct: anytype) [getFieldCount(@TypeOf(fields_struct))]field.Field {
            _ = self;
            const struct_info = @typeInfo(@TypeOf(fields_struct));
            if (struct_info != .@"struct") {
                @compileError("Expected struct, got " ++ @typeName(@TypeOf(fields_struct)));
            }

            const struct_fields = struct_info.@"struct".fields;
            comptime {
                if (struct_fields.len > max_fields) {
                    @compileError("Too many fields: " ++ std.fmt.comptimePrint("{}", .{struct_fields.len}) ++
                        " > max_fields: " ++ std.fmt.comptimePrint("{}", .{max_fields}));
                }
            }

            var result: [struct_fields.len]field.Field = undefined;

            inline for (struct_fields, 0..) |struct_field, i| {
                const field_value = @field(fields_struct, struct_field.name);
                result[i] = convertToField(struct_field.name, field_value);
            }

            return result;
        }

        /// Get field count for compile-time array sizing
        fn getFieldCount(comptime T: type) comptime_int {
            const type_info = @typeInfo(T);

            // Handle structs directly
            if (type_info == .@"struct") {
                return type_info.@"struct".fields.len;
            }

            // Handle pointers to structs/tuples
            if (type_info == .pointer and type_info.pointer.size == .one) {
                const pointed_type = type_info.pointer.child;
                const pointed_info = @typeInfo(pointed_type);

                if (pointed_info == .@"struct") {
                    return pointed_info.@"struct".fields.len;
                }

                // Handle pointers to arrays of fields
                if (pointed_info == .array and pointed_info.array.child == field.Field) {
                    return pointed_info.array.len;
                }
            }

            // Handle slices of fields
            if (type_info == .pointer and type_info.pointer.size == .slice and type_info.pointer.child == field.Field) {
                // For slices, we can't determine length at compile time, so this should not be used
                @compileError("Cannot determine field count for slice at compile time");
            }

            @compileError("Expected struct, pointer to struct, or field array, got " ++ @typeName(T));
        }

        /// Convert various types to Field.Value at compile time.
        /// Supports strings, integers, floats, booleans, optionals, and null values.
        fn convertToField(comptime name: []const u8, value: anytype) field.Field {
            const T = @TypeOf(value);
            const type_info = @typeInfo(T);

            return switch (type_info) {
                .pointer => |ptr_info| switch (ptr_info.size) {
                    .slice => if (ptr_info.child == u8)
                        field.Field.string(name, value)
                    else
                        @compileError("Unsupported slice type: " ++ @typeName(T)),
                    .one => {
                        // Handle string literals like "hello" which are *const [N:0]u8
                        const child_info = @typeInfo(ptr_info.child);
                        if (child_info == .array and child_info.array.child == u8) {
                            return field.Field.string(name, value);
                        } else {
                            @compileError("Unsupported pointer type: " ++ @typeName(T));
                        }
                    },
                    else => @compileError("Unsupported pointer type: " ++ @typeName(T)),
                },
                .array => |arr_info| if (arr_info.child == u8)
                    field.Field.string(name, &value)
                else
                    @compileError("Unsupported array type: " ++ @typeName(T)),
                .int => field.Field.int(name, @as(i64, @intCast(value))),
                .comptime_int => field.Field.int(name, @as(i64, value)),
                .float => field.Field.float(name, @as(f64, @floatCast(value))),
                .comptime_float => field.Field.float(name, @as(f64, value)),
                .bool => field.Field.boolean(name, value),
                .optional => if (value) |v|
                    convertToField(name, v)
                else
                    field.Field.null_value(name),
                .null => field.Field.null_value(name),
                .@"struct" => {
                    // Handle pre-constructed Field objects
                    if (T == field.Field) {
                        return value;
                    } else {
                        @compileError("Unsupported struct type: " ++ @typeName(T) ++ " for field '" ++ name ++ "'");
                    }
                },
                else => @compileError("Unsupported field type: " ++ @typeName(T) ++ " for field '" ++ name ++ "'"),
            };
        }

        fn formatAndWrite(self: *Self, log_record: otel.LogRecord) void {
            var buffer: [buffer_size]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buffer);
            const writer = fbs.writer();

            if (otel_config.enable_otel_format) {
                self.formatOTelJson(writer, log_record) catch return;
            } else {
                self.formatCompatibleJson(writer, log_record) catch return;
            }

            const formatted_len: u32 = @intCast(fbs.getPos() catch return);

            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.writer.write(buffer[0..formatted_len]) catch {};
        }

        fn formatOTelJson(self: *Self, writer: anytype, log_record: otel.LogRecord) !void {
            assert(@TypeOf(writer) != void);
            assert(log_record.attributes.len <= max_fields);

            try writer.writeAll("{");
            try self.writeOTelTimestamps(writer, log_record);
            try self.writeOTelSeverity(writer, log_record);
            try self.writeOTelBody(writer, log_record);
            try self.writeOTelAttributes(writer, log_record);
            try self.writeOTelTraceContext(writer, log_record);
            try self.writeOTelResource(writer, log_record);
            try self.writeOTelScope(writer, log_record);
            try writer.writeAll("}\n");
        }

        fn writeOTelTimestamps(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;
            assert(log_record.timestamp > 0);
            assert(log_record.observed_timestamp > 0);

            try writer.print("\"timeUnixNano\":\"{}\",", .{log_record.timestamp});
            try writer.print("\"observedTimeUnixNano\":\"{}\",", .{log_record.observed_timestamp});
        }

        fn writeOTelSeverity(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;
            assert(@intFromEnum(log_record.severity_number) <= 24);

            try writer.print("\"severityNumber\":{},", .{@intFromEnum(log_record.severity_number)});
            if (log_record.severity_text) |severity_text| {
                try writer.print("\"severityText\":\"{s}\",", .{severity_text});
            }
        }

        fn writeOTelBody(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;

            try writer.writeAll("\"body\":{\"stringValue\":\"");
            if (log_record.body.asString()) |body_str| {
                try escape.write(cfg, writer, body_str);
            }
            try writer.writeAll("\"},");
        }

        fn writeOTelAttributes(self: *Self, writer: anytype, log_record: otel.LogRecord) !void {
            assert(log_record.attributes.len <= max_fields);

            try writer.writeAll("\"attributes\":[");
            for (log_record.attributes, 0..) |attr, i| {
                if (i > 0) {
                    try writer.writeAll(",");
                }
                try self.formatOTelAttribute(writer, attr);
            }
            try writer.writeAll("],");
        }

        fn writeOTelTraceContext(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;

            if (log_record.trace_id) |trace_id| {
                var trace_hex: [32]u8 = undefined;
                _ = trace_mod.bytes_to_hex_lowercase(&trace_id, &trace_hex) catch return;
                try writer.print("\"traceId\":\"{s}\",", .{trace_hex});
            }
            if (log_record.span_id) |span_id| {
                var span_hex: [16]u8 = undefined;
                _ = trace_mod.bytes_to_hex_lowercase(&span_id, &span_hex) catch return;
                try writer.print("\"spanId\":\"{s}\",", .{span_hex});
            }
            if (log_record.trace_flags) |flags| {
                try writer.print("\"flags\":{},", .{flags.toU8()});
            }
        }

        fn writeOTelResource(self: *Self, writer: anytype, log_record: otel.LogRecord) !void {
            assert(log_record.resource.service_name.len > 0);

            try writer.writeAll("\"resource\":{\"attributes\":[");
            try self.formatResourceAttributes(writer, log_record.resource);
            try writer.writeAll("]},");
        }

        fn writeOTelScope(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;
            assert(log_record.instrumentation_scope.name.len > 0);

            try writer.writeAll("\"scope\":{\"name\":\"");
            try writer.writeAll(log_record.instrumentation_scope.name);
            try writer.writeAll("\"");
            if (log_record.instrumentation_scope.version) |version| {
                try writer.print(",\"version\":\"{s}\"", .{version});
            }
            try writer.writeAll("}");
        }

        fn formatCompatibleJson(self: *Self, writer: anytype, log_record: otel.LogRecord) !void {
            assert(@TypeOf(writer) != void);
            assert(log_record.attributes.len <= max_fields);

            try self.writeCompatibleHeader(writer, log_record);
            try self.writeCompatibleTraceContext(writer, log_record);
            try self.writeCompatibleResource(writer, log_record);
            try self.writeCompatibleAttributes(writer, log_record);
            try writer.writeAll("}\n");
        }

        fn writeCompatibleHeader(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;
            assert(log_record.timestamp > 0);

            try writer.writeAll("{\"level\":\"");
            try writer.writeAll(log_record.severity_text orelse "UNKNOWN");
            try writer.writeAll("\",\"msg\":\"");

            if (log_record.body.asString()) |body_str| {
                try escape.write(cfg, writer, body_str);
            }

            try writer.print(
                "\",\"ts\":{},\"tid\":{},\"severity_number\":{}",
                .{ log_record.timestamp / 1_000_000, std.Thread.getCurrentId(), @intFromEnum(log_record.severity_number) },
            );
        }

        fn writeCompatibleTraceContext(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;

            if (log_record.trace_id) |trace_id| {
                var trace_hex: [32]u8 = undefined;
                _ = trace_mod.bytes_to_hex_lowercase(&trace_id, &trace_hex) catch return;
                try writer.print(",\"trace\":\"{s}\"", .{trace_hex});
            }
            if (log_record.span_id) |span_id| {
                var span_hex: [16]u8 = undefined;
                _ = trace_mod.bytes_to_hex_lowercase(&span_id, &span_hex) catch return;
                try writer.print(",\"span\":\"{s}\"", .{span_hex});
            }
        }

        fn writeCompatibleResource(self: *const Self, writer: anytype, log_record: otel.LogRecord) !void {
            _ = self;
            assert(log_record.resource.service_name.len > 0);

            try writer.print(",\"service.name\":\"{s}\"", .{log_record.resource.service_name});
            if (log_record.resource.service_version) |version| {
                try writer.print(",\"service.version\":\"{s}\"", .{version});
            }
        }

        fn writeCompatibleAttributes(self: *Self, writer: anytype, log_record: otel.LogRecord) !void {
            assert(log_record.attributes.len <= max_fields);

            for (log_record.attributes) |attr| {
                try writer.writeAll(",\"");
                try escape.write(cfg, writer, attr.key);
                try writer.writeAll("\":");

                if (self.shouldRedact(attr.key)) {
                    try self.writeRedactedCompatibleValue(writer, attr.value);
                } else {
                    try self.formatFieldValue(writer, attr.value);
                }
            }
        }

        fn writeRedactedCompatibleValue(self: *const Self, writer: anytype, value: field.Field.Value) !void {
            _ = self;
            assert(@TypeOf(writer) != void);

            const redacted_type: field.Field.RedactedType = switch (value) {
                .string => .string,
                .int => .int,
                .uint => .uint,
                .float => .float,
                .boolean => .any,
                .null => .any,
                .redacted => |r| r.value_type,
            };
            try writer.print("\"[REDACTED:{s}]\"", .{@tagName(redacted_type)});
        }

        fn formatOTelAttribute(self: *Self, writer: anytype, attr: field.Field) !void {
            try writer.writeAll("{\"key\":\"");
            try escape.write(cfg, writer, attr.key);
            try writer.writeAll("\",\"value\":");

            if (self.shouldRedact(attr.key)) {
                try writer.writeAll("{\"stringValue\":\"[REDACTED]\"}");
            } else {
                switch (attr.value) {
                    .string => |s| {
                        try writer.writeAll("{\"stringValue\":\"");
                        try escape.write(cfg, writer, s);
                        try writer.writeAll("\"}");
                    },
                    .int => |i| {
                        try writer.writeAll("{\"intValue\":\"");
                        try writer.print("{}", .{i});
                        try writer.writeAll("\"}");
                    },
                    .uint => |u| {
                        try writer.writeAll("{\"intValue\":\"");
                        try writer.print("{}", .{u});
                        try writer.writeAll("\"}");
                    },
                    .float => |f| {
                        try writer.writeAll("{\"doubleValue\":");
                        try writer.print("{d:.5}", .{f});
                        try writer.writeAll("}");
                    },
                    .boolean => |b| {
                        try writer.writeAll("{\"boolValue\":");
                        try writer.print("{}", .{b});
                        try writer.writeAll("}");
                    },
                    .null => try writer.writeAll("{\"stringValue\":null}"),
                    .redacted => try writer.writeAll("{\"stringValue\":\"[REDACTED]\"}"),
                }
            }
            try writer.writeAll("}");
        }

        fn formatFieldValue(self: *Self, writer: anytype, value: field.Field.Value) !void {
            _ = self;
            switch (value) {
                .string => |s| {
                    try writer.writeByte('"');
                    try escape.write(cfg, writer, s);
                    try writer.writeByte('"');
                },
                .int => |i| try writer.print("{}", .{i}),
                .uint => |u| try writer.print("{}", .{u}),
                .float => |f| try writer.print("{d:.5}", .{f}),
                .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
                .null => try writer.writeAll("null"),
                .redacted => try writer.writeAll("\"[REDACTED]\""),
            }
        }

        fn formatResourceAttributes(self: *Self, writer: anytype, resource: otel.Resource) !void {
            _ = self;
            var first = true;

            // Service attributes
            if (!first) try writer.writeAll(",");
            try writer.writeAll("{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
            try writer.writeAll(resource.service_name);
            try writer.writeAll("\"}}");
            first = false;

            if (resource.service_version) |version| {
                try writer.writeAll(",");
                try writer.writeAll("{\"key\":\"service.version\",\"value\":{\"stringValue\":\"");
                try writer.writeAll(version);
                try writer.writeAll("\"}}");
            }

            // Process attributes
            if (resource.process_pid) |pid| {
                try writer.writeAll(",");
                try writer.writeAll("{\"key\":\"process.pid\",\"value\":{\"intValue\":\"");
                try writer.print("{}", .{pid});
                try writer.writeAll("\"}}");
            }

            // Host attributes
            if (resource.host_arch) |arch| {
                try writer.writeAll(",");
                try writer.writeAll("{\"key\":\"host.arch\",\"value\":{\"stringValue\":\"");
                try writer.writeAll(arch);
                try writer.writeAll("\"}}");
            }

            // OS attributes
            if (resource.os_type) |os_type| {
                try writer.writeAll(",");
                try writer.writeAll("{\"key\":\"os.type\",\"value\":{\"stringValue\":\"");
                try writer.writeAll(os_type);
                try writer.writeAll("\"}}");
            }
        }
    };
}

fn OTelAsyncLogger(comptime otel_config: otel.OTelConfig) type {
    _ = otel_config;
    return struct {
        const Self = @This();
        const BUFFER_SIZE = 2048;
        const RING_SIZE = 1024;

        const LogEntry = struct {
            data: [BUFFER_SIZE]u8,
            len: u32,
            timestamp_ns: u64,
        };

        const StaticRingBuffer = struct {
            entries: [RING_SIZE]LogEntry,
            write_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
            read_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

            fn tryPush(self: *@This(), entry: LogEntry) bool {
                const current_write = self.write_pos.load(.acquire);
                const current_read = self.read_pos.load(.acquire);
                assert(current_write >= current_read);

                const queue_size = current_write - current_read;
                if (queue_size >= RING_SIZE) {
                    return false;
                }

                const index = current_write & (RING_SIZE - 1);
                assert(index < RING_SIZE);

                self.entries[index] = entry;
                self.write_pos.store(current_write + 1, .release);
                return true;
            }

            fn tryPop(self: *@This()) ?LogEntry {
                const current_read = self.read_pos.load(.acquire);
                const current_write = self.write_pos.load(.acquire);
                assert(current_write >= current_read);

                if (current_read == current_write) {
                    return null;
                }

                const index = current_read & (RING_SIZE - 1);
                assert(index < RING_SIZE);

                const entry = self.entries[index];
                self.read_pos.store(current_read + 1, .release);
                return entry;
            }
        };

        writer: std.io.AnyWriter,
        loop: *xev.Loop,
        ring_buffer: StaticRingBuffer,
        shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(
            allocator: std.mem.Allocator,
            writer: std.io.AnyWriter,
            loop: *xev.Loop,
        ) !Self {
            _ = allocator;
            assert(@TypeOf(writer) == std.io.AnyWriter);
            assert(@TypeOf(loop.*) == xev.Loop);

            var ring_buffer = StaticRingBuffer{
                .entries = undefined,
            };

            for (&ring_buffer.entries) |*entry| {
                entry.* = LogEntry{
                    .data = undefined,
                    .len = 0,
                    .timestamp_ns = 0,
                };
            }

            return Self{
                .writer = writer,
                .loop = loop,
                .ring_buffer = ring_buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            assert(@TypeOf(self.*) == Self);
            self.shutdown.store(true, .release);
        }

        pub fn logAsync(self: *Self, log_record: otel.LogRecord) !void {
            assert(@TypeOf(self.*) == Self);
            assert(log_record.attributes.len <= 64);

            // Implementation would format the log_record and add to ring buffer
            // This is a simplified placeholder that maintains TigerStyle compliance
            // For now, we just validate the log_record structure
            assert(log_record.timestamp > 0);
        }
    };
}

const testing = std.testing;

test "OTelLogger creation and basic functionality" {
    const test_allocator = testing.allocator;

    var buffer = std.ArrayList(u8).init(test_allocator);
    defer buffer.deinit();

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-logger"),
    };

    var logger = OTelLogger(otel_config).init(buffer.writer().any());

    logger.info("Test message", &.{
        field.Field.string("key", "value"),
        field.Field.int("count", 42),
    });

    try testing.expect(buffer.items.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "Test message"));
    try testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "test-service"));
}

test "OTel format output" {
    const test_allocator = testing.allocator;

    var buffer = std.ArrayList(u8).init(test_allocator);
    defer buffer.deinit();

    const otel_config = comptime otel.OTelConfig{
        .enable_otel_format = true,
        .resource = otel.Resource.init().withService("otel-test", "2.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("otel-logger"),
    };

    var logger = OTelLogger(otel_config).init(buffer.writer().any());

    logger.info("OTel test message", &.{
        field.Field.string("environment", "test"),
    });

    const output = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "timeUnixNano"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "severityNumber"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "body"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "attributes"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "resource"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "scope"));
}

test "OTel unified API" {
    const test_allocator = testing.allocator;

    var buffer = std.ArrayList(u8).init(test_allocator);
    defer buffer.deinit();

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-logger"),
    };

    var logger = OTelLogger(otel_config).init(buffer.writer().any());

    // Test unified API with various field types
    logger.info("User authentication", .{
        .user_id = "12345",
        .username = "alice",
        .attempt = @as(i64, 1),
        .success = true,
        .duration_ms = 45.7,
        .optional_field = @as(?[]const u8, null),
    });

    const output = buffer.items;

    // Verify message and fields are present
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "User authentication"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"user_id\":\"12345\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"username\":\"alice\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"attempt\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"success\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"duration_ms\":45.7"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"optional_field\":null"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "test-service"));
}
