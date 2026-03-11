const std = @import("std");
const assert = std.debug.assert;

const config = @import("config.zig");
const field = @import("field.zig");
const field_input = @import("field_input.zig");
const trace_mod = @import("trace.zig");

const correlation = @import("correlation.zig");
const redaction = @import("redaction.zig");
const escape = @import("string_escape.zig");
const async_batcher = @import("async_batcher.zig");
const writer_handle = @import("writer_handle.zig");

pub fn Logger(comptime cfg: config.Config) type {
    return LoggerWithRedaction(cfg, .{});
}

pub fn LoggerWithRedaction(
    comptime cfg: config.Config,
    comptime redaction_options: redaction.RedactionOptions,
) type {
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
        const async_queue_size = cfg.async_queue_size;
        const compile_time_redacted_fields = redaction_options.redacted_fields;
        const AsyncSink = if (async_mode)
            async_batcher.Batcher(buffer_size, async_queue_size, cfg.batch_size)
        else
            void;

        pub const AsyncState = if (async_mode) AsyncSink.State else void;

        writer: writer_handle.Handle,
        mutex: std.Thread.Mutex = std.Thread.Mutex{},
        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,
        async_logger: if (async_mode) AsyncLogger(cfg) else void,
        logs_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        logs_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        write_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        const key_bytes_max = 255;
        const group_depth_max = 8;

        const FieldBuffer = struct {
            data: [max_fields]field.Field = undefined,
            key_storage: [max_fields][key_bytes_max]u8 = undefined,
            len: usize = 0,

            fn append(self: *FieldBuffer, field_item: field.Field) void {
                assert(self.len <= max_fields);

                if (self.find(field_item.key)) |field_index| {
                    self.storeField(field_index, field_item);
                    return;
                }

                if (self.len == max_fields) {
                    return;
                }

                self.storeField(self.len, field_item);
                self.len += 1;
            }

            fn appendSlice(self: *FieldBuffer, fields: []const field.Field) void {
                assert(fields.len <= 1024);

                for (fields) |field_item| {
                    self.append(field_item);
                }
            }

            fn constSlice(self: *const FieldBuffer) []const field.Field {
                assert(self.len <= max_fields);
                return self.data[0..self.len];
            }

            fn find(self: *const FieldBuffer, key: []const u8) ?usize {
                assert(key.len > 0);
                assert(self.len <= max_fields);

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
            len: usize = 0,

            fn append(
                self: *PrefixedFieldBuffer,
                group_names: []const []const u8,
                source_field: field.Field,
            ) void {
                assert(self.len <= max_fields);

                if (self.len == max_fields) {
                    return;
                }

                self.data[self.len] = source_field;
                self.data[self.len].key = copyGroupedKey(
                    self.key_storage[self.len][0..],
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
                assert(self.len <= max_fields);
                return self.data[0..self.len];
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

            pub fn init(parent: *Self, fields_input: anytype) ContextLogger {
                var context_logger = initEmpty(parent);
                context_logger.appendContextFields(fields_input);
                return context_logger;
            }

            pub fn with(self: *const ContextLogger, fields_input: anytype) ContextLogger {
                var rebound = self.*;
                rebound.rebindStorage();

                var context_logger = initEmpty(self.parent);
                context_logger.storeGroups(rebound.groupNames());
                context_logger.storeContextFields(rebound.contextFields());
                context_logger.appendContextFields(fields_input);
                return context_logger;
            }

            pub fn with_group(self: *const ContextLogger, group_name: []const u8) ContextLogger {
                var rebound = self.*;
                rebound.rebindStorage();

                var context_logger = initEmpty(self.parent);
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

            fn initEmpty(parent: *Self) ContextLogger {
                assert(@TypeOf(parent.*) == Self);

                return ContextLogger{
                    .parent = parent,
                };
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
                self.group_names[write_index] =
                    self.group_name_storage[write_index][0..group_name.len];
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
                trace_ctx: trace_mod.TraceContext,
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

            const logger_result = Self{
                .writer = writer_handle.Handle.init(output_writer),
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .async_logger = {},
            };

            assert(@intFromEnum(logger_result.level) <= @intFromEnum(config.Level.fatal));
            return logger_result;
        }

        pub fn initAsync(
            output_writer: anytype,
            async_state: *AsyncState,
        ) Self {
            return initAsyncWithRedaction(output_writer, async_state, null);
        }

        fn initAsyncWithRedaction(
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
            assert(@intFromEnum(cfg.level) <= @intFromEnum(config.Level.fatal));
            assert(buffer_size >= 256);
            assert(buffer_size <= 65536);

            const async_logger_instance = AsyncLogger(cfg).init(output_writer, async_state);

            const logger_result = Self{
                .writer = writer_handle.Handle.init(output_writer),
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .async_logger = async_logger_instance,
            };

            assert(@intFromEnum(logger_result.level) <= @intFromEnum(config.Level.fatal));
            return logger_result;
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
            assert(@TypeOf(self.*) == Self);

            if (async_mode) {
                try self.async_logger.flush();
                return;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.writer.flush();
        }

        fn shouldRedact(self: *const Self, key: []const u8) bool {
            assert(key.len > 0);

            inline for (compile_time_redacted_fields) |redacted_field| {
                if (std.mem.eql(u8, redacted_field, key)) return true;
            }

            return if (self.redaction_config) |rc| rc.shouldRedact(key) else false;
        }

        fn traceContextForLog(self: *const Self) trace_mod.TraceContext {
            _ = self;

            if (correlation.getCurrentTaskContextIfSet()) |current_context| {
                return current_context.trace_context;
            }

            return trace_mod.TraceContext.init(false);
        }

        pub fn with(self: *Self, fields_input: anytype) ContextLogger {
            return ContextLogger.init(self, fields_input);
        }

        pub fn with_group(self: *Self, group_name: []const u8) ContextLogger {
            var context_logger = ContextLogger.initEmpty(self);
            context_logger.appendGroup(group_name);
            return context_logger;
        }

        pub fn trace(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = self.traceContextForLog();
            self.logInternal(.trace, message, default_trace_ctx, fields_struct);
        }

        pub fn debug(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = self.traceContextForLog();
            self.logInternal(.debug, message, default_trace_ctx, fields_struct);
        }

        pub fn info(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = self.traceContextForLog();
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

            const default_trace_ctx = self.traceContextForLog();
            self.logInternal(.warn, message, default_trace_ctx, fields_struct);
        }

        pub fn err(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = self.traceContextForLog();
            self.logInternal(.err, message, default_trace_ctx, fields_struct);
        }

        pub fn fatal(self: *Self, message: []const u8, fields_struct: anytype) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = self.traceContextForLog();
            self.logInternal(.fatal, message, default_trace_ctx, fields_struct);
        }

        // ========================================
        // ERGONOMIC API - Anonymous Struct Fields
        // ========================================

        /// Convert anonymous struct to field array at compile time
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

        /// Utility for dynamic field logging (rare use cases)
        /// Most logging should use the anonymous struct API
        pub fn logDynamic(
            self: *Self,
            level: config.Level,
            message: []const u8,
            dynamic_fields: []const field.Field,
        ) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(message.len > 0);
            assert(message.len < buffer_size);

            const default_trace_ctx = self.traceContextForLog();
            self.logWithTrace(level, message, default_trace_ctx, dynamic_fields);
        }

        pub fn spanStart(
            self: *Self,
            operation_name: []const u8,
            operation_fields_struct: anytype,
        ) correlation.Span {
            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(operation_name.len > 0);
            assert(operation_name.len < 256);

            const current_context = correlation.ensureTaskContext();
            assert(!trace_mod.is_all_zero_id(current_context.trace_context.trace_id[0..]));

            const current_span_bytes = current_context.currentSpan() orelse
                current_context.trace_context.parent_id;
            const span_created = correlation.Span.init(
                operation_name,
                current_span_bytes,
                current_context.trace_context,
            );
            assert(span_created.id >= 1);

            current_context.pushSpan(span_created.getSpanIdBytes()) catch unreachable;
            current_context.trace_context = span_created.trace_context;

            const span_fields = self.buildSpanStartFields(span_created, operation_fields_struct);
            assert(span_fields.len >= 4);

            self.logWithTrace(.info, operation_name, span_created.trace_context, span_fields.constSlice());

            assert(span_created.id >= 1);
            assert(span_created.task_id >= 1);
            return span_created;
        }

        const BoundedFieldArrayStart = struct {
            data: [max_fields + 4]field.Field = undefined,
            len: usize = 0,

            pub fn init(capacity: usize) !@This() {
                _ = capacity;
                return @This(){};
            }

            pub fn append(self: *@This(), item: field.Field) !void {
                if (self.len >= max_fields + 4) return error.Overflow;
                self.data[self.len] = item;
                self.len += 1;
            }

            pub fn slice(self: *const @This()) []const field.Field {
                return self.data[0..self.len];
            }

            pub fn constSlice(self: *const @This()) []const field.Field {
                return self.data[0..self.len];
            }
        };

        fn buildSpanStartFields(
            self: *Self,
            span_created: correlation.Span,
            operation_fields_struct: anytype,
        ) BoundedFieldArrayStart {
            assert(span_created.id >= 1);
            assert(span_created.task_id >= 1);
            assert(span_created.thread_id >= 1);

            var span_fields_array = BoundedFieldArrayStart.init(0) catch
                @panic("BoundedArray init failed with valid capacity");

            span_fields_array.append(field.Field.string("span_mark", "start")) catch
                @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("span_id", span_created.id)) catch
                @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("task_id", span_created.task_id)) catch
                @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("thread_id", span_created.thread_id)) catch
                @panic("BoundedArray append failed with sufficient capacity");

            const fields_array = self.structToFields(operation_fields_struct);
            for (fields_array) |field_item| {
                span_fields_array.append(field_item) catch unreachable;
            }

            assert(span_fields_array.len >= 4);
            assert(span_fields_array.len <= max_fields + 4);
            return span_fields_array;
        }

        pub fn spanEnd(
            self: *Self,
            completed_span: correlation.Span,
            completion_fields_struct: anytype,
        ) void {
            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(completed_span.id >= 1);
            assert(completed_span.task_id >= 1);
            assert(completed_span.thread_id >= 1);

            const current_context = correlation.ensureTaskContext();
            const current_span_bytes = current_context.currentSpan() orelse
                @panic("spanEnd() requires an active span");
            const completed_span_bytes = completed_span.getSpanIdBytes();
            assert(std.mem.eql(u8, &current_span_bytes, &completed_span_bytes));

            const finished_at = std.time.Instant.now() catch unreachable;
            const span_duration_ns = completed_span.durationNs(finished_at);
            assert(span_duration_ns > 0);

            const span_fields = self.buildSpanEndFields(
                completed_span,
                span_duration_ns,
                completion_fields_struct,
            );
            assert(span_fields.len >= 5);

            self.logWithTrace(
                .info,
                completed_span.name,
                completed_span.trace_context,
                span_fields.constSlice(),
            );

            _ = current_context.popSpan();

            const restored_span_bytes = current_context.currentSpan() orelse
                completed_span.parent_span_bytes orelse current_context.trace_context.parent_id;
            current_context.trace_context = completed_span.trace_context.withParentId(restored_span_bytes);
        }

        const BoundedFieldArray = struct {
            data: [max_fields + 5]field.Field = undefined,
            len: usize = 0,

            pub fn init(capacity: usize) !@This() {
                _ = capacity;
                return @This(){};
            }

            pub fn append(self: *@This(), item: field.Field) !void {
                if (self.len >= max_fields + 5) return error.Overflow;
                self.data[self.len] = item;
                self.len += 1;
            }

            pub fn slice(self: *const @This()) []const field.Field {
                return self.data[0..self.len];
            }

            pub fn constSlice(self: *const @This()) []const field.Field {
                return self.data[0..self.len];
            }
        };

        fn buildSpanEndFields(
            self: *Self,
            completed_span: correlation.Span,
            span_duration_ns: u64,
            completion_fields_struct: anytype,
        ) BoundedFieldArray {
            assert(completed_span.id >= 1);
            assert(completed_span.task_id >= 1);
            assert(completed_span.thread_id >= 1);
            assert(span_duration_ns > 0);

            var span_fields_array = BoundedFieldArray.init(0) catch
                @panic("BoundedArray init failed with valid capacity");

            span_fields_array.append(field.Field.string("span_mark", "end")) catch
                @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("span_id", completed_span.id)) catch
                @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("task_id", completed_span.task_id)) catch
                @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("thread_id", completed_span.thread_id)) catch
                @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(
                field.Field.uint("duration_ns", span_duration_ns),
            ) catch @panic("BoundedArray append failed with sufficient capacity");

            const fields_array = self.structToFields(completion_fields_struct);
            for (fields_array) |field_item| {
                span_fields_array.append(field_item) catch unreachable;
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

        fn appendMergedInputFields(
            self: *const Self,
            target: *FieldBuffer,
            fields_input: anytype,
        ) void {
            const InputType = @TypeOf(fields_input);
            const input_info = @typeInfo(InputType);

            if (comptime isFieldArray(InputType)) {
                target.appendSlice(fieldSliceFromInput(fields_input));
                return;
            }

            if (input_info == .@"struct") {
                const fields_array = self.structToFields(fields_input);
                target.appendSlice(&fields_array);
                return;
            }

            if (input_info == .pointer and input_info.pointer.size == .one) {
                const pointed_type = input_info.pointer.child;
                const pointed_info = @typeInfo(pointed_type);

                if (pointed_info == .@"struct") {
                    const fields_array = self.structToFields(fields_input.*);
                    target.appendSlice(&fields_array);
                    return;
                }

                if (pointed_info == .array and pointed_info.array.child == field.Field) {
                    target.appendSlice(fieldSliceFromInput(fields_input));
                    return;
                }
            }

            @compileError("Expected struct or field array, got " ++ @typeName(InputType));
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
                var buffer: [buffer_size]u8 = undefined;
                const formatted_len = self.formatLogEntry(
                    &buffer,
                    level,
                    message,
                    trace_ctx,
                    fields,
                ) catch {
                    self.noteDropped();
                    return;
                };
                self.async_logger.enqueue(buffer[0..formatted_len]);
                return;
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

            var buffer: [buffer_size]u8 = undefined;
            const formatted_len = self.formatLogEntry(
                &buffer,
                level,
                message,
                trace_ctx,
                fields,
            ) catch {
                self.noteDropped();
                return;
            };

            self.writeToOutput(buffer[0..formatted_len]) catch {
                self.noteDropped();
                self.noteWriteFailure();
                return;
            };
            self.noteWritten();
        }

        fn formatLogEntry(
            self: *const Self,
            buffer: []u8,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields: []const field.Field,
        ) !usize {
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(buffer.len == buffer_size);
            assert(message.len > 0);
            assert(message.len < buffer_size);
            assert(fields.len <= 1024);

            const actual_fields = if (fields.len > max_fields) fields[0..max_fields] else fields;
            assert(actual_fields.len <= max_fields);

            var writer: std.Io.Writer = .fixed(buffer);
            try self.writeLogHeader(&writer, level, message, trace_ctx);
            try self.writeLogFields(&writer, actual_fields);
            try self.writeLogFooter(&writer);

            const formatted_len = writer.buffered().len;
            assert(formatted_len > 0);
            assert(formatted_len <= buffer_size);
            return formatted_len;
        }

        fn writeToOutput(self: *Self, data: []const u8) std.Io.Writer.Error!void {
            assert(@TypeOf(self.*) == Self);
            assert(data.len > 0);
            assert(data.len <= buffer_size);

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.writer.ioWriter().writeAll(data);
        }

        fn writeLogHeader(
            self: *const Self,
            writer: *std.Io.Writer,
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
                .{
                    trace_ctx.trace_id_hex,
                    trace_ctx.span_id_hex,
                    std.time.milliTimestamp(),
                    std.Thread.getCurrentId(),
                },
            );
        }

        fn writeLogFields(
            self: *const Self,
            writer: *std.Io.Writer,
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
            writer: *std.Io.Writer,
        ) !void {
            _ = self;
            try writer.writeAll("}\n");
        }

        fn writeJsonFloat(writer: *std.Io.Writer, value: f64) !void {
            assert(!std.math.isNan(value));
            assert(!std.math.isInf(value));
            try writer.print("{}", .{value});
        }

        fn formatEventFieldValue(
            self: *const Self,
            writer: *std.Io.Writer,
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
                .float => |f| try writeJsonFloat(writer, f),
                .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
                .null => try writer.writeAll("null"),
                .redacted => |r| {
                    if (r.hint) |hint| {
                        try writer.print(
                            "\"[REDACTED:{s}:{s}]\"",
                            .{ @tagName(r.value_type), hint },
                        );
                    } else {
                        try writer.print("\"[REDACTED:{s}]\"", .{@tagName(r.value_type)});
                    }
                },
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

fn AsyncLogger(comptime cfg: config.Config) type {
    return struct {
        const Self = @This();
        const max_fields = cfg.max_fields;
        const buffer_size = cfg.buffer_size;
        const Batcher = async_batcher.Batcher(
            buffer_size,
            cfg.async_queue_size,
            cfg.batch_size,
        );

        pub const State = Batcher.State;

        sink: Batcher,

        pub fn init(output_writer: anytype, state: *State) Self {
            return .{
                .sink = Batcher.init(output_writer, state),
            };
        }

        pub fn deinit(self: *Self) void {
            self.sink.deinit();
        }

        pub fn enqueue(self: *Self, data: []const u8) void {
            assert(data.len > 0);
            assert(data.len <= buffer_size);
            self.sink.enqueue(data);
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

        // Performance monitoring
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

// Test the ergonomic API
test "Ergonomic API with anonymous struct fields" {
    const testing = std.testing;
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var logger = Logger(.{ .max_fields = 8 }).init(&writer);

    // Test the new ergonomic API
    logger.info("User login successful", .{
        .user_id = "12345",
        .username = "john_doe",
        .attempt = 1,
        .success = true,
        .ip_address = "192.168.1.100",
        .session_duration = 3.14,
    });

    const output = writer.buffered();

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

test "ContextLogger keeps persistent fields and lets call-site fields win" {
    const testing = std.testing;

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var logger = Logger(.{ .max_fields = 8 }).init(&writer);

    const request_logger = logger.with(.{
        .service = "api",
        .request_id = "base-request",
    });
    request_logger.info("Handled request", .{
        .request_id = "override-request",
        .status = 200,
    });

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"service\":\"api\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"request_id\":\"override-request\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"status\":200"));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "\"request_id\":\"base-request\""));
}

test "ContextLogger supports with_group" {
    const testing = std.testing;

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var logger = Logger(.{ .max_fields = 8 }).init(&writer);

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

test "Ergonomic API flattens nested anonymous structs" {
    const testing = std.testing;

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var logger = Logger(.{}).init(&writer);

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

test "Async logger preserves explicit trace context" {
    const testing = std.testing;

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var async_state = Logger(.{ .async_mode = true }).AsyncState{};
    var logger = Logger(.{ .async_mode = true }).initAsync(&writer, &async_state);

    const trace_ctx = trace_mod.TraceContext.init(true);
    logger.infoWithTrace("Async trace", trace_ctx, .{
        .component = "worker",
    });

    logger.drain();
    try logger.flush();

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, trace_ctx.trace_id_hex[0..]));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, trace_ctx.span_id_hex[0..]));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"component\":\"worker\""));
}

test "Async logger applies compile-time redaction" {
    const testing = std.testing;

    const SecureLogger = LoggerWithRedaction(
        .{ .async_mode = true },
        .{ .redacted_fields = &.{"token"} },
    );

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var async_state = SecureLogger.AsyncState{};
    var logger = SecureLogger.initAsync(&writer, &async_state);

    logger.info("Async redaction", .{
        .token = "secret-token",
        .visible = "hello",
    });

    logger.drain();
    try logger.flush();

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"visible\":\"hello\""));
    try testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "\"token\":\"[REDACTED:string]\"",
    ));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "secret-token"));
}

test "Ergonomic API preserves full unsigned integer range" {
    const testing = std.testing;

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var logger = Logger(.{}).init(&writer);

    const counter_total: u64 = std.math.maxInt(u64);
    logger.info("Counter snapshot", .{
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

test "Ergonomic API preserves float precision" {
    const testing = std.testing;

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var logger = Logger(.{}).init(&writer);

    const ratio = @as(f64, 1.0) / 3.0;
    logger.info("Ratio snapshot", .{
        .ratio = ratio,
    });

    const output = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(
        u8,
        output,
        1,
        "\"ratio\":0.3333333333333333",
    ));
}
