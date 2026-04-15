const std = @import("std");

const config = @import("config.zig");
const field = @import("field.zig");
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
            bytes: []u8,
            level: config.Level,
        };

        level: config.Level,
        redaction_config: ?*const redaction.RedactionConfig,
        resource: otel.Resource,
        instrumentation_scope: otel.InstrumentationScope,
        mutex: if (async_mode) void else std.Io.Mutex = if (async_mode) {} else .init,
        output: if (async_mode) void else OutputWriter,
        allocator: if (async_mode) std.mem.Allocator else void = if (async_mode) undefined else {},
        async_logger: if (async_mode) ?*AsyncLogger else void = if (async_mode) null else {},
        managed_event_loop: if (async_mode) ?*EventLoop else void = if (async_mode) null else {},
        managed_event_loop_allocator: if (async_mode) ?std.mem.Allocator else void = if (async_mode) null else {},

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
            return initAsyncWithRedactionAndIo(output_writer, event_loop.io(), allocator, redaction_cfg);
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
                .resource = otel_config.resource,
                .instrumentation_scope = otel_config.instrumentation_scope,
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
                    if (self.managed_event_loop_allocator) |allocator| allocator.destroy(managed_loop);
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
                    const bytes = self.formatLogAlloc(log_record) catch return;
                    async_logger.enqueue(bytes, level);
                }
                return;
            }

            self.formatAndWrite(log_record);
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

        fn formatLogAlloc(self: *Self, log_record: otel.LogRecord) ![]u8 {
            var buffer: [buffer_size]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try self.writeRecord(&writer, log_record);
            return try self.allocator.dupe(u8, writer.buffered());
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
                while (self.len != 0) self.condition.waitUncancelable(io, &self.mutex);
            }

            fn wakeAll(self: *AsyncQueue, io: std.Io) void {
                self.condition.broadcast(io);
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

                for (entries) |entry| self.allocator.free(entry.bytes);
            }

            fn workerMain(self: *AsyncLogger) std.Io.Cancelable!void {
                while (true) {
                    const count = self.queue.popBatchBlocking(self.io, &self.should_stop, self.batch) orelse break;
                    if (count != 0) self.writeBatch(self.batch[0..count]);
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
