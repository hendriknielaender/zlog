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
        mutex: std.Thread.Mutex = .{},
        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,

        async_logger: if (async_mode) ?AsyncLogger(cfg) else void = if (async_mode) null else {},

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
            };

            assert(@TypeOf(logger_result.writer) == std.io.AnyWriter);
            assert(@intFromEnum(logger_result.level) <= @intFromEnum(config.Level.fatal));
            return logger_result;
        }

        pub fn initAsync(
            output_writer: std.io.AnyWriter,
            event_loop: *xev.Loop,
            memory_allocator: std.mem.Allocator,
        ) !Self {
            return initAsyncWithRedaction(output_writer, event_loop, memory_allocator, null);
        }

        pub fn initAsyncWithRedaction(
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
            assert(buffer_size >= 256);

            const async_logger_instance = try AsyncLogger(cfg).init(memory_allocator, output_writer, event_loop, async_queue_size, cfg.batch_size);

            const logger_result = Self{
                .writer = output_writer,
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .async_logger = async_logger_instance,
            };

            assert(@TypeOf(logger_result.writer) == std.io.AnyWriter);
            assert(@intFromEnum(logger_result.level) <= @intFromEnum(config.Level.fatal));
            return logger_result;
        }

        pub fn deinit(self: *Self) void {
            if (async_mode) {
                if (self.async_logger) |*async_logger| {
                    async_logger.deinit();
                }
            }
        }

        fn shouldRedact(self: *const Self, key: []const u8) bool {
            inline for (compile_time_redacted_fields) |redacted_field| {
                if (std.mem.eql(u8, redacted_field, key)) return true;
            }

            return if (self.redaction_config) |rc| rc.shouldRedact(key) else false;
        }

        pub fn trace(self: *Self, trace_message: []const u8, trace_fields: []const field.Field) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(trace_message.len > 0);
            assert(trace_message.len < buffer_size);
            assert(trace_fields.len <= 1024);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.trace, trace_message, default_trace_ctx, trace_fields);
        }

        pub fn debug(self: *Self, debug_message: []const u8, debug_fields: []const field.Field) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(debug_message.len > 0);
            assert(debug_message.len < buffer_size);
            assert(debug_fields.len <= 1024);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.debug, debug_message, default_trace_ctx, debug_fields);
        }

        pub fn info(self: *Self, info_message: []const u8, info_fields: []const field.Field) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(info_message.len > 0);
            assert(info_message.len < buffer_size);
            assert(info_fields.len <= 1024);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.info, info_message, default_trace_ctx, info_fields);
        }

        pub fn infoWithTrace(
            self: *Self,
            info_message: []const u8,
            trace_ctx: trace_mod.TraceContext,
            info_fields: []const field.Field,
        ) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(info_message.len > 0);
            assert(info_message.len < buffer_size);
            assert(info_fields.len <= 1024);
            self.logWithTrace(.info, info_message, trace_ctx, info_fields);
        }

        pub fn warn(self: *Self, warn_message: []const u8, warn_fields: []const field.Field) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(warn_message.len > 0);
            assert(warn_message.len < buffer_size);
            assert(warn_fields.len <= 1024);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.warn, warn_message, default_trace_ctx, warn_fields);
        }

        pub fn err(self: *Self, error_message: []const u8, error_fields: []const field.Field) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(error_message.len > 0);
            assert(error_message.len < buffer_size);
            assert(error_fields.len <= 1024);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.err, error_message, default_trace_ctx, error_fields);
        }

        pub fn fatal(self: *Self, fatal_message: []const u8, fatal_fields: []const field.Field) void {
            comptime {
                if (!cfg.enable_logging) return;
            }

            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(fatal_message.len > 0);
            assert(fatal_message.len < buffer_size);
            assert(fatal_fields.len <= 1024);

            const default_trace_ctx = trace_mod.TraceContext.init(false);
            self.logWithTrace(.fatal, fatal_message, default_trace_ctx, fatal_fields);
        }

        pub fn spanStart(self: *Self, operation_name: []const u8, operation_fields: []const field.Field) correlation.Span {
            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(operation_name.len > 0);
            assert(operation_name.len < 256);
            assert(operation_fields.len <= max_fields);

            const current_context = correlation.getCurrentTaskContext();
            assert(!trace_mod.is_all_zero_id(current_context.trace_context.trace_id[0..]));

            const current_span_bytes = current_context.currentSpan();
            const span_created = correlation.Span.init(operation_name, current_span_bytes, current_context.trace_context);
            assert(span_created.id >= 1);

            var span_fields_array = std.BoundedArray(field.Field, max_fields + 4).init(0) catch @panic("BoundedArray init failed with valid capacity");
            span_fields_array.append(field.Field.string("span_mark", "start")) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("span_id", span_created.id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("task_id", span_created.task_id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("thread_id", span_created.thread_id)) catch @panic("BoundedArray append failed with sufficient capacity");

            for (operation_fields) |field_item| {
                span_fields_array.append(field_item) catch break;
            }

            assert(span_fields_array.len >= 4);
            self.info(operation_name, span_fields_array.constSlice());
            return span_created;
        }

        pub fn spanEnd(self: *Self, completed_span: correlation.Span, completion_fields: []const field.Field) void {
            assert(@intFromEnum(self.level) <= @intFromEnum(config.Level.fatal));
            assert(completed_span.id >= 1);
            assert(completed_span.task_id >= 1);
            assert(completed_span.start_time > 0);
            assert(completion_fields.len <= max_fields);

            const end_timestamp_ns = std.time.nanoTimestamp();
            assert(end_timestamp_ns > completed_span.start_time);

            const duration_elapsed_ns = end_timestamp_ns - completed_span.start_time;
            assert(duration_elapsed_ns >= 0);

            var span_fields_array = std.BoundedArray(field.Field, max_fields + 5).init(0) catch @panic("BoundedArray init failed with valid capacity");
            span_fields_array.append(field.Field.string("span_mark", "end")) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("span_id", completed_span.id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("task_id", completed_span.task_id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("thread_id", completed_span.thread_id)) catch @panic("BoundedArray append failed with sufficient capacity");
            span_fields_array.append(field.Field.uint("duration_ns", @intCast(duration_elapsed_ns))) catch @panic("BoundedArray append failed with sufficient capacity");

            for (completion_fields) |field_item| {
                span_fields_array.append(field_item) catch break;
            }

            assert(span_fields_array.len >= 5);
            self.info(completed_span.name, span_fields_array.constSlice());
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

            if (@intFromEnum(level) < @intFromEnum(self.level)) return;

            if (async_mode) {
                if (self.async_logger) |*async_logger| {
                    async_logger.logAsync(level, self.level, message, fields, trace_ctx, max_fields) catch {
                        return;
                    };
                    return;
                }
            }

            var buffer: [buffer_size]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buffer);
            const writer = fbs.writer();

            writer.print(
                "{{\"level\":\"{s}\",\"msg\":\"",
                .{level.string()},
            ) catch return;
            escape.write(cfg, writer, message) catch return;
            writer.print(
                "\",\"trace\":\"{s}\",\"span\":\"{s}\",\"ts\":{},\"tid\":{}",
                .{ trace_ctx.trace_id_hex, trace_ctx.span_id_hex, std.time.milliTimestamp(), std.Thread.getCurrentId() },
            ) catch return;

            for (fields) |field_item| {
                writer.writeAll(",\"") catch return;
                escape.write(cfg, writer, field_item.key) catch return;
                writer.writeAll("\":") catch return;

                if (self.shouldRedact(field_item.key)) {
                    const redacted_type: field.Field.RedactedType = switch (field_item.value) {
                        .string => .string,
                        .int => .int,
                        .uint => .uint,
                        .float => .float,
                        .boolean => .any,
                        .null => .any,
                        .redacted => |r| r.value_type,
                    };
                    writer.print("\"[REDACTED:{s}]\"", .{@tagName(redacted_type)}) catch return;
                } else {
                    switch (field_item.value) {
                        .string => |s| {
                            writer.writeByte('"') catch return;
                            escape.write(cfg, writer, s) catch return;
                            writer.writeByte('"') catch return;
                        },
                        .int => |i| writer.print("{}", .{i}) catch return,
                        .uint => |u| writer.print("{}", .{u}) catch return,
                        .float => |f| writer.print("{d:.5}", .{f}) catch return,
                        .boolean => |b| writer.writeAll(if (b) "true" else "false") catch return,
                        .null => writer.writeAll("null") catch return,
                        .redacted => |r| {
                            if (r.hint) |hint| {
                                writer.print("\"[REDACTED:{s}:{s}]\"", .{ @tagName(r.value_type), hint }) catch return;
                            } else {
                                writer.print("\"[REDACTED:{s}]\"", .{@tagName(r.value_type)}) catch return;
                            }
                        },
                    }
                }
            }

            writer.writeAll("}\n") catch return;

            const formatted_len: u32 = @intCast(fbs.getPos() catch return);

            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.writer.write(buffer[0..formatted_len]) catch {};
        }
    };
}

