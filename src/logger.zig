const std = @import("std");
const assert = std.debug.assert;
const xev = @import("xev");

const config = @import("config.zig");
const field = @import("field.zig");
const trace_mod = @import("trace.zig");

const correlation = @import("correlation.zig");
const redaction = @import("redaction.zig");
const escape = @import("string_escape.zig");

pub fn Logger(comptime cfg: config.Config) type {
    return LoggerWithRedaction(cfg, .{});
}

pub fn LoggerWithRedaction(comptime cfg: config.Config, comptime redaction_options: redaction.RedactionOptions) type {
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
        const async_queue_size = cfg.async_queue_size;
        const compile_time_redacted_fields = redaction_options.redacted_fields;

        writer: std.io.AnyWriter,
        mutex: std.Thread.Mutex = std.Thread.Mutex{},
        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,
        async_logger: if (async_mode) ?AsyncLogger(cfg) else void = if (async_mode) null else {},
        managed_event_loop: if (async_mode) ?*xev.Loop else void = if (async_mode) null else {},

        pub fn init(output_writer: std.io.AnyWriter) Self {
            return initWithRedaction(output_writer, null);
        }

        pub fn initWithRedaction(output_writer: std.io.AnyWriter, redaction_cfg: ?*const redaction.RedactionConfig) Self {
            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@intFromEnum(cfg.level) <= @intFromEnum(config.Level.fatal));

            const logger_result = Self{
                .writer = output_writer,
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .async_logger = if (async_mode) null else {},
                .managed_event_loop = if (async_mode) null else {},
            };

            assert(@TypeOf(logger_result.writer) == std.io.AnyWriter);
            assert(@intFromEnum(logger_result.level) <= @intFromEnum(config.Level.fatal));
            return logger_result;
        }

        /// Initialize async logger with managed event loop (recommended)
        pub fn initAsync(
            output_writer: std.io.AnyWriter,
            memory_allocator: std.mem.Allocator,
        ) !Self {
            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@TypeOf(memory_allocator) == std.mem.Allocator);

            const managed_loop = try memory_allocator.create(xev.Loop);
            assert(@TypeOf(managed_loop) == *xev.Loop);

            managed_loop.* = try xev.Loop.init(.{});
            assert(@TypeOf(managed_loop.*) == xev.Loop);

            var logger = try initAsyncWithRedaction(output_writer, managed_loop, memory_allocator, null);
            logger.managed_event_loop = managed_loop;

            assert(logger.managed_event_loop != null);
            return logger;
        }

        /// Initialize async logger with existing event loop (advanced usage)
        pub fn initAsyncWithEventLoop(
            output_writer: std.io.AnyWriter,
            event_loop: *xev.Loop,
            memory_allocator: std.mem.Allocator,
        ) !Self {
            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@TypeOf(event_loop.*) == xev.Loop);
            assert(@TypeOf(memory_allocator) == std.mem.Allocator);

            var logger = try initAsyncWithRedaction(output_writer, event_loop, memory_allocator, null);
            logger.managed_event_loop = null;

            assert(logger.managed_event_loop == null);
            assert(logger.async_logger != null);
            return logger;
        }

        /// Initialize async logger with redaction and managed event loop
        pub fn initAsyncWithRedactionManaged(
            output_writer: std.io.AnyWriter,
            memory_allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@TypeOf(memory_allocator) == std.mem.Allocator);

            const managed_loop = try memory_allocator.create(xev.Loop);
            assert(@TypeOf(managed_loop) == *xev.Loop);

            managed_loop.* = try xev.Loop.init(.{});
            assert(@TypeOf(managed_loop.*) == xev.Loop);

            var logger = try initAsyncWithRedaction(output_writer, managed_loop, memory_allocator, redaction_cfg);
            logger.managed_event_loop = managed_loop;

            assert(logger.managed_event_loop != null);
            return logger;
        }

        /// Initialize async logger with redaction and existing event loop
        pub fn initAsyncWithRedactionAndEventLoop(
            output_writer: std.io.AnyWriter,
            event_loop: *xev.Loop,
            memory_allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@TypeOf(event_loop.*) == xev.Loop);
            assert(@TypeOf(memory_allocator) == std.mem.Allocator);

            var logger = try initAsyncWithRedaction(output_writer, event_loop, memory_allocator, redaction_cfg);
            logger.managed_event_loop = null;

            assert(logger.managed_event_loop == null);
            assert(logger.async_logger != null);
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

            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@TypeOf(event_loop.*) == xev.Loop);
            assert(@TypeOf(memory_allocator) == std.mem.Allocator);
            assert(@intFromEnum(cfg.level) <= @intFromEnum(config.Level.fatal));
            assert(async_queue_size > 0);
            assert(async_queue_size <= 1048576);
            assert(buffer_size >= 256);
            assert(buffer_size <= 65536);
            assert(cfg.batch_size > 0);
            assert(cfg.batch_size <= 1024);

            const async_logger_instance = try AsyncLogger(cfg).init(memory_allocator, output_writer, event_loop, async_queue_size, cfg.batch_size);

            const logger_result = Self{
                .writer = output_writer,
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .async_logger = async_logger_instance,
                .managed_event_loop = null,
            };

            assert(@TypeOf(logger_result.writer) == std.io.AnyWriter);
            assert(@intFromEnum(logger_result.level) <= @intFromEnum(config.Level.fatal));
            assert(logger_result.async_logger != null);
            return logger_result;
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

        /// Deinitialize logger with allocator (needed for managed event loop cleanup)
        pub fn deinitWithAllocator(self: *Self, allocator: std.mem.Allocator) void {
            assert(@TypeOf(self.*) == Self);
            assert(@TypeOf(allocator) == std.mem.Allocator);

            if (async_mode) {
                if (self.async_logger) |*async_logger| {
                    async_logger.deinit();
                }

                if (self.managed_event_loop) |managed_loop| {
                    assert(@TypeOf(managed_loop.*) == xev.Loop);
                    managed_loop.deinit();
                    allocator.destroy(managed_loop);
                }
            }

            assert(@TypeOf(self.*) == Self);
        }

        /// Run the managed event loop once (non-blocking)
        /// Only works if logger was initialized with managed event loop
        pub fn runEventLoop(self: *Self) !void {
            assert(@TypeOf(self.*) == Self);

            if (!async_mode) {
                return;
            }

            if (self.managed_event_loop) |managed_loop| {
                assert(@TypeOf(managed_loop.*) == xev.Loop);
                try managed_loop.run(.no_wait);
            } else {
                return error.NoManagedEventLoop;
            }
        }

        /// Run the managed event loop until completion
        /// Only works if logger was initialized with managed event loop
        pub fn runEventLoopUntilDone(self: *Self) !void {
            assert(@TypeOf(self.*) == Self);

            if (!async_mode) {
                return;
            }

            if (self.managed_event_loop) |managed_loop| {
                assert(@TypeOf(managed_loop.*) == xev.Loop);
                try managed_loop.run(.until_done);
            } else {
                return error.NoManagedEventLoop;
            }
        }

        fn shouldRedact(self: *const Self, key: []const u8) bool {
            assert(key.len > 0);

            inline for (compile_time_redacted_fields) |redacted_field| {
                if (std.mem.eql(u8, redacted_field, key)) return true;
            }

            return if (self.redaction_config) |rc| rc.shouldRedact(key) else false;
        }

        pub fn trace(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.trace, message, default_trace_ctx, fields_struct);
        }

        pub fn debug(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.debug, message, default_trace_ctx, fields_struct);
        }

        pub fn info(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.info, message, default_trace_ctx, fields_struct);
        }

        pub fn infoWithTrace(
            self: *Self,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields_struct: anytype,
        ) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            self.logInternal(.info, message, trace_ctx, fields_struct);
        }

        pub fn warn(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.warn, message, default_trace_ctx, fields_struct);
        }

        pub fn err(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.err, message, default_trace_ctx, fields_struct);
        }

        pub fn fatal(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.fatal, message, default_trace_ctx, fields_struct);
        }

        // ========================================
        // ERGONOMIC API - Anonymous Struct Fields
        // ========================================

        /// Convert anonymous struct to field array at compile time
        fn structToFields(self: *const Self, fields_struct: anytype) [getFieldCount(@TypeOf(fields_struct))]field.Field {
            const T = @TypeOf(fields_struct);
            const struct_info = @typeInfo(T);
            assert(struct_info == .@"struct" or (struct_info == .pointer and struct_info.pointer.size == .one));

            if (struct_info == .@"struct") {
                return self.convertDirectStructToFields(fields_struct);
            }

            if (struct_info == .pointer) {
                assert(struct_info.pointer.size == .one);
                return self.convertPointerStructToFields(fields_struct);
            }

            @compileError("Expected struct or pointer to struct, got " ++ @typeName(T));
        }

        fn convertDirectStructToFields(self: *const Self, fields_struct: anytype) [getFieldCount(@TypeOf(fields_struct))]field.Field {
            _ = self;
            const struct_info = @typeInfo(@TypeOf(fields_struct));
            assert(struct_info == .@"struct");

            const struct_fields = struct_info.@"struct".fields;
            assert(struct_fields.len <= max_fields);

            var fields: [struct_fields.len]field.Field = undefined;
            inline for (struct_fields, 0..) |struct_field, i| {
                const field_value = @field(fields_struct, struct_field.name);
                fields[i] = convertToField(struct_field.name, field_value);
            }

            assert(fields.len == struct_fields.len);
            return fields;
        }

        fn convertPointerStructToFields(self: *const Self, fields_struct: anytype) [getFieldCount(@TypeOf(fields_struct))]field.Field {
            const T = @TypeOf(fields_struct);
            const struct_info = @typeInfo(T);
            assert(struct_info == .pointer);
            assert(struct_info.pointer.size == .one);

            const pointed_type = struct_info.pointer.child;
            const pointed_info = @typeInfo(pointed_type);
            assert(pointed_info == .@"struct");

            return self.structToFields(fields_struct.*);
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

        /// Utility for dynamic field logging (rare use cases)
        /// Most logging should use the anonymous struct API
        pub fn logDynamic(self: *Self, level: config.Level, message: []const u8, dynamic_fields: []const field.Field) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(level, message, default_trace_ctx, dynamic_fields);
        }

        /// Convert various types to Field.Value at compile time
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

        pub fn spanStart(self: *Self, operation_name: []const u8, operation_fields_struct: anytype) correlation.Span {
            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(operation_name.len > 0);
            assert(operation_name.len < 256);

            const current_context = correlation.getCurrentTaskContext();
            assert(!trace_mod.is_all_zero_id(current_context.trace_context.trace_id[0..]));

            const current_span_bytes = current_context.currentSpan();
            const span_created = correlation.Span.init(operation_name, current_span_bytes, current_context.trace_context);
            assert(span_created.id >= 1);

            const span_fields = self.buildSpanStartFields(span_created, operation_fields_struct);
            assert(span_fields.len >= 4);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.info, operation_name, default_trace_ctx, span_fields.constSlice());

            assert(span_created.id >= 1);
            assert(span_created.task_id >= 1);
            return span_created;
        }

        fn buildSpanStartFields(self: *Self, span_created: correlation.Span, operation_fields_struct: anytype) std.BoundedArray(field.Field, max_fields + 4) {
            assert(span_created.id >= 1);
            assert(span_created.task_id >= 1);
            assert(span_created.thread_id >= 1);

            var span_fields_array = std.BoundedArray(field.Field, max_fields + 4).init(0) catch @panic("BoundedArray init failed with valid capacity");

            span_fields_array.append(field.Field.string("span_mark", "start")) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("span_id", span_created.id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("task_id", span_created.task_id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("thread_id", span_created.thread_id)) catch @panic("BoundedArray append failed with sufficient capacity");

            const fields_array = self.structToFields(operation_fields_struct);
            for (fields_array) |field_item| {
                span_fields_array.append(field_item) catch break;
            }

            assert(span_fields_array.len >= 4);
            assert(span_fields_array.len <= max_fields + 4);
            return span_fields_array;
        }

        pub fn spanEnd(self: *Self, completed_span: correlation.Span, completion_fields_struct: anytype) void {
            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(completed_span.id >= 1);
            assert(completed_span.task_id >= 1);
            assert(completed_span.thread_id >= 1);

            const span_end_time_ns = std.time.nanoTimestamp();
            const span_duration_ns = span_end_time_ns - completed_span.start_time;
            assert(span_duration_ns >= 0);
            assert(span_end_time_ns > completed_span.start_time);

            const span_fields = self.buildSpanEndFields(completed_span, span_duration_ns, completion_fields_struct);
            assert(span_fields.len >= 5);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.info, completed_span.name, default_trace_ctx, span_fields.constSlice());
        }

        fn buildSpanEndFields(self: *Self, completed_span: correlation.Span, span_duration_ns: i128, completion_fields_struct: anytype) std.BoundedArray(field.Field, max_fields + 5) {
            assert(completed_span.id >= 1);
            assert(completed_span.task_id >= 1);
            assert(completed_span.thread_id >= 1);
            assert(span_duration_ns >= 0);

            var span_fields_array = std.BoundedArray(field.Field, max_fields + 5).init(0) catch @panic("BoundedArray init failed with valid capacity");

            span_fields_array.append(field.Field.string("span_mark", "end")) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("span_id", completed_span.id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("task_id", completed_span.task_id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("thread_id", completed_span.thread_id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("duration_ns", @as(u64, @intCast(span_duration_ns)))) catch @panic("BoundedArray append failed with sufficient capacity");

            const fields_array = self.structToFields(completion_fields_struct);
            for (fields_array) |field_item| {
                span_fields_array.append(field_item) catch break;
            }

            assert(span_fields_array.len >= 5);
            assert(span_fields_array.len <= max_fields + 5);
            return span_fields_array;
        }

        /// Core logging implementation - anonymous structs only for simplicity
        fn logInternal(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
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
            trace_ctx: trace_mod.TraceContext,
            fields: []const field.Field,
        ) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(fields.len <= 1024);
            assert(message.len > 0);
            assert(message.len < buffer_size);

            if (@intFromEnum(level) < @intFromEnum(self.level)) {
                return;
            }

            if (async_mode) {
                if (self.async_logger) |*async_logger| {
                    async_logger.log(level, message, fields) catch {
                        // TODO: Consider incrementing a dropped_logs counter for monitoring
                        // For now, we silently drop logs to prevent blocking the caller
                        return;
                    };
                    return;
                }
            }

            self.formatAndWriteLog(level, message, trace_ctx, fields);
        }

        fn formatAndWriteLog(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields: []const field.Field,
        ) void {
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(message.len > 0);
            assert(message.len < buffer_size);
            assert(fields.len <= 1024);

            const actual_fields = if (fields.len > max_fields) fields[0..max_fields] else fields;
            assert(actual_fields.len <= max_fields);

            var buffer: [buffer_size]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buffer);
            const writer = fbs.writer();

            self.writeLogHeader(writer, level, message, trace_ctx) catch return;
            self.writeLogFields(writer, actual_fields) catch return;
            self.writeLogFooter(writer) catch return;

            const formatted_len: u32 = @intCast(fbs.getPos() catch return);
            assert(formatted_len > 0);
            assert(formatted_len <= buffer_size);

            self.writeToOutput(buffer[0..formatted_len]);
        }

        fn writeToOutput(self: *Self, data: []const u8) void {
            assert(@TypeOf(self.*) == Self);
            assert(data.len > 0);
            assert(data.len <= buffer_size);

            self.mutex.lock();
            defer self.mutex.unlock();

            assert(@TypeOf(self.writer) == std.io.AnyWriter);
            self.writer.writeAll(data) catch return;
        }

        fn writeLogHeader(
            self: *const Self,
            writer: anytype,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
        ) !void {
            _ = self;
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(message.len > 0);

            try writer.writeAll("{\"level\":\"");
            try writer.writeAll(level.string());
            try writer.writeAll("\",\"msg\":\"");
            try escape.write(cfg, writer, message);
            try writer.print(
                "\",\"trace\":\"{s}\",\"span\":\"{s}\",\"ts\":{},\"tid\":{}",
                .{ trace_ctx.trace_id_hex, trace_ctx.span_id_hex, std.time.milliTimestamp(), std.Thread.getCurrentId() },
            );
        }

        fn writeLogFields(
            self: *const Self,
            writer: anytype,
            fields: []const field.Field,
        ) !void {
            assert(fields.len <= max_fields);

            for (fields) |field_item| {
                try writer.writeAll(",\"");
                try escape.write(cfg, writer, field_item.key);
                try writer.writeAll("\":");

                // Check if field should be redacted
                if (self.shouldRedact(field_item.key)) {
                    const redacted_value = field.Field.Value{
                        .redacted = .{
                            .value_type = switch (field_item.value) {
                                .string => .string,
                                .int => .int,
                                .uint => .uint,
                                .float => .float,
                                .boolean => .any,
                                .null => .any,
                                .redacted => |r| r.value_type,
                            },
                            .hint = null,
                        },
                    };
                    try self.formatEventFieldValue(writer, redacted_value);
                } else {
                    try self.formatEventFieldValue(writer, field_item.value);
                }
            }
        }

        fn writeLogFooter(
            self: *const Self,
            writer: anytype,
        ) !void {
            _ = self;
            try writer.writeAll("}\n");
        }

        fn formatEventFieldValue(
            self: *const Self,
            writer: anytype,
            value: field.Field.Value,
        ) !void {
            _ = self;
            assert(@TypeOf(writer) != void);

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
                .redacted => |r| {
                    if (r.hint) |hint| {
                        try writer.print("\"[REDACTED:{s}:{s}]\"", .{ @tagName(r.value_type), hint });
                    } else {
                        try writer.print("\"[REDACTED:{s}]\"", .{@tagName(r.value_type)});
                    }
                },
            }
        }
    };
}

