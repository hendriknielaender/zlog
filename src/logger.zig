const std = @import("std");

const config = @import("config.zig");
const field = @import("field.zig");
const trace_mod = @import("trace.zig");
const correlation = @import("correlation.zig");
const redaction = @import("redaction.zig");
const escape = @import("string_escape.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const OutputWriter = @import("output_writer.zig").OutputWriter;

fn syncIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn monotonicNowNs() i128 {
    return @as(i128, std.Io.Timestamp.now(syncIo(), .awake).nanoseconds);
}

fn realtimeNowMs() i64 {
    return std.Io.Timestamp.now(syncIo(), .real).toMilliseconds();
}

pub fn Logger(comptime cfg: config.Config) type {
    return LoggerWithRedaction(cfg, .{});
}

pub fn LoggerWithRedaction(comptime cfg: config.Config, comptime redaction_options: redaction.RedactionOptions) type {
    comptime {
        std.debug.assert(cfg.max_fields > 0);
        std.debug.assert(cfg.buffer_size >= 256);
        std.debug.assert(cfg.buffer_size <= 65536);
        if (cfg.async_mode) {
            std.debug.assert(cfg.async_queue_size > 0);
            std.debug.assert(cfg.batch_size > 0);
        }
    }

    return struct {
        const Self = @This();
        const max_fields = cfg.max_fields;
        const buffer_size = cfg.buffer_size;
        const async_mode = cfg.async_mode;
        const compile_time_redacted_fields = redaction_options.redacted_fields;

        const AsyncEntry = struct {
            bytes: []u8,
            level: config.Level,
        };

        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,
        mutex: if (async_mode) void else std.Io.Mutex = if (async_mode) {} else .init,
        output: if (async_mode) void else OutputWriter,
        allocator: if (async_mode) std.mem.Allocator else void = if (async_mode) undefined else {},
        async_logger: if (async_mode) ?*AsyncLogger else void = if (async_mode) null else {},
        managed_event_loop: if (async_mode) ?*EventLoop else void = if (async_mode) null else {},
        managed_event_loop_allocator: if (async_mode) ?std.mem.Allocator else void = if (async_mode) null else {},

        pub fn init(output_writer: *std.Io.Writer) Self {
            return initWithRedaction(output_writer, null);
        }

        pub fn initOwnedStderr(allocator: std.mem.Allocator, io: std.Io) !Self {
            return initOwnedStderrWithRedaction(allocator, io, null);
        }

        pub fn initOwnedStderrWithRedaction(
            allocator: std.mem.Allocator,
            io: std.Io,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            if (async_mode) {
                @compileError("initOwnedStderrWithRedaction is only available for synchronous loggers");
            }

            return .{
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .output = try OutputWriter.ownedStderr(allocator, io, buffer_size),
            };
        }

        pub fn initWithRedaction(
            output_writer: *std.Io.Writer,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) Self {
            if (async_mode) {
                @compileError("initWithRedaction is only available when async_mode = false; use initAsync* instead");
            }

            return .{
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .output = OutputWriter.borrowedWriter(output_writer),
            };
        }

        pub fn initAsync(
            output_writer: *std.Io.Writer,
            allocator: std.mem.Allocator,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsync requires async_mode = true in config");
            }

            const managed_loop = try allocator.create(EventLoop);
            errdefer allocator.destroy(managed_loop);
            managed_loop.* = EventLoop.init(allocator);
            errdefer managed_loop.deinit();

            return initAsyncWithOutput(
                OutputWriter.borrowedWriter(output_writer),
                managed_loop.io(),
                allocator,
                null,
                managed_loop,
                allocator,
            );
        }

        pub fn initAsyncOwnedStderr(
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsyncOwnedStderr requires async_mode = true in config");
            }
            _ = io;

            const managed_loop = try allocator.create(EventLoop);
            errdefer allocator.destroy(managed_loop);
            managed_loop.* = EventLoop.init(allocator);
            errdefer managed_loop.deinit();

            return initAsyncWithOutput(
                try OutputWriter.ownedStderr(allocator, managed_loop.io(), buffer_size),
                managed_loop.io(),
                allocator,
                null,
                managed_loop,
                allocator,
            );
        }

        pub fn initAsyncOwnedStderrWithIo(
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsyncOwnedStderrWithIo requires async_mode = true in config");
            }

            return initAsyncWithOutput(
                try OutputWriter.ownedStderr(allocator, io, buffer_size),
                io,
                allocator,
                null,
                null,
                null,
            );
        }

        pub fn initAsyncWithIo(
            output_writer: *std.Io.Writer,
            io: std.Io,
            allocator: std.mem.Allocator,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsyncWithIo requires async_mode = true in config");
            }

            return initAsyncWithOutput(
                OutputWriter.borrowedWriter(output_writer),
                io,
                allocator,
                null,
                null,
                null,
            );
        }

        pub fn initAsyncWithEventLoop(
            output_writer: *std.Io.Writer,
            event_loop: *EventLoop,
            allocator: std.mem.Allocator,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsyncWithEventLoop requires async_mode = true in config");
            }

            return initAsyncWithOutput(
                OutputWriter.borrowedWriter(output_writer),
                event_loop.io(),
                allocator,
                null,
                null,
                null,
            );
        }

        pub fn initAsyncWithRedactionManaged(
            output_writer: *std.Io.Writer,
            allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsyncWithRedactionManaged requires async_mode = true in config");
            }

            const managed_loop = try allocator.create(EventLoop);
            errdefer allocator.destroy(managed_loop);
            managed_loop.* = EventLoop.init(allocator);
            errdefer managed_loop.deinit();

            return initAsyncWithOutput(
                OutputWriter.borrowedWriter(output_writer),
                managed_loop.io(),
                allocator,
                redaction_cfg,
                managed_loop,
                allocator,
            );
        }

        pub fn initAsyncWithRedactionAndIo(
            output_writer: *std.Io.Writer,
            io: std.Io,
            allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsyncWithRedactionAndIo requires async_mode = true in config");
            }

            return initAsyncWithOutput(
                OutputWriter.borrowedWriter(output_writer),
                io,
                allocator,
                redaction_cfg,
                null,
                null,
            );
        }

        pub fn initAsyncWithRedactionAndEventLoop(
            output_writer: *std.Io.Writer,
            event_loop: *EventLoop,
            allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            if (!async_mode) {
                @compileError("initAsyncWithRedactionAndEventLoop requires async_mode = true in config");
            }

            return initAsyncWithOutput(
                OutputWriter.borrowedWriter(output_writer),
                event_loop.io(),
                allocator,
                redaction_cfg,
                null,
                null,
            );
        }

        fn initAsyncWithOutput(
            output: OutputWriter,
            io: std.Io,
            allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
            managed_event_loop: ?*EventLoop,
            managed_event_loop_allocator: ?std.mem.Allocator,
        ) !Self {
            const async_logger = try AsyncLogger.init(
                allocator,
                output,
                io,
                cfg.async_queue_size,
                cfg.batch_size,
            );
            errdefer async_logger.destroy();

            return .{
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .output = if (async_mode) {} else unreachable,
                .allocator = allocator,
                .async_logger = async_logger,
                .managed_event_loop = managed_event_loop,
                .managed_event_loop_allocator = managed_event_loop_allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (async_mode) {
                if (self.async_logger) |async_logger| {
                    async_logger.destroy();
                    self.async_logger = null;
                }
                if (self.managed_event_loop) |managed_loop| {
                    managed_loop.deinit();
                    if (self.managed_event_loop_allocator) |allocator| {
                        allocator.destroy(managed_loop);
                    }
                    self.managed_event_loop = null;
                    self.managed_event_loop_allocator = null;
                }
            } else {
                self.output.deinit();
            }
        }

        pub fn deinitWithAllocator(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            self.deinit();
        }

        pub fn runEventLoop(self: *Self) !void {
            if (!async_mode) return;
            if (self.async_logger) |async_logger| {
                async_logger.flushPending();
            }
        }

        pub fn runEventLoopUntilDone(self: *Self) !void {
            if (!async_mode) return;
            if (self.async_logger) |async_logger| {
                async_logger.flushPending();
                async_logger.waitUntilDrained();
            }
        }

        fn shouldRedact(self: *const Self, key: []const u8) bool {
            inline for (compile_time_redacted_fields) |redacted_field| {
                if (std.mem.eql(u8, redacted_field, key)) return true;
            }
            return if (self.redaction_config) |cfg_ptr| cfg_ptr.shouldRedact(key) else false;
        }

        pub fn trace(self: *Self, message: []const u8, fields_struct: anytype) void {
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.trace, message, default_trace_ctx, fields_struct);
        }

        pub fn debug(self: *Self, message: []const u8, fields_struct: anytype) void {
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.debug, message, default_trace_ctx, fields_struct);
        }

        pub fn info(self: *Self, message: []const u8, fields_struct: anytype) void {
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.info, message, default_trace_ctx, fields_struct);
        }

        pub fn infoWithTrace(
            self: *Self,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields_struct: anytype,
        ) void {
            self.logInternal(.info, message, trace_ctx, fields_struct);
        }

        pub fn warn(self: *Self, message: []const u8, fields_struct: anytype) void {
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.warn, message, default_trace_ctx, fields_struct);
        }

        pub fn err(self: *Self, message: []const u8, fields_struct: anytype) void {
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.err, message, default_trace_ctx, fields_struct);
        }

        pub fn fatal(self: *Self, message: []const u8, fields_struct: anytype) void {
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logInternal(.fatal, message, default_trace_ctx, fields_struct);
        }

        pub fn logDynamic(
            self: *Self,
            level: config.Level,
            message: []const u8,
            dynamic_fields: []const field.Field,
        ) void {
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(level, message, default_trace_ctx, dynamic_fields);
        }

        pub fn spanStart(self: *Self, operation_name: []const u8, operation_fields_struct: anytype) correlation.Span {
            const current_context = correlation.getCurrentTaskContext();
            const span = correlation.Span.init(operation_name, current_context.currentSpan(), current_context.trace_context);

            var fields_array = tryBuildSpanStartFields(self, span, operation_fields_struct);
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.info, operation_name, default_trace_ctx, fields_array.constSlice());

            return span;
        }

        pub fn spanEnd(self: *Self, completed_span: correlation.Span, completion_fields_struct: anytype) void {
            const span_end_time_ns = monotonicNowNs();
            const span_duration_ns = span_end_time_ns - completed_span.start_time;

            var fields_array = tryBuildSpanEndFields(self, completed_span, span_duration_ns, completion_fields_struct);
            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.info, completed_span.name, default_trace_ctx, fields_array.constSlice());
        }

        const SpanStartFields = struct {
            data: [max_fields + 4]field.Field = undefined,
            len: usize = 0,

            fn append(self: *@This(), item: field.Field) void {
                if (self.len >= self.data.len) return;
                self.data[self.len] = item;
                self.len += 1;
            }

            fn constSlice(self: *const @This()) []const field.Field {
                return self.data[0..self.len];
            }
        };

        const SpanEndFields = struct {
            data: [max_fields + 5]field.Field = undefined,
            len: usize = 0,

            fn append(self: *@This(), item: field.Field) void {
                if (self.len >= self.data.len) return;
                self.data[self.len] = item;
                self.len += 1;
            }

            fn constSlice(self: *const @This()) []const field.Field {
                return self.data[0..self.len];
            }
        };

        fn tryBuildSpanStartFields(
            self: *Self,
            span: correlation.Span,
            operation_fields_struct: anytype,
        ) SpanStartFields {
            var fields_array = SpanStartFields{};
            fields_array.append(field.Field.string("span_mark", "start"));
            fields_array.append(field.Field.uint("span_id", span.id));
            fields_array.append(field.Field.uint("task_id", span.task_id));
            fields_array.append(field.Field.uint("thread_id", span.thread_id));

            const extra_fields = self.structToFields(operation_fields_struct);
            for (extra_fields) |item| fields_array.append(item);
            return fields_array;
        }

        fn tryBuildSpanEndFields(
            self: *Self,
            span: correlation.Span,
            duration_ns: i128,
            completion_fields_struct: anytype,
        ) SpanEndFields {
            var fields_array = SpanEndFields{};
            fields_array.append(field.Field.string("span_mark", "end"));
            fields_array.append(field.Field.uint("span_id", span.id));
            fields_array.append(field.Field.uint("task_id", span.task_id));
            fields_array.append(field.Field.uint("thread_id", span.thread_id));
            fields_array.append(field.Field.uint("duration_ns", @as(u64, @intCast(duration_ns))));

            const extra_fields = self.structToFields(completion_fields_struct);
            for (extra_fields) |item| fields_array.append(item);
            return fields_array;
        }

        fn logInternal(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields_input: anytype,
        ) void {
            if (!cfg.enable_logging) return;

            const InputType = @TypeOf(fields_input);
            const input_info = @typeInfo(InputType);

            if (comptime isFieldArray(InputType)) {
                self.logWithTrace(level, message, trace_ctx, fields_input);
                return;
            }

            if (input_info == .@"struct") {
                const fields_array = self.structToFields(fields_input);
                self.logWithTrace(level, message, trace_ctx, &fields_array);
                return;
            }

            if (input_info == .pointer and input_info.pointer.size == .one) {
                const pointed_info = @typeInfo(input_info.pointer.child);
                if (pointed_info == .@"struct") {
                    const fields_array = self.structToFields(fields_input.*);
                    self.logWithTrace(level, message, trace_ctx, &fields_array);
                    return;
                }
                if (pointed_info == .array and pointed_info.array.child == field.Field) {
                    self.logWithTrace(level, message, trace_ctx, fields_input);
                    return;
                }
            }

            @compileError("Expected struct or field array, got " ++ @typeName(InputType));
        }

        fn isFieldArray(comptime T: type) bool {
            const type_info = @typeInfo(T);
            return switch (type_info) {
                .pointer => |ptr| blk: {
                    if (ptr.size == .slice and ptr.child == field.Field) break :blk true;
                    if (ptr.size == .one) {
                        const pointed_info = @typeInfo(ptr.child);
                        if (pointed_info == .array and pointed_info.array.child == field.Field) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
        }

        fn structToFields(self: *const Self, fields_struct: anytype) [getFieldCount(@TypeOf(fields_struct))]field.Field {
            _ = self;
            const struct_info = @typeInfo(@TypeOf(fields_struct));
            const struct_fields = switch (struct_info) {
                .@"struct" => |struct_type| struct_type.fields,
                else => @compileError("Expected struct, got " ++ @typeName(@TypeOf(fields_struct))),
            };

            var result: [struct_fields.len]field.Field = undefined;
            inline for (struct_fields, 0..) |struct_field, i| {
                result[i] = convertToField(struct_field.name, @field(fields_struct, struct_field.name));
            }
            return result;
        }

        fn getFieldCount(comptime T: type) comptime_int {
            const type_info = @typeInfo(T);
            if (type_info == .@"struct") return type_info.@"struct".fields.len;
            if (type_info == .pointer and type_info.pointer.size == .one) {
                const pointed_info = @typeInfo(type_info.pointer.child);
                if (pointed_info == .@"struct") return pointed_info.@"struct".fields.len;
                if (pointed_info == .array and pointed_info.array.child == field.Field) return pointed_info.array.len;
            }
            @compileError("Expected struct or field array, got " ++ @typeName(T));
        }

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
                        const child_info = @typeInfo(ptr_info.child);
                        if (child_info == .array and child_info.array.child == u8) {
                            return field.Field.string(name, value);
                        }
                        @compileError("Unsupported pointer type: " ++ @typeName(T));
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
                .@"struct" => if (T == field.Field)
                    value
                else
                    @compileError("Unsupported struct type: " ++ @typeName(T)),
                else => @compileError("Unsupported field type: " ++ @typeName(T)),
            };
        }

        fn logWithTrace(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields: []const field.Field,
        ) void {
            if (!cfg.enable_logging) return;
            if (@intFromEnum(level) < @intFromEnum(self.level)) return;

            if (async_mode) {
                if (self.async_logger) |async_logger| {
                    const bytes = self.formatLogAlloc(level, message, trace_ctx, fields) catch return;
                    async_logger.enqueue(bytes, level);
                }
                return;
            }

            self.formatAndWriteLog(level, message, trace_ctx, fields);
        }

        fn formatLogAlloc(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields: []const field.Field,
        ) ![]u8 {
            var buffer: [buffer_size]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try self.writeFormatted(&writer, level, message, trace_ctx, fields);
            return try self.allocator.dupe(u8, writer.buffered());
        }

        fn formatAndWriteLog(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields: []const field.Field,
        ) void {
            var buffer: [buffer_size]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            self.writeFormatted(&writer, level, message, trace_ctx, fields) catch return;
            self.writeToOutput(writer.buffered());
        }

        fn writeFormatted(
            self: *Self,
            writer: *std.Io.Writer,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            fields: []const field.Field,
        ) !void {
            const actual_fields = if (fields.len > max_fields) fields[0..max_fields] else fields;
            try self.writeLogHeader(writer, level, message, trace_ctx);
            try self.writeLogFields(writer, actual_fields);
            try writer.writeAll("}\n");
        }

        fn writeToOutput(self: *Self, data: []const u8) void {
            self.mutex.lockUncancelable(syncIo());
            defer self.mutex.unlock(syncIo());
            self.output.writeAll(data) catch return;
            self.output.flush() catch return;
        }

        fn writeLogHeader(
            self: *const Self,
            writer: *std.Io.Writer,
            level: config.Level,
            message: []const u8,
            trace_ctx: trace_mod.TraceContext,
        ) !void {
            _ = self;
            try writer.writeAll("{\"level\":\"");
            try writer.writeAll(level.string());
            try writer.writeAll("\",\"msg\":\"");
            try escape.write(cfg, writer, message);
            try writer.print(
                "\",\"trace\":\"{s}\",\"span\":\"{s}\",\"ts\":{},\"tid\":{}",
                .{
                    trace_ctx.trace_id_hex,
                    trace_ctx.span_id_hex,
                    realtimeNowMs(),
                    std.Thread.getCurrentId(),
                },
            );
        }

        fn writeLogFields(
            self: *const Self,
            writer: *std.Io.Writer,
            fields: []const field.Field,
        ) !void {
            for (fields) |field_item| {
                try writer.writeAll(",\"");
                try escape.write(cfg, writer, field_item.key);
                try writer.writeAll("\":");

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
                    try formatFieldValue(writer, redacted_value);
                } else {
                    try formatFieldValue(writer, field_item.value);
                }
            }
        }

        fn formatFieldValue(writer: *std.Io.Writer, value: field.Field.Value) !void {
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

        const AsyncQueue = struct {
            allocator: std.mem.Allocator,
            entries: []AsyncEntry,
            read_index: usize = 0,
            write_index: usize = 0,
            len: usize = 0,
            mutex: std.Io.Mutex = .init,
            condition: std.Io.Condition = .init,

            fn init(allocator: std.mem.Allocator, capacity: usize) !AsyncQueue {
                return .{
                    .allocator = allocator,
                    .entries = try allocator.alloc(AsyncEntry, capacity),
                };
            }

            fn deinit(self: *AsyncQueue) void {
                for (0..self.len) |offset| {
                    const index = (self.read_index + offset) % self.entries.len;
                    self.allocator.free(self.entries[index].bytes);
                }
                self.allocator.free(self.entries);
                self.* = undefined;
            }

            fn push(self: *AsyncQueue, io: std.Io, entry: AsyncEntry) bool {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);

                if (self.len == self.entries.len) return false;

                self.entries[self.write_index] = entry;
                self.write_index = (self.write_index + 1) % self.entries.len;
                self.len += 1;
                self.condition.signal(io);
                return true;
            }

            fn popBatch(self: *AsyncQueue, io: std.Io, batch: []AsyncEntry) usize {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);

                const count = @min(self.len, batch.len);
                for (0..count) |i| {
                    batch[i] = self.entries[self.read_index];
                    self.read_index = (self.read_index + 1) % self.entries.len;
                }
                self.len -= count;
                if (count > 0) self.condition.broadcast(io);
                return count;
            }

            fn popBatchBlocking(
                self: *AsyncQueue,
                io: std.Io,
                should_stop: *const std.atomic.Value(bool),
                batch: []AsyncEntry,
            ) ?usize {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);

                while (self.len == 0 and !should_stop.load(.acquire)) {
                    self.condition.waitUncancelable(io, &self.mutex);
                }

                if (self.len == 0 and should_stop.load(.acquire)) return null;

                const count = @min(self.len, batch.len);
                for (0..count) |i| {
                    batch[i] = self.entries[self.read_index];
                    self.read_index = (self.read_index + 1) % self.entries.len;
                }
                self.len -= count;
                self.condition.broadcast(io);
                return count;
            }

            fn waitUntilEmpty(self: *AsyncQueue, io: std.Io) void {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                while (self.len != 0) {
                    self.condition.waitUncancelable(io, &self.mutex);
                }
            }

            fn wakeAll(self: *AsyncQueue, io: std.Io) void {
                self.condition.broadcast(io);
            }

            fn size(self: *AsyncQueue, io: std.Io) usize {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                return self.len;
            }
        };

        const AsyncLogger = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            output: OutputWriter,
            queue: AsyncQueue,
            batch: []AsyncEntry,
            scratch: std.ArrayList(u8) = .empty,
            should_stop: std.atomic.Value(bool) = .init(false),
            worker_future: std.Io.Future(std.Io.Cancelable!void),
            logs_written: std.atomic.Value(u64) = .init(0),
            logs_dropped: std.atomic.Value(u64) = .init(0),
            flush_count: std.atomic.Value(u64) = .init(0),

            fn init(
                allocator: std.mem.Allocator,
                output: OutputWriter,
                io: std.Io,
                queue_size: u32,
                batch_size: u32,
            ) !*AsyncLogger {
                const self = try allocator.create(AsyncLogger);
                errdefer allocator.destroy(self);

                var queue = try AsyncQueue.init(allocator, queue_size);
                errdefer queue.deinit();

                const batch = try allocator.alloc(AsyncEntry, @max(@as(usize, 1), @min(queue_size, batch_size)));
                errdefer allocator.free(batch);

                self.* = .{
                    .allocator = allocator,
                    .io = io,
                    .output = output,
                    .queue = queue,
                    .batch = batch,
                    .worker_future = undefined,
                };

                self.worker_future = try io.concurrent(workerMain, .{self});
                return self;
            }

            fn destroy(self: *AsyncLogger) void {
                self.should_stop.store(true, .release);
                self.queue.wakeAll(self.io);
                _ = self.worker_future.await(self.io) catch {};
                self.flushPending();
                self.scratch.deinit(self.allocator);
                self.output.deinit();
                self.queue.deinit();
                self.allocator.free(self.batch);
                const allocator = self.allocator;
                allocator.destroy(self);
            }

            fn enqueue(self: *AsyncLogger, bytes: []u8, level: config.Level) void {
                if (!self.queue.push(self.io, .{ .bytes = bytes, .level = level })) {
                    self.allocator.free(bytes);
                    _ = self.logs_dropped.fetchAdd(1, .monotonic);
                }
            }

            fn flushPending(self: *AsyncLogger) void {
                while (true) {
                    const count = self.queue.popBatch(self.io, self.batch);
                    if (count == 0) break;
                    self.writeBatch(self.batch[0..count]);
                }
            }

            fn waitUntilDrained(self: *AsyncLogger) void {
                self.queue.waitUntilEmpty(self.io);
            }

            fn writeBatch(self: *AsyncLogger, entries: []AsyncEntry) void {
                self.scratch.items.len = 0;

                for (entries) |entry| {
                    self.scratch.appendSlice(self.allocator, entry.bytes) catch {
                        self.output.writeAll(entry.bytes) catch {};
                        self.output.flush() catch {};
                        self.allocator.free(entry.bytes);
                        continue;
                    };
                }

                if (self.scratch.items.len > 0) {
                    self.output.writeAll(self.scratch.items) catch {};
                    self.output.flush() catch {};
                }

                for (entries) |entry| {
                    self.allocator.free(entry.bytes);
                }

                _ = self.logs_written.fetchAdd(entries.len, .monotonic);
                _ = self.flush_count.fetchAdd(1, .monotonic);
            }

            fn workerMain(self: *AsyncLogger) std.Io.Cancelable!void {
                while (true) {
                    const count = self.queue.popBatchBlocking(self.io, &self.should_stop, self.batch) orelse break;
                    if (count != 0) self.writeBatch(self.batch[0..count]);
                }
            }

            fn getMetrics(self: *const AsyncLogger) struct {
                logs_written: u64,
                logs_dropped: u64,
                flush_count: u64,
                queue_size: u32,
            } {
                return .{
                    .logs_written = self.logs_written.load(.monotonic),
                    .logs_dropped = self.logs_dropped.load(.monotonic),
                    .flush_count = self.flush_count.load(.monotonic),
                    .queue_size = @intCast(self.queue.size(self.io)),
                };
            }
        };

        pub fn getMetrics(self: *const Self) struct {
            logs_written: u64,
            logs_dropped: u64,
            flush_count: u64,
            queue_size: u32,
        } {
            if (async_mode) {
                return self.async_logger.?.getMetrics();
            }
            return .{
                .logs_written = 0,
                .logs_dropped = 0,
                .flush_count = 0,
                .queue_size = 0,
            };
        }
    };
}

const testing = std.testing;

test "synchronous logger writes json" {
    var sink_buffer: [2048]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    var log = Logger(.{}).init(&sink);
    defer log.deinit();

    log.info("hello", .{ .user = "alice", .count = @as(i64, 3) });

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"level\":\"INFO\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"user\":\"alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"count\":3") != null);
}

test "logger redacts runtime fields" {
    var sink_buffer: [2048]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    var redaction_storage: [4][]const u8 = undefined;
    var redaction_cfg = redaction.RedactionConfig.init(&redaction_storage);
    defer redaction_cfg.deinit();
    try redaction_cfg.addKey("password");

    var log = Logger(.{}).initWithRedaction(&sink, &redaction_cfg);
    defer log.deinit();

    log.info("login", .{ .user = "alice", .password = "secret" });

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, output, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[REDACTED:string]") != null);
}

test "async logger flushes queued logs" {
    var sink_buffer: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    var log = try Logger(.{ .async_mode = true }).initAsync(&sink, testing.allocator);
    defer log.deinit();

    log.info("async", .{ .kind = "basic" });
    try log.runEventLoopUntilDone();

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"async\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"kind\":\"basic\"") != null);
}