pub fn AsyncLogger(comptime cfg: config.Config) type {
    return struct {
        const Self = @This();
        const BUFFER_SIZE = 1024;
        const RING_SIZE = 1024;
        const BATCH_SIZE = 32;

        const LogEntry = struct {
            data: [BUFFER_SIZE]u8,
            len: u32,
            timestamp_ns: u64,
        };

        const AsyncRingBuffer = struct {
            entries: [RING_SIZE]LogEntry,
            write_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
            read_pos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

            fn tryPush(self: *@This(), entry: LogEntry) bool {
                const current_write = self.write_pos.load(.acquire);
                const current_read = self.read_pos.load(.acquire);

                if (current_write - current_read >= RING_SIZE) return false;

                self.entries[current_write & (RING_SIZE - 1)] = entry;
                self.write_pos.store(current_write + 1, .release);
                return true;
            }

            fn tryPop(self: *@This()) ?LogEntry {
                const current_read = self.read_pos.load(.acquire);
                const current_write = self.write_pos.load(.acquire);

                if (current_read == current_write) return null;

                const entry = self.entries[current_read & (RING_SIZE - 1)];
                self.read_pos.store(current_read + 1, .release);
                return entry;
            }

            fn isEmpty(self: *@This()) bool {
                return self.read_pos.load(.acquire) == self.write_pos.load(.acquire);
            }
        };

        allocator: std.mem.Allocator,
        writer: std.io.AnyWriter,
        loop: *xev.Loop,
        ring_buffer: AsyncRingBuffer,

        timer_completion: xev.Completion,
        timer: xev.Timer,

        shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        write_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        batch_buffer: [BATCH_SIZE * BUFFER_SIZE]u8,

        pub fn init(
            allocator: std.mem.Allocator,
            writer: std.io.AnyWriter,
            loop: *xev.Loop,
            queue_size: u32,
            batch_size: u32,
        ) !Self {
            _ = queue_size;
            _ = batch_size;

            var self = Self{
                .allocator = allocator,
                .writer = writer,
                .loop = loop,
                .ring_buffer = AsyncRingBuffer{
                    // SAFETY: entries will be initialized in the loop below
                    .entries = undefined,
                },
                // SAFETY: timer_completion will be initialized by timer.run()
                .timer_completion = undefined,
                .timer = try xev.Timer.init(),
                // SAFETY: batch_buffer is only used during processBatch() which writes before reading
                .batch_buffer = undefined,
            };

            for (&self.ring_buffer.entries) |*entry| {
                entry.* = LogEntry{
                    // SAFETY: data is only read when len > 0, and len is initialized to 0
                    .data = undefined,
                    .len = 0,
                    .timestamp_ns = 0,
                };
            }

            self.timer.run(
                loop,
                &self.timer_completion,
                1_000_000,
                Self,
                &self,
                Self.onTimer,
            );

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.shutdown.store(true, .release);

            self.flushPending();

            self.timer.deinit();
        }

        pub fn logAsync(
            self: *Self,
            level: config.Level,
            current_level: config.Level,
            message: []const u8,
            fields: []const field.Field,
            trace_ctx: trace_mod.TraceContext,
            max_fields: u16,
        ) !void {
            assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
            assert(@intFromEnum(current_level) <= @intFromEnum(config.Level.fatal));
            assert(fields.len <= max_fields);

            if (@intFromEnum(level) < @intFromEnum(current_level)) return;

            var format_buffer: [BUFFER_SIZE]u8 = undefined;
            const formatted_len = self.formatEventOptimized(
                level,
                message,
                fields[0..@min(fields.len, max_fields)],
                trace_ctx,
                &format_buffer,
            ) catch return;

            var entry = LogEntry{
                // SAFETY: data will be filled by memcpy immediately after this initialization
                .data = undefined,
                .len = @intCast(formatted_len),
                .timestamp_ns = @intCast(std.time.nanoTimestamp()),
            };

            @memcpy(entry.data[0..formatted_len], format_buffer[0..formatted_len]);

            if (!self.ring_buffer.tryPush(entry)) {
                return error.QueueFull;
            }
        }

        fn onTimer(
            userdata: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;

            const self = userdata.?;

            if (self.shutdown.load(.acquire)) {
                return .disarm;
            }

            if (!self.write_pending.load(.acquire)) {
                self.processBatch();
            }

            self.timer.run(
                loop,
                c,
                1_000_000,
                Self,
                self,
                Self.onTimer,
            );

            return .disarm;
        }

        fn processBatch(self: *Self) void {
            var batch_len: u32 = 0;
            var entries_processed: u32 = 0;

            while (entries_processed < BATCH_SIZE) {
                const entry = self.ring_buffer.tryPop() orelse break;

                if (batch_len + entry.len > self.batch_buffer.len) break;

                @memcpy(
                    self.batch_buffer[batch_len .. batch_len + entry.len],
                    entry.data[0..entry.len],
                );
                batch_len += entry.len;
                entries_processed += 1;
            }

            if (batch_len > 0) {
                self.write_pending.store(true, .release);
                _ = self.writer.write(self.batch_buffer[0..batch_len]) catch {};
                self.write_pending.store(false, .release);
            }
        }

        pub fn flushPending(self: *Self) void {
            while (!self.ring_buffer.isEmpty()) {
                self.processBatch();

                while (self.write_pending.load(.acquire)) {
                    std.Thread.yield() catch |err| std.debug.panic("Thread yield failed: {}", .{err});
                }
            }
        }

        fn formatEventOptimized(
            self: *Self,
            level: config.Level,
            message: []const u8,
            fields: []const field.Field,
            trace_ctx: trace_mod.TraceContext,
            buffer: []u8,
        ) !u32 {
            _ = self;
            assert(buffer.len >= 256);

            var fbs = std.io.fixedBufferStream(buffer);
            const writer = fbs.writer();

            try writer.print(
                "{{\"level\":\"{s}\",\"msg\":\"",
                .{level.string()},
            );
            try escape.write(cfg, writer, message);
            try writer.print(
                "\",\"trace\":\"{s}\",\"span\":\"{s}\",\"ts\":{},\"tid\":{}",
                .{ trace_ctx.trace_id_hex, trace_ctx.span_id_hex, std.time.milliTimestamp(), std.Thread.getCurrentId() },
            );

            for (fields) |field_item| {
                try writer.writeAll(",\"");
                try escape.write(cfg, writer, field_item.key);
                try writer.writeAll("\":");
                switch (field_item.value) {
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

            try writer.writeAll("}\n");

            return @intCast(fbs.getPos() catch 0);
        }
    };
}
