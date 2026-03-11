const std = @import("std");
const assert = std.debug.assert;

const config = @import("config.zig");
const field = @import("field.zig");
const field_input = @import("field_input.zig");
const trace_mod = @import("trace.zig");
const correlation = @import("correlation.zig");
const otel = @import("otel.zig");
const escape = @import("string_escape.zig");
const async_batcher = @import("async_batcher.zig");
const redaction = @import("redaction.zig");
const writer_handle = @import("writer_handle.zig");

/// OpenTelemetry-compliant logger that outputs logs according to OTel log data model
pub fn OTelLogger(comptime otel_config: otel.OTelConfig) type {
    return OTelLoggerWithRedaction(otel_config, .{});
}

pub fn OTelLoggerWithRedaction(
    comptime otel_config: otel.OTelConfig,
    comptime redaction_options: redaction.RedactionOptions,
) type {
    const cfg = otel_config.base_config;

    comptime {
        assert(cfg.max_fields > 0);
        assert(cfg.buffer_size >= 256);
        assert(cfg.buffer_size <= 65536);
        if (cfg.async_mode) {
            assert(cfg.async_queue_size > 0);
            assert(cfg.batch_size > 0);
        }
    }

    return struct {
        const Self = @This();
        const max_fields = cfg.max_fields;
        const buffer_size = cfg.buffer_size;
        const async_mode = cfg.async_mode;
        const compile_time_redacted_fields = redaction_options.redacted_fields;
        const AsyncSink = if (async_mode)
            async_batcher.Batcher(buffer_size, cfg.async_queue_size, cfg.batch_size)
        else
            void;

        pub const AsyncState = if (async_mode) AsyncSink.State else void;

        writer: writer_handle.Handle,
        mutex: std.Thread.Mutex = std.Thread.Mutex{},
        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,
        resource: otel.Resource,
        instrumentation_scope: otel.InstrumentationScope,
        async_logger: if (async_mode) OTelAsyncLogger(otel_config) else void,
        logs_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        logs_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        write_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        const key_bytes_max = 255;
        const group_depth_max = 8;

        const FieldBuffer = struct {
            data: [max_fields]field.Field = undefined,
            key_storage: [max_fields][key_bytes_max]u8 = undefined,
            len: u16 = 0,

            fn append(self: *FieldBuffer, field_item: field.Field) void {
                assert(self.len <= max_fields);

                if (self.find(field_item.key)) |field_index| {
                    self.storeField(field_index, field_item);
                    return;
                }

                if (self.len == max_fields) {
                    return;
                }

                const write_index: usize = @intCast(self.len);
                self.storeField(write_index, field_item);
                self.len += 1;
            }

            fn appendSlice(self: *FieldBuffer, fields: []const field.Field) void {
                assert(fields.len <= max_fields);

                for (fields) |field_item| {
                    self.append(field_item);
                }
            }

            fn constSlice(self: *const FieldBuffer) []const field.Field {
                const fields_len: usize = @intCast(self.len);
                assert(fields_len <= max_fields);
                return self.data[0..fields_len];
            }

            fn find(self: *const FieldBuffer, key: []const u8) ?usize {
                assert(key.len > 0);

                for (self.constSlice(), 0..) |field_item, field_index| {
                    if (std.mem.eql(u8, field_item.key, key)) {
                        return field_index;
                    }
                }

                return null;
            }

            fn storeField(self: *FieldBuffer, field_index: usize, field_item: field.Field) void {
                assert(field_index < max_fields);
                assert(field_item.key.len > 0);
                assert(field_item.key.len <= key_bytes_max);

                std.mem.copyForwards(
                    u8,
                    self.key_storage[field_index][0..field_item.key.len],
                    field_item.key,
                );
                self.data[field_index] = field_item;
                self.data[field_index].key = self.key_storage[field_index][0..field_item.key.len];
            }
        };

        const PrefixedFieldBuffer = struct {
            data: [max_fields]field.Field = undefined,
            key_storage: [max_fields][key_bytes_max]u8 = undefined,
            len: u16 = 0,

            fn append(self: *PrefixedFieldBuffer, group_names: []const []const u8, source_field: field.Field) void {
                assert(self.len <= max_fields);

                if (self.len == max_fields) {
                    return;
                }

                const write_index: usize = @intCast(self.len);
                self.data[write_index] = source_field;
                self.data[write_index].key = copyGroupedKey(
                    self.key_storage[write_index][0..],
                    group_names,
                    source_field.key,
                );
                self.len += 1;
            }

            fn appendSlice(
                self: *PrefixedFieldBuffer,
                group_names: []const []const u8,
                source_fields: []const field.Field,
            ) void {
                assert(source_fields.len <= max_fields);

                for (source_fields) |source_field| {
                    self.append(group_names, source_field);
                }
            }

            fn constSlice(self: *const PrefixedFieldBuffer) []const field.Field {
                const fields_len: usize = @intCast(self.len);
                assert(fields_len <= max_fields);
                return self.data[0..fields_len];
            }
        };

        pub const ContextLogger = struct {
            parent: *Self,
            context_fields: [max_fields]field.Field = undefined,
            context_key_storage: [max_fields][key_bytes_max]u8 = undefined,
            context_fields_len: u16 = 0,
            group_names: [group_depth_max][]const u8 = undefined,
            group_name_storage: [group_depth_max][key_bytes_max]u8 = undefined,
            group_names_len: u8 = 0,

            fn init(parent: *Self) ContextLogger {
                assert(@TypeOf(parent.*) == Self);

                return ContextLogger{
                    .parent = parent,
                };
            }

            pub fn with(self: *const ContextLogger, fields_input: anytype) ContextLogger {
                var rebound = self.*;
                rebound.rebindStorage();

                var context_logger = ContextLogger.init(self.parent);
                context_logger.storeGroups(rebound.groupNames());
                context_logger.storeContextFields(rebound.contextFields());
                context_logger.appendContextFields(fields_input);
                return context_logger;
            }

            pub fn with_group(self: *const ContextLogger, group_name: []const u8) ContextLogger {
                var rebound = self.*;
                rebound.rebindStorage();

                var context_logger = ContextLogger.init(self.parent);
                context_logger.storeGroups(rebound.groupNames());
                context_logger.storeContextFields(rebound.contextFields());
                context_logger.appendGroup(group_name);
                return context_logger;
            }

            pub fn trace(self: *const ContextLogger, message: []const u8, fields_input: anytype) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(.trace, message, self.parent.traceContextForLog(), fields_input);
            }

            pub fn debug(self: *const ContextLogger, message: []const u8, fields_input: anytype) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(.debug, message, self.parent.traceContextForLog(), fields_input);
            }

            pub fn info(self: *const ContextLogger, message: []const u8, fields_input: anytype) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(.info, message, self.parent.traceContextForLog(), fields_input);
            }

            pub fn infoWithTrace(
                self: *const ContextLogger,
                message: []const u8,
                trace_ctx: trace_mod.TraceContext,
                fields_input: anytype,
            ) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(.info, message, trace_ctx, fields_input);
            }

            pub fn warn(self: *const ContextLogger, message: []const u8, fields_input: anytype) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(.warn, message, self.parent.traceContextForLog(), fields_input);
            }

            pub fn err(self: *const ContextLogger, message: []const u8, fields_input: anytype) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(.err, message, self.parent.traceContextForLog(), fields_input);
            }

            pub fn fatal(self: *const ContextLogger, message: []const u8, fields_input: anytype) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(.fatal, message, self.parent.traceContextForLog(), fields_input);
            }

            pub fn logDynamic(
                self: *const ContextLogger,
                level: config.Level,
                message: []const u8,
                dynamic_fields: []const field.Field,
            ) void {
                var rebound = self.*;
                rebound.rebindStorage();
                rebound.logInternal(level, message, self.parent.traceContextForLog(), dynamic_fields);
            }

            fn appendContextFields(self: *ContextLogger, fields_input: anytype) void {
                var merged_fields: FieldBuffer = .{};
                merged_fields.appendSlice(self.contextFields());
                self.parent.appendGroupedInputFields(&merged_fields, self.groupNames(), fields_input);
                self.storeContextFields(merged_fields.constSlice());
            }

            fn appendGroup(self: *ContextLogger, group_name: []const u8) void {
                assert(group_name.len > 0);
                assert(group_name.len <= key_bytes_max);
                assert(self.group_names_len < group_depth_max);

                const write_index: usize = @intCast(self.group_names_len);
                std.mem.copyForwards(
                    u8,
                    self.group_name_storage[write_index][0..group_name.len],
                    group_name,
                );
                self.group_names[write_index] = self.group_name_storage[write_index][0..group_name.len];
                self.group_names_len += 1;
            }

            fn groupNames(self: *const ContextLogger) []const []const u8 {
                const group_names_len: usize = @intCast(self.group_names_len);
                assert(group_names_len <= group_depth_max);
                return self.group_names[0..group_names_len];
            }

            fn contextFields(self: *const ContextLogger) []const field.Field {
                const context_fields_len: usize = @intCast(self.context_fields_len);
                assert(context_fields_len <= max_fields);
                return self.context_fields[0..context_fields_len];
            }

            fn logInternal(
                self: *const ContextLogger,
                level: config.Level,
                message: []const u8,
                trace_ctx: ?trace_mod.TraceContext,
                fields_input: anytype,
            ) void {
                comptime {
                    if (!cfg.enable_logging) return;
                }

                assert(message.len > 0);
                assert(message.len < buffer_size);

                var merged_fields: FieldBuffer = .{};
                merged_fields.appendSlice(self.contextFields());
                self.parent.appendGroupedInputFields(&merged_fields, self.groupNames(), fields_input);
                self.parent.logWithTrace(level, message, trace_ctx, merged_fields.constSlice());
            }

            fn storeGroups(self: *ContextLogger, group_names: []const []const u8) void {
                for (group_names) |group_name| {
                    self.appendGroup(group_name);
                }
            }

            fn storeContextFields(self: *ContextLogger, fields: []const field.Field) void {
                assert(fields.len <= max_fields);

                self.context_fields_len = @intCast(fields.len);
                for (fields, 0..) |field_item, field_index| {
                    assert(field_item.key.len > 0);
                    assert(field_item.key.len <= key_bytes_max);

                    std.mem.copyForwards(
                        u8,
                        self.context_key_storage[field_index][0..field_item.key.len],
                        field_item.key,
                    );
                    self.context_fields[field_index] = field_item;
                    self.context_fields[field_index].key =
                        self.context_key_storage[field_index][0..field_item.key.len];
                }
            }

            fn rebindStorage(self: *ContextLogger) void {
                const group_names_len: usize = @intCast(self.group_names_len);
                assert(group_names_len <= group_depth_max);
                for (0..group_names_len) |group_index| {
                    const group_name_len = self.group_names[group_index].len;
                    assert(group_name_len > 0);
                    assert(group_name_len <= key_bytes_max);
                    self.group_names[group_index] =
                        self.group_name_storage[group_index][0..group_name_len];
                }

                const context_fields_len: usize = @intCast(self.context_fields_len);
                assert(context_fields_len <= max_fields);
                for (0..context_fields_len) |field_index| {
                    const field_key_len = self.context_fields[field_index].key.len;
                    assert(field_key_len > 0);
                    assert(field_key_len <= key_bytes_max);
                    self.context_fields[field_index].key =
                        self.context_key_storage[field_index][0..field_key_len];
                }
            }
        };

        pub fn init(output_writer: anytype) Self {
            comptime {
                if (async_mode) {
                    @compileError("init() requires async_mode = false in config");
                }
            }
            return initWithRedaction(output_writer, null);
        }

        pub fn initWithRedaction(
            output_writer: anytype,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) Self {
            comptime {
                if (async_mode) {
                    @compileError("initWithRedaction() requires async_mode = false in config");
                }
            }

            assert(@intFromEnum(cfg.level) <= @intFromEnum(config.Level.fatal));

            return Self{
                .writer = writer_handle.Handle.init(output_writer),
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
                .async_logger = {},
            };
        }

        pub fn initAsync(
            output_writer: anytype,
            async_state: *AsyncState,
        ) Self {
            return initAsyncWithRedactionImpl(output_writer, async_state, null);
        }

        fn initAsyncWithRedactionImpl(
            output_writer: anytype,
            async_state: *AsyncState,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) Self {
            comptime {
                if (!async_mode) {
                    @compileError("initAsyncWithRedaction() requires async_mode = true in config");
                }
            }

            assert(@TypeOf(async_state.*) == AsyncState);

            const async_logger_instance = OTelAsyncLogger(otel_config).init(
                output_writer,
                async_state,
            );

            return Self{
                .writer = writer_handle.Handle.init(output_writer),
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
                .async_logger = async_logger_instance,
            };
        }

        pub fn initAsyncWithRedaction(
            output_writer: anytype,
            async_state: *AsyncState,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) Self {
            return initAsyncWithRedactionImpl(output_writer, async_state, redaction_cfg);
        }

        pub fn deinit(self: *Self) void {
            self.flush() catch {
                _ = self.write_failures.fetchAdd(1, .monotonic);
            };

            if (async_mode) {
                self.async_logger.deinit();
            }

            self.writer.deinit();
        }

        pub fn drain(self: *Self) void {
            if (!async_mode) {
                return;
            }

            self.async_logger.drain();
        }

        pub fn flush(self: *Self) std.Io.Writer.Error!void {
            if (async_mode) {
                try self.async_logger.flush();
                return;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.writer.flush();
        }

        pub fn with(self: *Self, fields_input: anytype) ContextLogger {
            var context_logger = ContextLogger.init(self);
            context_logger.appendContextFields(fields_input);
            return context_logger;
        }

        pub fn with_group(self: *Self, group_name: []const u8) ContextLogger {
            var context_logger = ContextLogger.init(self);
            context_logger.appendGroup(group_name);
            return context_logger;
        }

        fn shouldRedact(self: *const Self, key: []const u8) bool {
            inline for (compile_time_redacted_fields) |redacted_field| {
                if (std.mem.eql(u8, redacted_field, key)) return true;
            }
            return if (self.redaction_config) |rc| rc.shouldRedact(key) else false;
        }

        fn traceContextForLog(self: *const Self) ?trace_mod.TraceContext {
            _ = self;

            if (correlation.getCurrentTaskContextIfSet()) |current_context| {
                return current_context.trace_context;
            }

            return null;
        }

        pub fn trace(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.trace, message, self.traceContextForLog(), fields_struct);
        }

        pub fn debug(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.debug, message, self.traceContextForLog(), fields_struct);
        }

        pub fn info(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.info, message, self.traceContextForLog(), fields_struct);
        }

        pub fn infoWithTrace(
            self: *Self,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields_struct: anytype,
        ) void {
            assert(message.len > 0);
            self.logInternal(.info, message, trace_ctx, fields_struct);
        }

        pub fn warn(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.warn, message, self.traceContextForLog(), fields_struct);
        }

        pub fn err(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.err, message, self.traceContextForLog(), fields_struct);
        }

        pub fn fatal(self: *Self, message: []const u8, fields_struct: anytype) void {
            assert(message.len > 0);
            self.logInternal(.fatal, message, self.traceContextForLog(), fields_struct);
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
            return field_input.isFieldArray(T);
        }

        fn noteDropped(self: *Self) void {
            _ = self.logs_dropped.fetchAdd(1, .monotonic);
        }

        fn noteWritten(self: *Self) void {
            _ = self.logs_written.fetchAdd(1, .monotonic);
        }

        fn noteWriteFailure(self: *Self) void {
            _ = self.write_failures.fetchAdd(1, .monotonic);
        }

        fn appendGroupedInputFields(
            self: *const Self,
            target: *FieldBuffer,
            group_names: []const []const u8,
            fields_input: anytype,
        ) void {
            const InputType = @TypeOf(fields_input);
            const input_info = @typeInfo(InputType);

            var prefixed_fields: PrefixedFieldBuffer = .{};

            if (comptime isFieldArray(InputType)) {
                prefixed_fields.appendSlice(group_names, fieldSliceFromInput(fields_input));
                target.appendSlice(prefixed_fields.constSlice());
                return;
            }

            if (input_info == .@"struct") {
                const fields_array = self.structToFields(fields_input);
                prefixed_fields.appendSlice(group_names, &fields_array);
                target.appendSlice(prefixed_fields.constSlice());
                return;
            }

            if (input_info == .pointer and input_info.pointer.size == .one) {
                const pointed_type = input_info.pointer.child;
                const pointed_info = @typeInfo(pointed_type);

                if (pointed_info == .@"struct") {
                    const fields_array = self.structToFields(fields_input.*);
                    prefixed_fields.appendSlice(group_names, &fields_array);
                    target.appendSlice(prefixed_fields.constSlice());
                    return;
                }

                if (pointed_info == .array and pointed_info.array.child == field.Field) {
                    prefixed_fields.appendSlice(group_names, fieldSliceFromInput(fields_input));
                    target.appendSlice(prefixed_fields.constSlice());
                    return;
                }
            }

            @compileError("Expected struct or field array, got " ++ @typeName(InputType));
        }

        fn fieldSliceFromInput(fields_input: anytype) []const field.Field {
            return field_input.fieldSliceFromInput(fields_input);
        }

        fn copyGroupedKey(
            key_buffer: []u8,
            group_names: []const []const u8,
            field_key: []const u8,
        ) []const u8 {
            assert(field_key.len > 0);
            assert(field_key.len <= key_bytes_max);

            const key_bytes = groupedKeyBytes(group_names, field_key);
            assert(key_bytes > 0);
            assert(key_bytes <= key_bytes_max);
            assert(key_buffer.len >= key_bytes);

            var write_index: usize = 0;
            for (group_names) |group_name| {
                assert(group_name.len > 0);
                assert(group_name.len <= key_bytes_max);

                std.mem.copyForwards(
                    u8,
                    key_buffer[write_index .. write_index + group_name.len],
                    group_name,
                );
                write_index += group_name.len;
                key_buffer[write_index] = '.';
                write_index += 1;
            }

            std.mem.copyForwards(
                u8,
                key_buffer[write_index .. write_index + field_key.len],
                field_key,
            );
            write_index += field_key.len;

            assert(write_index == key_bytes);
            return key_buffer[0..write_index];
        }

        fn groupedKeyBytes(group_names: []const []const u8, field_key: []const u8) usize {
            assert(field_key.len > 0);
            assert(field_key.len <= key_bytes_max);

            var key_bytes = field_key.len;
            for (group_names) |group_name| {
                assert(group_name.len > 0);
                assert(group_name.len <= key_bytes_max);
                key_bytes += group_name.len + 1;
            }

            assert(key_bytes > 0);
            assert(key_bytes <= key_bytes_max);
            return key_bytes;
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
                var buffer: [buffer_size]u8 = undefined;
                const formatted_len = self.formatLogRecord(&buffer, log_record) catch {
                    self.noteDropped();
                    return;
                };
                self.async_logger.logAsync(buffer[0..formatted_len]);
                return;
            }

            self.formatAndWrite(log_record);
        }

        // ========================================
        // ERGONOMIC API - Anonymous Struct Fields
        // ========================================

        /// Convert anonymous struct to field array at compile time.
        /// This enables ergonomic logging syntax like:
        /// logger.info("message", .{ .user_id = "123", .success = true });
        fn structToFields(
            self: *const Self,
            fields_struct: anytype,
        ) [getFieldCount(@TypeOf(fields_struct))]field.Field {
            _ = self;
            return field_input.structToFields(max_fields, fields_struct);
        }

        /// Get field count for compile-time array sizing
        fn getFieldCount(comptime T: type) comptime_int {
            return field_input.fieldCount(T);
        }

        fn formatAndWrite(self: *Self, log_record: otel.LogRecord) void {
            var buffer: [buffer_size]u8 = undefined;
            const formatted_len = self.formatLogRecord(&buffer, log_record) catch {
                self.noteDropped();
                return;
            };

            self.mutex.lock();
            defer self.mutex.unlock();
            self.writer.ioWriter().writeAll(buffer[0..formatted_len]) catch {
                self.noteDropped();
                self.noteWriteFailure();
                return;
            };
            self.noteWritten();
        }

        fn formatLogRecord(self: *Self, buffer: []u8, log_record: otel.LogRecord) !usize {
            assert(buffer.len == buffer_size);

            var writer: std.Io.Writer = .fixed(buffer);

            if (otel_config.enable_otel_format) {
                try self.formatOTelJson(&writer, log_record);
            } else {
                try self.formatCompatibleJson(&writer, log_record);
            }

            const formatted_len = writer.buffered().len;
            assert(formatted_len > 0);
            assert(formatted_len <= buffer_size);
            return formatted_len;
        }

        fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
            try writer.writeByte('"');
            try escape.write(cfg, writer, value);
            try writer.writeByte('"');
        }

        fn writeJsonFloat(writer: *std.Io.Writer, value: f64) !void {
            assert(!std.math.isNan(value));
            assert(!std.math.isInf(value));
            try writer.print("{}", .{value});
        }

        fn formatOTelJson(self: *Self, writer: *std.Io.Writer, log_record: otel.LogRecord) !void {
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

        fn writeOTelTimestamps(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            _ = self;
            assert(log_record.timestamp > 0);
            assert(log_record.observed_timestamp > 0);

            try writer.print("\"timeUnixNano\":\"{}\",", .{log_record.timestamp});
            try writer.print("\"observedTimeUnixNano\":\"{}\",", .{log_record.observed_timestamp});
        }

        fn writeOTelSeverity(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            _ = self;
            assert(@intFromEnum(log_record.severity_number) <= 24);

            try writer.print(
                "\"severityNumber\":{},",
                .{@intFromEnum(log_record.severity_number)},
            );
            if (log_record.severity_text) |severity_text| {
                try writer.writeAll("\"severityText\":");
                try writeJsonString(writer, severity_text);
                try writer.writeAll(",");
            }
        }

        fn writeOTelBody(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            _ = self;

            try writer.writeAll("\"body\":{\"stringValue\":\"");
            if (log_record.body.asString()) |body_str| {
                try escape.write(cfg, writer, body_str);
            }
            try writer.writeAll("\"},");
        }

        fn writeOTelAttributes(
            self: *Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            assert(log_record.attributes.len <= max_fields);

            try writer.writeAll("\"attributes\":[");
            var first_attribute = true;
            for (log_record.attributes) |attr| {
                if (attr.value == .null) {
                    continue;
                }

                if (!first_attribute) {
                    try writer.writeAll(",");
                }
                first_attribute = false;
                try self.formatOTelAttribute(writer, attr);
            }
            try writer.writeAll("],");
        }

        fn writeOTelTraceContext(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
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

        fn writeOTelResource(
            self: *Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            assert(log_record.resource.service_name.len > 0);

            try writer.writeAll("\"resource\":{\"attributes\":[");
            try self.formatResourceAttributes(writer, log_record.resource);
            try writer.writeAll("]},");
        }

        fn writeOTelScope(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            _ = self;
            assert(log_record.instrumentation_scope.name.len > 0);

            try writer.writeAll("\"scope\":{\"name\":");
            try writeJsonString(writer, log_record.instrumentation_scope.name);
            if (log_record.instrumentation_scope.version) |version| {
                try writer.writeAll(",\"version\":");
                try writeJsonString(writer, version);
            }
            try writer.writeAll("}");
        }

        fn formatCompatibleJson(
            self: *Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            assert(@TypeOf(writer) != void);
            assert(log_record.attributes.len <= max_fields);

            try self.writeCompatibleHeader(writer, log_record);
            try self.writeCompatibleTraceContext(writer, log_record);
            try self.writeCompatibleResource(writer, log_record);
            try self.writeCompatibleAttributes(writer, log_record);
            try writer.writeAll("}\n");
        }

        fn writeCompatibleHeader(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            _ = self;
            assert(log_record.timestamp > 0);

            try writer.writeAll("{\"level\":");
            try writeJsonString(writer, log_record.severity_text orelse "UNKNOWN");
            try writer.writeAll(",\"msg\":\"");

            if (log_record.body.asString()) |body_str| {
                try escape.write(cfg, writer, body_str);
            }

            try writer.print(
                "\",\"ts\":{},\"tid\":{},\"severity_number\":{}",
                .{
                    log_record.timestamp / 1_000_000,
                    std.Thread.getCurrentId(),
                    @intFromEnum(log_record.severity_number),
                },
            );
        }

        fn writeCompatibleTraceContext(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
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

        fn writeCompatibleResource(
            self: *const Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
            _ = self;
            assert(log_record.resource.service_name.len > 0);

            try writer.writeAll(",\"service.name\":");
            try writeJsonString(writer, log_record.resource.service_name);
            if (log_record.resource.service_version) |version| {
                try writer.writeAll(",\"service.version\":");
                try writeJsonString(writer, version);
            }
        }

        fn writeCompatibleAttributes(
            self: *Self,
            writer: *std.Io.Writer,
            log_record: otel.LogRecord,
        ) !void {
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

        fn writeRedactedCompatibleValue(
            self: *const Self,
            writer: *std.Io.Writer,
            value: field.Field.Value,
        ) !void {
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

        fn formatOTelAttribute(self: *Self, writer: *std.Io.Writer, attr: field.Field) !void {
            assert(attr.value != .null);
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
                        try writeJsonFloat(writer, f);
                        try writer.writeAll("}");
                    },
                    .boolean => |b| {
                        try writer.writeAll("{\"boolValue\":");
                        try writer.print("{}", .{b});
                        try writer.writeAll("}");
                    },
                    .null => unreachable,
                    .redacted => try writer.writeAll("{\"stringValue\":\"[REDACTED]\"}"),
                }
            }
            try writer.writeAll("}");
        }

        fn formatFieldValue(self: *Self, writer: *std.Io.Writer, value: field.Field.Value) !void {
            _ = self;
            switch (value) {
                .string => |s| {
                    try writer.writeByte('"');
                    try escape.write(cfg, writer, s);
                    try writer.writeByte('"');
                },
                .int => |i| try writer.print("{}", .{i}),
                .uint => |u| try writer.print("{}", .{u}),
                .float => |f| try writeJsonFloat(writer, f),
                .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
                .null => try writer.writeAll("null"),
                .redacted => try writer.writeAll("\"[REDACTED]\""),
            }
        }

        fn formatResourceAttributes(
            self: *Self,
            writer: *std.Io.Writer,
            resource: otel.Resource,
        ) !void {
            _ = self;
            var first = true;

            // Service attributes
            if (!first) try writer.writeAll(",");
            try writer.writeAll("{\"key\":\"service.name\",\"value\":{\"stringValue\":");
            try writeJsonString(writer, resource.service_name);
            try writer.writeAll("}}");
            first = false;

            if (resource.service_version) |version| {
                try writer.writeAll(",");
                try writer.writeAll("{\"key\":\"service.version\",\"value\":{\"stringValue\":");
                try writeJsonString(writer, version);
                try writer.writeAll("}}");
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
                try writer.writeAll("{\"key\":\"host.arch\",\"value\":{\"stringValue\":");
                try writeJsonString(writer, arch);
                try writer.writeAll("}}");
            }

            // OS attributes
            if (resource.os_type) |os_type| {
                try writer.writeAll(",");
                try writer.writeAll("{\"key\":\"os.type\",\"value\":{\"stringValue\":");
                try writeJsonString(writer, os_type);
                try writer.writeAll("}}");
            }
        }

        pub fn getMetrics(self: *const Self) struct {
            logs_written: u64,
            logs_dropped: u64,
            flush_count: u64,
            queue_size: u32,
            write_failures: u64,
        } {
            if (async_mode) {
                const async_metrics = self.async_logger.getMetrics();
                return .{
                    .logs_written = async_metrics.logs_written,
                    .logs_dropped = async_metrics.logs_dropped +
                        self.logs_dropped.load(.monotonic),
                    .flush_count = async_metrics.flush_count,
                    .queue_size = async_metrics.queue_size,
                    .write_failures = async_metrics.write_failures +
                        self.write_failures.load(.monotonic),
                };
            }

            return .{
                .logs_written = self.logs_written.load(.monotonic),
                .logs_dropped = self.logs_dropped.load(.monotonic),
                .flush_count = 0,
                .queue_size = 0,
                .write_failures = self.write_failures.load(.monotonic),
            };
        }
    };
}

