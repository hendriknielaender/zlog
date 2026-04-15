const std = @import("std");

const config = @import("config.zig");
const field = @import("field.zig");
const field_input = @import("field_input.zig");
const trace_mod = @import("trace.zig");
const otel = @import("otel.zig");
const escape = @import("string_escape.zig");
const redaction = @import("redaction.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const OutputWriter = @import("output_writer.zig").OutputWriter;

fn syncIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn OTelLogger(comptime otel_config: otel.OTelConfig) type {
    return OTelLoggerWithRedaction(otel_config, .{});
}

pub fn OTelLoggerWithRedaction(
    comptime otel_config: otel.OTelConfig,
    comptime redaction_options: redaction.RedactionOptions,
) type {
    const cfg = otel_config.base_config;

    comptime {
        std.debug.assert(cfg.max_fields > 0);
        std.debug.assert(cfg.buffer_size >= 256);
        std.debug.assert(cfg.buffer_size <= 65536);
    }

    return struct {
        const Self = @This();
        const max_fields = cfg.max_fields;
        const buffer_size = cfg.buffer_size;
        const async_mode = cfg.async_mode;
        const compile_time_redacted_fields = redaction_options.redacted_fields;

        const AsyncEntry = struct {
            bytes: [buffer_size]u8,
            len: u32,

            fn init() AsyncEntry {
                // SAFETY: `bytes` are written before `slice` exposes any of them, and `len` starts at 0.
                var entry: AsyncEntry = undefined;
                entry.len = 0;
                return entry;
            }

            fn slice(self: *const AsyncEntry) []const u8 {
                std.debug.assert(self.len <= buffer_size);
                return self.bytes[0..self.len];
            }
        };

        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,
        resource: otel.Resource,
        instrumentation_scope: otel.InstrumentationScope,
        mutex: if (async_mode) void else std.Io.Mutex = if (async_mode) {} else .init,
        output: if (async_mode) void else OutputWriter,
        async_logger: if (async_mode) ?*AsyncLogger else void = if (async_mode) null else {},
        managed_event_loop: if (async_mode) ?*EventLoop else void = if (async_mode) null else {},

        pub fn init(output_writer: *std.Io.Writer) Self {
            return initWithRedaction(output_writer, null);
        }

        pub fn initOwnedStderrWithRedaction(
            allocator: std.mem.Allocator,
            io: std.Io,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            if (async_mode) {
                @compileError("initOwnedStderrWithRedaction is only available for synchronous OTel loggers");
            }

            return .{
                .level = cfg.level,
                .redaction_config = redaction_cfg,
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
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
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
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
            );
        }

        pub fn initAsyncWithEventLoop(
            output_writer: *std.Io.Writer,
            event_loop: *EventLoop,
            allocator: std.mem.Allocator,
        ) !Self {
            return initAsyncWithIo(output_writer, event_loop.io(), allocator);
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
            );
        }

        pub fn initAsyncWithRedactionAndEventLoop(
            output_writer: *std.Io.Writer,
            event_loop: *EventLoop,
            allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
        ) !Self {
            return initAsyncWithRedactionAndIo(output_writer, event_loop.io(), allocator, redaction_cfg);
        }

        fn initAsyncWithOutput(
            output: OutputWriter,
            io: std.Io,
            allocator: std.mem.Allocator,
            redaction_cfg: ?*const redaction.RedactionConfig,
            managed_event_loop: ?*EventLoop,
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
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
                .output = if (async_mode) {} else unreachable,
                .async_logger = async_logger,
                .managed_event_loop = managed_event_loop,
            };
        }

        pub fn deinit(self: *Self) void {
            if (async_mode) {
                const managed_loop_allocator = if (self.async_logger) |async_logger|
                    async_logger.allocator
                else
                    null;

                if (self.async_logger) |async_logger| {
                    async_logger.destroy();
                    self.async_logger = null;
                }
                if (self.managed_event_loop) |managed_loop| {
                    managed_loop.deinit();
                    if (managed_loop_allocator) |allocator| allocator.destroy(managed_loop);
                    self.managed_event_loop = null;
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
            if (self.async_logger) |async_logger| async_logger.flushPending();
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
            self.logInternal(.trace, message, null, fields_struct);
        }

        pub fn debug(self: *Self, message: []const u8, fields_struct: anytype) void {
            self.logInternal(.debug, message, null, fields_struct);
        }

        pub fn info(self: *Self, message: []const u8, fields_struct: anytype) void {
            self.logInternal(.info, message, null, fields_struct);
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
            self.logInternal(.warn, message, null, fields_struct);
        }

        pub fn err(self: *Self, message: []const u8, fields_struct: anytype) void {
            self.logInternal(.err, message, null, fields_struct);
        }

        pub fn fatal(self: *Self, message: []const u8, fields_struct: anytype) void {
            self.logInternal(.fatal, message, null, fields_struct);
        }

        fn logInternal(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: ?trace_mod.TraceContext,
            fields_input: anytype,
        ) void {
            if (!cfg.enable_logging) return;
            if (@intFromEnum(level) < @intFromEnum(self.level)) return;

            const InputType = @TypeOf(fields_input);

            if (comptime field_input.isFieldArray(InputType)) {
                self.logWithTrace(
                    level,
                    message,
                    trace_ctx,
                    field_input.fieldSliceFromInput(fields_input),
                );
                return;
            }

            switch (@typeInfo(InputType)) {
                .@"struct" => {
                    const fields_array = field_input.structToFields(max_fields, fields_input);
                    self.logWithTrace(level, message, trace_ctx, &fields_array);
                    return;
                },
                .pointer => |pointer_info| {
                    if (pointer_info.size == .one) {
                        const pointed_info = @typeInfo(pointer_info.child);
                        if (pointed_info == .@"struct") {
                            const fields_array = field_input.structToFields(max_fields, fields_input);
                            self.logWithTrace(level, message, trace_ctx, &fields_array);
                            return;
                        }
                    }
                },
                else => {},
            }

            @compileError("Expected struct or field array, got " ++ @typeName(InputType));
        }

        fn logWithTrace(
            self: *Self,
            level: config.Level,
            message: []const u8,
            trace_ctx: ?trace_mod.TraceContext,
            attributes: []const field.Field,
        ) void {
            const log_record = otel.LogRecord.init(
                level,
                message,
                attributes,
                trace_ctx,
                self.resource,
                self.instrumentation_scope,
            );

            if (async_mode) {
                if (self.async_logger) |async_logger| {
                    const entry = self.formatLogEntry(log_record) catch return;
                    async_logger.enqueue(entry);
                }
                return;
            }

            self.formatAndWrite(log_record);
        }

        fn formatLogEntry(self: *Self, log_record: otel.LogRecord) !AsyncEntry {
            var entry = AsyncEntry.init();
            var writer: std.Io.Writer = .fixed(&entry.bytes);
            try self.writeRecord(&writer, log_record);
            const buffered = writer.buffered();
            std.debug.assert(buffered.len <= buffer_size);
            entry.len = @intCast(buffered.len);
            return entry;
        }

        fn formatAndWrite(self: *Self, log_record: otel.LogRecord) void {
            var buffer: [buffer_size]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            self.writeRecord(&writer, log_record) catch return;
            self.writeToOutput(writer.buffered());
        }

        fn writeToOutput(self: *Self, data: []const u8) void {
            self.mutex.lockUncancelable(syncIo());
            defer self.mutex.unlock(syncIo());
            self.output.writeAll(data) catch return;
            self.output.flush() catch return;
        }

        fn writeRecord(self: *Self, writer: *std.Io.Writer, log_record: otel.LogRecord) !void {
            if (otel_config.enable_otel_format) {
                try self.formatOTelJson(writer, log_record);
            } else {
                try self.formatCompatibleJson(writer, log_record);
            }
            try writer.writeAll("\n");
        }

        fn formatOTelJson(self: *Self, writer: *std.Io.Writer, log_record: otel.LogRecord) !void {
            try writer.writeAll("{");
            try writer.print("\"timeUnixNano\":\"{}\",", .{log_record.timestamp});
            try writer.print("\"observedTimeUnixNano\":\"{}\",", .{log_record.observed_timestamp});
            try writer.print("\"severityNumber\":{},", .{@intFromEnum(log_record.severity_number)});
            if (log_record.severity_text) |severity_text| {
                try writer.print("\"severityText\":\"{s}\",", .{severity_text});
            }
            try writer.writeAll("\"body\":{\"stringValue\":\"");
            if (log_record.body.asString()) |body_str| try escape.write(cfg, writer, body_str);
            try writer.writeAll("\"},");

            try writer.writeAll("\"attributes\":[");
            for (log_record.attributes, 0..) |attr, i| {
                if (i > 0) try writer.writeAll(",");
                try self.writeOtelAttribute(writer, attr);
            }
            try writer.writeAll("],");

            if (log_record.trace_id) |trace_id| {
                var trace_hex: [32]u8 = undefined;
                _ = try trace_mod.bytes_to_hex_lowercase(&trace_id, &trace_hex);
                try writer.print("\"traceId\":\"{s}\",", .{trace_hex});
            }
            if (log_record.span_id) |span_id| {
                var span_hex: [16]u8 = undefined;
                _ = try trace_mod.bytes_to_hex_lowercase(&span_id, &span_hex);
                try writer.print("\"spanId\":\"{s}\",", .{span_hex});
            }
            if (log_record.trace_flags) |flags| {
                try writer.print("\"flags\":{},", .{flags.toU8()});
            }

            try writer.writeAll("\"resource\":{\"attributes\":[");
            try self.writeResourceAttributes(writer, log_record.resource);
            try writer.writeAll("]},");

            try writer.writeAll("\"scope\":{\"name\":\"");
            try writer.writeAll(log_record.instrumentation_scope.name);
            try writer.writeAll("\"");
            if (log_record.instrumentation_scope.version) |version| {
                try writer.print(",\"version\":\"{s}\"", .{version});
            }
            try writer.writeAll("}}");
        }

        fn formatCompatibleJson(self: *Self, writer: *std.Io.Writer, log_record: otel.LogRecord) !void {
            try writer.writeAll("{\"level\":\"");
            try writer.writeAll(log_record.severity_text orelse "UNKNOWN");
            try writer.writeAll("\",\"msg\":\"");
            if (log_record.body.asString()) |body_str| try escape.write(cfg, writer, body_str);
            try writer.print(
                "\",\"ts\":{},\"tid\":{},\"severity_number\":{}",
                .{
                    log_record.timestamp / 1_000_000,
                    std.Thread.getCurrentId(),
                    @intFromEnum(log_record.severity_number),
                },
            );

            if (log_record.trace_id) |trace_id| {
                var trace_hex: [32]u8 = undefined;
                _ = try trace_mod.bytes_to_hex_lowercase(&trace_id, &trace_hex);
                try writer.print(",\"trace\":\"{s}\"", .{trace_hex});
            }
            if (log_record.span_id) |span_id| {
                var span_hex: [16]u8 = undefined;
                _ = try trace_mod.bytes_to_hex_lowercase(&span_id, &span_hex);
                try writer.print(",\"span\":\"{s}\"", .{span_hex});
            }

            try writer.print(",\"service.name\":\"{s}\"", .{log_record.resource.service_name});
            if (log_record.resource.service_version) |version| {
                try writer.print(",\"service.version\":\"{s}\"", .{version});
            }

            for (log_record.attributes) |attr| {
                try writer.writeAll(",\"");
                try escape.write(cfg, writer, attr.key);
                try writer.writeAll("\":");
                if (self.shouldRedact(attr.key)) {
                    try writer.writeAll("\"[REDACTED]\"");
                } else {
                    try self.writeCompatibleValue(writer, attr.value);
                }
            }

            try writer.writeAll("}");
        }

        fn writeCompatibleValue(self: *Self, writer: *std.Io.Writer, value: field.Field.Value) !void {
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

        fn writeOtelAttribute(self: *Self, writer: *std.Io.Writer, attr: field.Field) !void {
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
                    .int => |i| try writer.print("{{\"intValue\":\"{}\"}}", .{i}),
                    .uint => |u| try writer.print("{{\"intValue\":\"{}\"}}", .{u}),
                    .float => |f| try writer.print("{{\"doubleValue\":{d:.5}}}", .{f}),
                    .boolean => |b| try writer.print("{{\"boolValue\":{}}}", .{b}),
                    .null => try writer.writeAll("{\"stringValue\":null}"),
                    .redacted => try writer.writeAll("{\"stringValue\":\"[REDACTED]\"}"),
                }
            }

            try writer.writeAll("}");
        }

        fn writeResourceAttributes(self: *Self, writer: *std.Io.Writer, resource: otel.Resource) !void {
            _ = self;
            try writer.writeAll("{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
            try writer.writeAll(resource.service_name);
            try writer.writeAll("\"}}");

            if (resource.service_version) |version| {
                try writer.writeAll(",");
                try writer.writeAll("{\"key\":\"service.version\",\"value\":{\"stringValue\":\"");
                try writer.writeAll(version);
                try writer.writeAll("\"}}");
            }
        }

        const AsyncQueue = struct {
            allocator: std.mem.Allocator,
            entries: []AsyncEntry,
            read_index: u32 = 0,
            write_index: u32 = 0,
            len: u32 = 0,
            mutex: std.Io.Mutex = .init,
            condition: std.Io.Condition = .init,

            fn init(allocator: std.mem.Allocator, capacity: u32) !AsyncQueue {
                std.debug.assert(capacity > 0);
                return .{
                    .allocator = allocator,
                    .entries = try allocator.alloc(AsyncEntry, @intCast(capacity)),
                };
            }

            fn deinit(self: *AsyncQueue) void {
                std.debug.assert(self.len <= self.entries.len);
                self.allocator.free(self.entries);
                self.* = undefined;
            }

            fn push(self: *AsyncQueue, io: std.Io, entry: AsyncEntry) bool {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                if (self.len == self.entries.len) return false;
                const write_index: usize = @intCast(self.write_index);
                self.entries[write_index] = entry;
                self.write_index = ringAdvance(self.write_index, @intCast(self.entries.len));
                self.len += 1;
                self.condition.signal(io);
                return true;
            }

            fn popBatch(self: *AsyncQueue, io: std.Io, batch: []AsyncEntry) u32 {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                const batch_len: u32 = @intCast(batch.len);
                const count = @min(self.len, batch_len);
                const count_usize: usize = @intCast(count);

                for (0..count_usize) |i| {
                    const read_index: usize = @intCast(self.read_index);
                    batch[i] = self.entries[read_index];
                    self.read_index = ringAdvance(self.read_index, @intCast(self.entries.len));
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
            ) ?u32 {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                while (self.len == 0 and !should_stop.load(.acquire)) {
                    self.condition.waitUncancelable(io, &self.mutex);
                }
                if (self.len == 0 and should_stop.load(.acquire)) return null;
                const batch_len: u32 = @intCast(batch.len);
                const count = @min(self.len, batch_len);
                const count_usize: usize = @intCast(count);

                for (0..count_usize) |i| {
                    const read_index: usize = @intCast(self.read_index);
                    batch[i] = self.entries[read_index];
                    self.read_index = ringAdvance(self.read_index, @intCast(self.entries.len));
                }
                self.len -= count;
                self.condition.broadcast(io);
                return count;
            }

            fn waitUntilEmpty(self: *AsyncQueue, io: std.Io) void {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                while (self.len != 0) self.condition.waitUncancelable(io, &self.mutex);
            }

            fn wakeAll(self: *AsyncQueue, io: std.Io) void {
                self.condition.broadcast(io);
            }

            fn size(self: *AsyncQueue, io: std.Io) u32 {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                return self.len;
            }

            fn ringAdvance(index: u32, capacity: u32) u32 {
                std.debug.assert(capacity > 0);
                std.debug.assert(index < capacity);

                const next = index + 1;
                return if (next == capacity) 0 else next;
            }
        };

        const AsyncLogger = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            output: OutputWriter,
            queue: AsyncQueue,
            batch: []AsyncEntry,
            should_stop: std.atomic.Value(bool) = .init(false),
            drain_mutex: std.Io.Mutex = .init,
            drain_condition: std.Io.Condition = .init,
            write_in_progress: u32 = 0,
            worker_future: std.Io.Future(std.Io.Cancelable!void),

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

                const batch_len = @max(@as(u32, 1), @min(queue_size, batch_size));
                const batch = try allocator.alloc(AsyncEntry, @intCast(batch_len));
                errdefer allocator.free(batch);

                self.* = .{
                    .allocator = allocator,
                    .io = io,
                    .output = output,
                    .queue = queue,
                    .batch = batch,
                    // SAFETY: `worker_future` is assigned immediately after `self.*` initialization and before any read.
                    .worker_future = undefined,
                };

                self.worker_future = try io.concurrent(workerMain, .{self});
                return self;
            }

            fn destroy(self: *AsyncLogger) void {
                self.should_stop.store(true, .release);
                self.queue.wakeAll(self.io);
                _ = self.worker_future.await(self.io) catch |shutdown_err| {
                    std.debug.panic("otel logger worker shutdown failed: {}", .{shutdown_err});
                };
                self.flushPending();
                self.output.deinit();
                self.queue.deinit();
                self.allocator.free(self.batch);
                const allocator = self.allocator;
                allocator.destroy(self);
            }

            fn enqueue(self: *AsyncLogger, entry: AsyncEntry) void {
                if (!self.queue.push(self.io, entry)) {}
            }

            fn flushPending(self: *AsyncLogger) void {
                while (true) {
                    const count = self.queue.popBatch(self.io, self.batch);
                    if (count == 0) break;
                    self.writeBatchTracked(self.batch[0..count]);
                }
            }

            fn waitUntilDrained(self: *AsyncLogger) void {
                while (true) {
                    self.queue.waitUntilEmpty(self.io);
                    self.waitUntilIdle();
                    if (self.queue.size(self.io) == 0) break;
                }
            }

            fn writeBatch(self: *AsyncLogger, entries: []AsyncEntry) void {
                for (entries) |entry| {
                    self.output.writeAll(entry.slice()) catch return;
                }
                self.output.flush() catch return;
            }

            fn workerMain(self: *AsyncLogger) std.Io.Cancelable!void {
                while (true) {
                    const count = self.queue.popBatchBlocking(self.io, &self.should_stop, self.batch) orelse break;
                    if (count != 0) self.writeBatchTracked(self.batch[0..count]);
                }
            }

            fn writeBatchTracked(self: *AsyncLogger, entries: []AsyncEntry) void {
                self.beginWrite();
                defer self.endWrite();
                self.writeBatch(entries);
            }

            fn beginWrite(self: *AsyncLogger) void {
                self.drain_mutex.lockUncancelable(self.io);
                defer self.drain_mutex.unlock(self.io);
                self.write_in_progress += 1;
            }

            fn endWrite(self: *AsyncLogger) void {
                self.drain_mutex.lockUncancelable(self.io);
                defer self.drain_mutex.unlock(self.io);
                std.debug.assert(self.write_in_progress > 0);
                self.write_in_progress -= 1;
                if (self.write_in_progress == 0) self.drain_condition.broadcast(self.io);
            }

            fn waitUntilIdle(self: *AsyncLogger) void {
                self.drain_mutex.lockUncancelable(self.io);
                defer self.drain_mutex.unlock(self.io);
                while (self.write_in_progress != 0) {
                    self.drain_condition.waitUncancelable(self.io, &self.drain_mutex);
                }
            }
        };
    };
}

const testing = std.testing;

test "otel logger writes compatible json" {
    var sink_buffer: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    const otel_config = comptime otel.OTelConfig{
        .resource = otel.Resource.init().withService("test-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("test-scope"),
    };

    var logger = OTelLogger(otel_config).init(&sink);
    defer logger.deinit();

    logger.info("Test message", .{ .key = "value" });

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "Test message") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test-service") != null);
}

test "otel async logger flushes output" {
    var sink_buffer: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);

    const otel_config = comptime otel.OTelConfig{
        .base_config = .{ .async_mode = true },
        .resource = otel.Resource.init().withService("async-service", "1.0.0"),
        .instrumentation_scope = otel.InstrumentationScope.init("async-scope"),
    };

    var logger = try OTelLogger(otel_config).initAsync(&sink, testing.allocator);
    defer logger.deinit();

    logger.info("async message", .{ .environment = "test" });
    try logger.runEventLoopUntilDone();

    const output = sink.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "async message") != null);
    try testing.expect(std.mem.indexOf(u8, output, "async-service") != null);
}