fn AsyncLogger(comptime cfg: config.Config) type {
    return struct {
        const Self = @This();
        const max_fields = cfg.max_fields;
        const BUFFER_SIZE = 2048;
        const MAX_BATCH_SIZE = 64;
        const FLUSH_INTERVAL_MS = 100;

        // Backpressure strategies
        const BackpressureStrategy = enum {
            drop, // Drop logs when buffer full (default)
            block, // Block until space available
            sample, // Intelligent sampling under load
        };

        const LogEntry = struct {
            data: [BUFFER_SIZE]u8,
            len: u32,
            timestamp_ns: u64,
            level: config.Level,
        };

        // Event-driven queue using libxev
        const AsyncQueue = struct {
            entries: std.ArrayList(LogEntry),
            mutex: std.Thread.Mutex,
            condition: std.Thread.Condition,
            max_size: u32,
            backpressure: BackpressureStrategy,

            fn init(allocator: std.mem.Allocator, max_size: u32, backpressure: BackpressureStrategy) AsyncQueue {
                return AsyncQueue{
                    .entries = std.ArrayList(LogEntry).init(allocator),
                    .mutex = .{},
                    .condition = .{},
                    .max_size = max_size,
                    .backpressure = backpressure,
                };
            }

            fn deinit(self: *AsyncQueue) void {
                self.entries.deinit();
            }

            fn push(self: *AsyncQueue, entry: LogEntry) !void {
                self.mutex.lock();
                defer self.mutex.unlock();

                // Handle backpressure
                switch (self.backpressure) {
                    .drop => {
                        if (self.entries.items.len >= self.max_size) {
                            return; // Silent drop
                        }
                    },
                    .block => {
                        while (self.entries.items.len >= self.max_size) {
                            self.condition.wait(&self.mutex);
                        }
                    },
                    .sample => {
                        if (self.entries.items.len >= self.max_size) {
                            // Intelligent sampling: keep only ERROR/FATAL logs
                            if (@intFromEnum(entry.level) < @intFromEnum(config.Level.err)) {
                                return;
                            }
                            // Remove oldest non-critical log
                            for (self.entries.items, 0..) |existing, i| {
                                if (@intFromEnum(existing.level) < @intFromEnum(config.Level.err)) {
                                    _ = self.entries.orderedRemove(i);
                                    break;
                                }
                            }
                        }
                    },
                }

                try self.entries.append(entry);
                self.condition.signal();
            }

            fn popBatch(self: *AsyncQueue, batch: []LogEntry) u32 {
                self.mutex.lock();
                defer self.mutex.unlock();

                const count = @min(self.entries.items.len, batch.len);
                if (count == 0) return 0;

                const count_u32: u32 = @intCast(count);
                @memcpy(batch[0..count], self.entries.items[0..count]);
                self.entries.replaceRange(0, count, &.{}) catch unreachable;

                self.condition.signal(); // Signal waiting producers
                return count_u32;
            }

            fn isEmpty(self: *AsyncQueue) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.entries.items.len == 0;
            }
        };

        // libxev integration
        queue: AsyncQueue,
        writer: std.io.AnyWriter,
        allocator: std.mem.Allocator,
        event_loop: *xev.Loop,

        // Event-driven components
        timer: xev.Timer,
        write_completion: xev.Completion,
        should_stop: std.atomic.Value(bool),

        // Batching state
        batch_buffer: [MAX_BATCH_SIZE]LogEntry,
        write_buffer: std.ArrayList(u8),

        // Performance metrics
        logs_written: std.atomic.Value(u64),
        logs_dropped: std.atomic.Value(u64),
        flush_count: std.atomic.Value(u64),

        pub fn init(
            allocator: std.mem.Allocator,
            output_writer: std.io.AnyWriter,
            event_loop: *xev.Loop,
            queue_size: u32,
            batch_size: u32,
        ) !Self {
            _ = batch_size;
            assert(@TypeOf(allocator) == std.mem.Allocator);
            assert(@TypeOf(output_writer) == std.io.AnyWriter);
            assert(@TypeOf(event_loop.*) == xev.Loop);
            assert(queue_size > 0);
            assert(queue_size <= 65536);

            var self = Self{
                .queue = AsyncQueue.init(allocator, queue_size, .sample),
                .writer = output_writer,
                .allocator = allocator,
                .event_loop = event_loop,
                .timer = undefined,
                .write_completion = undefined,
                .should_stop = std.atomic.Value(bool).init(false),
                .batch_buffer = undefined,
                .write_buffer = std.ArrayList(u8).init(allocator),
                .logs_written = std.atomic.Value(u64).init(0),
                .logs_dropped = std.atomic.Value(u64).init(0),
                .flush_count = std.atomic.Value(u64).init(0),
            };

            self.timer = try xev.Timer.init();
            assert(@TypeOf(self.timer) == xev.Timer);

            assert(self.logs_written.load(.monotonic) == 0);
            assert(self.logs_dropped.load(.monotonic) == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.should_stop.store(true, .release);

            // Final flush
            self.flushPending();

            // Cleanup
            self.queue.deinit();
            self.write_buffer.deinit();
            self.timer.deinit();
        }

        pub fn log(self: *Self, level: config.Level, message: []const u8, fields: []const field.Field) !void {
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(message.len > 0);
            assert(message.len < BUFFER_SIZE);
            assert(fields.len <= max_fields);

            if (self.should_stop.load(.acquire)) {
                return;
            }

            const formatted_entry = try self.formatLogEntry(level, message, fields);
            assert(formatted_entry.len > 0);
            assert(formatted_entry.len <= BUFFER_SIZE);

            self.queueLogEntry(formatted_entry, level);
        }

        fn formatLogEntry(self: *Self, level: config.Level, message: []const u8, fields: []const field.Field) !LogEntry {
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(message.len > 0);
            assert(fields.len <= max_fields);

            var buffer: [BUFFER_SIZE]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buffer);
            const writer = stream.writer();

            try self.writeJsonHeader(writer, level, message);
            try self.writeJsonFields(writer, fields);
            try writer.writeAll("}\n");

            const entry = LogEntry{
                .data = buffer,
                .len = @intCast(stream.pos),
                .timestamp_ns = @intCast(std.time.nanoTimestamp()),
                .level = level,
            };

            assert(entry.len > 0);
            assert(entry.len <= BUFFER_SIZE);
            return entry;
        }

        fn writeJsonHeader(self: *const Self, writer: anytype, level: config.Level, message: []const u8) !void {
            _ = self;
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(message.len > 0);

            try writer.writeAll("{\"level\":\"");
            try writer.writeAll(level.string());
            try writer.writeAll("\",\"msg\":\"");
            try escape.write(cfg, writer, message);
            try writer.writeAll("\",\"ts\":");
            try writer.print("{}", .{std.time.nanoTimestamp()});
            try writer.writeAll(",\"tid\":");
            try writer.print("{}", .{std.Thread.getCurrentId()});
        }

        fn writeJsonFields(self: *Self, writer: anytype, fields: []const field.Field) !void {
            assert(fields.len <= max_fields);

            for (fields) |field_item| {
                try writer.writeAll(",\"");
                try escape.write(cfg, writer, field_item.key);
                try writer.writeAll("\":");
                try self.formatFieldValue(writer, field_item.value);
            }
        }

        fn queueLogEntry(self: *Self, entry: LogEntry, level: config.Level) void {
            assert(entry.len > 0);
            assert(entry.len <= BUFFER_SIZE);
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));

            self.queue.push(entry) catch {
                _ = self.logs_dropped.fetchAdd(1, .monotonic);
                return;
            };
        }

        pub fn flushPending(self: *Self) void {
            while (!self.queue.isEmpty()) {
                const count = self.queue.popBatch(&self.batch_buffer);
                if (count == 0) break;

                self.writeBatch(self.batch_buffer[0..count]);
            }
        }

        // libxev timer callback for periodic flushing
        fn timerCallback(
            userdata: ?*Self,
            loop: *xev.Loop,
            completion: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;

            const self = userdata.?;
            if (self.should_stop.load(.acquire)) {
                return .disarm;
            }

            // Batch flush logs
            const count = self.queue.popBatch(&self.batch_buffer);
            if (count > 0) {
                self.writeBatch(self.batch_buffer[0..count]);
                _ = self.flush_count.fetchAdd(1, .monotonic);
            }

            // Reschedule timer
            self.timer.run(
                loop,
                completion,
                FLUSH_INTERVAL_MS,
                Self,
                self,
                timerCallback,
            );

            return .rearm;
        }

        fn writeBatch(self: *Self, entries: []const LogEntry) void {
            // Clear write buffer
            self.write_buffer.clearRetainingCapacity();

            // Batch multiple log entries into single write
            for (entries) |entry| {
                self.write_buffer.appendSlice(entry.data[0..entry.len]) catch {
                    // If we can't buffer, write immediately
                    self.writer.writeAll(entry.data[0..entry.len]) catch {};
                    continue;
                };
            }

            // Single batched write for better I/O performance
            if (self.write_buffer.items.len > 0) {
                self.writer.writeAll(self.write_buffer.items) catch {};
                _ = self.logs_written.fetchAdd(entries.len, .monotonic);
            }
        }

        fn formatFieldValue(self: *const Self, writer: anytype, value: field.Field.Value) !void {
            _ = self;
            switch (value) {
                .string => |s| {
                    try writer.writeAll("\"");
                    try escape.write(cfg, writer, s);
                    try writer.writeAll("\"");
                },
                .int => |i| try writer.print("{}", .{i}),
                .uint => |u| try writer.print("{}", .{u}),
                .float => |f| try writer.print("{d:.5}", .{f}),
                .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
                .null => try writer.writeAll("null"),
                .redacted => try writer.writeAll("\"[REDACTED]\""),
            }
        }

        // Performance monitoring
        pub fn getMetrics(self: *const Self) struct {
            logs_written: u64,
            logs_dropped: u64,
            flush_count: u64,
            queue_size: u32,
        } {
            return .{
                .logs_written = self.logs_written.load(.monotonic),
                .logs_dropped = self.logs_dropped.load(.monotonic),
                .flush_count = self.flush_count.load(.monotonic),
                .queue_size = @intCast(self.queue.entries.items.len),
            };
        }
    };
}

// Test the ergonomic API
test "Ergonomic API with anonymous struct fields" {
    const testing = std.testing;

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var logger = Logger(.{ .max_fields = 8 }).init(buffer.writer().any());

    // Test the new ergonomic API
    logger.info("User login successful", .{
        .user_id = "12345",
        .username = "john_doe",
        .attempt = 1,
        .success = true,
        .ip_address = "192.168.1.100",
        .session_duration = 3.14,
    });

    const output = buffer.items;

    // Verify all fields are present
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"user_id\":\"12345\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"username\":\"john_doe\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"attempt\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"success\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"ip_address\":\"192.168.1.100\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"session_duration\":3.14"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"level\":\"INFO\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"msg\":\"User login successful\""));
}