fn OTelAsyncLogger(comptime otel_config: otel.OTelConfig) type {
    return struct {
        const Self = @This();
        const cfg = otel_config.base_config;
        const Batcher = async_batcher.Batcher(
            cfg.buffer_size,
            cfg.async_queue_size,
            cfg.batch_size,
        );

        pub const State = Batcher.State;

        sink: Batcher,

        pub fn init(writer: anytype, state: *State) Self {
            return .{
                .sink = Batcher.init(writer, state),
            };
        }

        pub fn deinit(self: *Self) void {
            self.sink.deinit();
        }

        pub fn flush(self: *Self) std.Io.Writer.Error!void {
            try self.sink.flush();
        }

        pub fn drain(self: *Self) void {
            self.sink.drain();
        }

        pub fn flushPending(self: *Self) void {
            self.sink.flush_pending();
        }

        pub fn logAsync(self: *Self, formatted_log: []const u8) void {
            assert(formatted_log.len > 0);
            assert(formatted_log.len <= cfg.buffer_size);
            self.sink.enqueue(formatted_log);
        }

        pub fn getMetrics(self: *const Self) struct {
            logs_written: u64,
            logs_dropped: u64,
            flush_count: u64,
            queue_size: u32,
            write_failures: u64,
        } {
            const metrics = self.sink.metrics();
            return .{
                .logs_written = metrics.logs_written,
                .logs_dropped = metrics.logs_dropped,
                .flush_count = metrics.flush_count,
                .queue_size = metrics.queue_size,
                .write_failures = metrics.write_failures,
            };
        }
    };
}

const testing = std.testing;

test "OTelLogger creation and basic functionality" {
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-logger"),
    };

    var logger = OTelLogger(otel_config).init(&writer);

    logger.info("Test message", &.{
        field.Field.string("key", "value"),
        field.Field.int("count", 42),
    });

    const output = writer.buffered();
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "Test message"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "test-service"));
}

test "OTel format output" {
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    const otel_config = comptime otel.OTelConfig{
        .enable_otel_format = true,
        .resource = otel.Resource.init().withService("otel-test", "2.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("otel-logger"),
    };

    var logger = OTelLogger(otel_config).init(&writer);

    logger.info("OTel test message", &.{
        field.Field.string("environment", "test"),
    });

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "timeUnixNano"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "severityNumber"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "body"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "attributes"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "resource"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "scope"));
}

test "OTel unified API" {
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-logger"),
    };

    var logger = OTelLogger(otel_config).init(&writer);

    // Test unified API with various field types
    logger.info("User authentication", .{
        .user_id = "12345",
        .username = "alice",
        .attempt = @as(i64, 1),
        .success = true,
        .duration_ms = 45.7,
        .optional_field = @as(?[]const u8, null),
    });

    const output = writer.buffered();

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

test "OTel unified API preserves full unsigned integer range" {
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-logger"),
    };

    var logger = OTelLogger(otel_config).init(&writer);

    const counter_total: u64 = std.math.maxInt(u64);
    logger.info("Unsigned counter", .{
        .counter_total = counter_total,
    });

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "\"counter_total\":18446744073709551615",
    ));
}

test "OTel ContextLogger supports with and with_group" {
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-logger"),
    };

    var logger = OTelLogger(otel_config).init(&writer);

    var group_name = [_]u8{ 'd', 'b' };
    const db_logger = logger.with_group(group_name[0..]).with(.{
        .system = "postgres",
    });
    group_name[0] = 'x';

    const query_logger = db_logger.with_group("query");
    query_logger.info("Query executed", .{
        .rows = 1,
        .ratio = @as(f64, 1.0) / 3.0,
    });

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"db.system\":\"postgres\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"db.query.rows\":1"));
    try testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "\"db.query.ratio\":0.3333333333333333",
    ));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "\"xb.system\""));
}

test "OTel ergonomic API flattens nested anonymous structs" {
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-logger"),
    };

    var logger = OTelLogger(otel_config).init(&writer);
    logger.info("Request completed", .{
        .request = .{
            .method = "GET",
            .status_code = 200,
        },
        .cache = .{
            .hit = true,
        },
    });

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"request.method\":\"GET\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"request.status_code\":200"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"cache.hit\":true"));
}
