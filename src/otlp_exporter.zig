const std = @import("std");
const assert = std.debug.assert;
const log_config = @import("config.zig");
const otel = @import("otel.zig");
const field = @import("field.zig");
const escape = @import("string_escape.zig");

/// OTLP Logs exporter state without internal allocation.
/// The caller owns transport and any buffers needed around this serializer.
pub const OTLPExporter = struct {
    endpoint: []const u8,
    headers: []Header,
    headers_len: u32 = 0,
    timeout_ms: u32,
    compression: Compression,

    pub const Header = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const Compression = enum {
        none,
        gzip,
    };

    pub fn init(endpoint: []const u8, header_storage: []Header) OTLPExporter {
        assert(endpoint.len > 0);
        assert(header_storage.len <= std.math.maxInt(u32));

        return OTLPExporter{
            .endpoint = endpoint,
            .headers = header_storage,
            .timeout_ms = 10000,
            .compression = .none,
        };
    }

    pub fn deinit(self: *OTLPExporter) void {
        self.headers_len = 0;
    }

    pub fn setHeader(self: *OTLPExporter, key: []const u8, value: []const u8) !void {
        assert(key.len > 0);
        assert(value.len > 0);

        if (self.findHeaderIndex(key)) |header_index| {
            self.headers[header_index].value = value;
            return;
        }

        if (self.headers_len == self.headers.len) {
            return error.OutOfCapacity;
        }

        const write_index: usize = @intCast(self.headers_len);
        assert(write_index < self.headers.len);

        self.headers[write_index] = .{
            .key = key,
            .value = value,
        };
        self.headers_len += 1;
    }

    pub fn setApiKey(self: *OTLPExporter, api_key: []const u8) !void {
        try self.setHeader("Authorization", api_key);
    }

    pub fn setTimeout(self: *OTLPExporter, timeout_ms: u32) void {
        assert(timeout_ms > 0);
        self.timeout_ms = timeout_ms;
    }

    pub fn setCompression(self: *OTLPExporter, compression: Compression) void {
        self.compression = compression;
    }

    pub fn headerSlice(self: *const OTLPExporter) []const Header {
        const configured_headers_len: usize = @intCast(self.headers_len);
        assert(configured_headers_len <= self.headers.len);
        return self.headers[0..configured_headers_len];
    }

    /// Serialize a batch of log records to OTLP JSON and write the payload to the target writer.
    pub fn exportLogs(
        self: *const OTLPExporter,
        writer: *std.Io.Writer,
        log_records: []const otel.LogRecord,
    ) !void {
        try self.serializeLogsToOTLP(log_records, writer);
    }

    /// Serialize a single log record to OTLP JSON and write the payload to the target writer.
    pub fn exportLog(
        self: *const OTLPExporter,
        writer: *std.Io.Writer,
        log_record: otel.LogRecord,
    ) !void {
        const records = [_]otel.LogRecord{log_record};
        try self.exportLogs(writer, &records);
    }

    fn findHeaderIndex(self: *const OTLPExporter, key: []const u8) ?usize {
        const configured_headers_len: usize = @intCast(self.headers_len);
        assert(configured_headers_len <= self.headers.len);

        for (self.headers[0..configured_headers_len], 0..) |header, index| {
            if (std.mem.eql(u8, header.key, key)) {
                return index;
            }
        }

        return null;
    }

    fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
        try writer.writeByte('"');
        try escape.write(log_config.Config{}, writer, value);
        try writer.writeByte('"');
    }

    fn serializeLogsToOTLP(
        self: *const OTLPExporter,
        log_records: []const otel.LogRecord,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{\"resourceLogs\":[");

        var group_start: usize = 0;
        var first_group = true;
        while (group_start < log_records.len) {
            const group_record = log_records[group_start];
            var group_end = group_start + 1;
            while (group_end < log_records.len and
                resourceScopeMatches(log_records[group_end], group_record))
            {
                group_end += 1;
            }

            if (!first_group) {
                try writer.writeAll(",");
            }
            first_group = false;

            try writer.writeAll("{\"resource\":");
            try self.serializeResource(group_record.resource, writer);
            try writer.writeAll(",\"scopeLogs\":[{\"scope\":");
            try self.serializeInstrumentationScope(group_record.instrumentation_scope, writer);
            try writer.writeAll(",\"logRecords\":[");

            for (log_records[group_start..group_end], 0..) |log_record, index| {
                if (index > 0) {
                    try writer.writeAll(",");
                }
                try self.serializeLogRecord(log_record, writer);
            }

            try writer.writeAll("]}]}");
            group_start = group_end;
        }

        try writer.writeAll("]}");
    }

    fn resourceScopeMatches(left: otel.LogRecord, right: otel.LogRecord) bool {
        return resourceMatches(left.resource, right.resource) and
            scopeMatches(left.instrumentation_scope, right.instrumentation_scope);
    }

    fn resourceMatches(left: otel.Resource, right: otel.Resource) bool {
        if (!std.mem.eql(u8, left.service_name, right.service_name)) return false;
        if (!optionalStringMatches(left.service_version, right.service_version)) return false;
        if (!optionalStringMatches(left.service_namespace, right.service_namespace)) return false;
        if (!optionalStringMatches(left.service_instance_id, right.service_instance_id)) return false;
        if (left.process_pid != right.process_pid) return false;
        if (!optionalStringMatches(
            left.process_executable_name,
            right.process_executable_name,
        )) return false;
        if (!optionalStringMatches(
            left.process_executable_path,
            right.process_executable_path,
        )) return false;
        if (!optionalStringMatches(left.process_command_line, right.process_command_line)) return false;
        if (!optionalStringMatches(left.process_runtime_name, right.process_runtime_name)) return false;
        if (!optionalStringMatches(
            left.process_runtime_version,
            right.process_runtime_version,
        )) return false;
        if (!optionalStringMatches(left.host_name, right.host_name)) return false;
        if (!optionalStringMatches(left.host_id, right.host_id)) return false;
        if (!optionalStringMatches(left.host_type, right.host_type)) return false;
        if (!optionalStringMatches(left.host_arch, right.host_arch)) return false;
        if (!optionalStringMatches(left.os_type, right.os_type)) return false;
        if (!optionalStringMatches(left.os_description, right.os_description)) return false;
        if (!optionalStringMatches(left.os_name, right.os_name)) return false;
        if (!optionalStringMatches(left.os_version, right.os_version)) return false;
        return true;
    }

    fn scopeMatches(left: otel.InstrumentationScope, right: otel.InstrumentationScope) bool {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (!optionalStringMatches(left.version, right.version)) return false;
        if (!optionalStringMatches(left.schema_url, right.schema_url)) return false;
        return true;
    }

    fn optionalStringMatches(left: ?[]const u8, right: ?[]const u8) bool {
        if (left) |left_value| {
            if (right) |right_value| {
                return std.mem.eql(u8, left_value, right_value);
            }
            return false;
        }

        return right == null;
    }

    fn serializeResource(
        self: *const OTLPExporter,
        resource: otel.Resource,
        writer: *std.Io.Writer,
    ) !void {
        _ = self;
        assert(resource.service_name.len > 0);

        try writer.writeAll("{\"attributes\":[");

        var first_attribute = true;
        try writeResourceStringAttribute(
            writer,
            "service.name",
            resource.service_name,
            &first_attribute,
        );

        if (resource.service_version) |version| {
            try writeResourceStringAttribute(writer, "service.version", version, &first_attribute);
        }
        if (resource.service_namespace) |namespace| {
            try writeResourceStringAttribute(
                writer,
                "service.namespace",
                namespace,
                &first_attribute,
            );
        }
        if (resource.process_pid) |pid| {
            try writeResourceIntAttribute(writer, "process.pid", pid, &first_attribute);
        }
        if (resource.process_executable_name) |name| {
            try writeResourceStringAttribute(
                writer,
                "process.executable.name",
                name,
                &first_attribute,
            );
        }
        if (resource.host_name) |name| {
            try writeResourceStringAttribute(writer, "host.name", name, &first_attribute);
        }
        if (resource.host_arch) |arch| {
            try writeResourceStringAttribute(writer, "host.arch", arch, &first_attribute);
        }
        if (resource.os_type) |os_type| {
            try writeResourceStringAttribute(writer, "os.type", os_type, &first_attribute);
        }
        if (resource.os_description) |description| {
            try writeResourceStringAttribute(
                writer,
                "os.description",
                description,
                &first_attribute,
            );
        }

        try writer.writeAll("]}");
    }

    fn writeResourceAttributeSeparator(
        writer: *std.Io.Writer,
        first_attribute: *bool,
    ) !void {
        if (first_attribute.*) {
            first_attribute.* = false;
            return;
        }

        try writer.writeAll(",");
    }

    fn writeResourceStringAttribute(
        writer: *std.Io.Writer,
        key: []const u8,
        value: []const u8,
        first_attribute: *bool,
    ) !void {
        assert(key.len > 0);
        assert(value.len > 0);

        try writeResourceAttributeSeparator(writer, first_attribute);
        try writer.writeAll("{\"key\":");
        try writeJsonString(writer, key);
        try writer.writeAll(",\"value\":{\"stringValue\":");
        try writeJsonString(writer, value);
        try writer.writeAll("}}");
    }

    fn writeResourceIntAttribute(
        writer: *std.Io.Writer,
        key: []const u8,
        value: u32,
        first_attribute: *bool,
    ) !void {
        assert(key.len > 0);

        try writeResourceAttributeSeparator(writer, first_attribute);
        try writer.writeAll("{\"key\":");
        try writeJsonString(writer, key);
        try writer.writeAll(",\"value\":{\"intValue\":\"");
        try writer.print("{}", .{value});
        try writer.writeAll("\"}}");
    }

    fn serializeInstrumentationScope(
        self: *const OTLPExporter,
        scope: otel.InstrumentationScope,
        writer: *std.Io.Writer,
    ) !void {
        _ = self;
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, scope.name);

        if (scope.version) |version| {
            try writer.writeAll(",\"version\":");
            try writeJsonString(writer, version);
        }
        if (scope.schema_url) |schema_url| {
            try writer.writeAll(",\"schemaUrl\":");
            try writeJsonString(writer, schema_url);
        }

        try writer.writeAll("}");
    }

    fn serializeLogRecord(
        self: *const OTLPExporter,
        log_record: otel.LogRecord,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll("{");
        try writer.print("\"timeUnixNano\":\"{}\",", .{log_record.timestamp});
        try writer.print("\"observedTimeUnixNano\":\"{}\",", .{log_record.observed_timestamp});
        try writer.print("\"severityNumber\":{},", .{@intFromEnum(log_record.severity_number)});

        if (log_record.severity_text) |severity_text| {
            try writer.writeAll("\"severityText\":");
            try writeJsonString(writer, severity_text);
            try writer.writeAll(",");
        }

        try writer.writeAll("\"body\":");
        try self.serializeLogBody(log_record.body, writer);
        try writer.writeAll(",");

        try writer.writeAll("\"attributes\":[");
        var dropped_attributes_count: u32 = 0;
        var first_attribute = true;
        for (log_record.attributes) |attr| {
            if (attr.value == .null) {
                dropped_attributes_count += 1;
                continue;
            }

            if (!first_attribute) {
                try writer.writeAll(",");
            }
            first_attribute = false;
            try self.serializeAttribute(attr, writer);
        }
        try writer.writeAll("],");

        if (log_record.trace_id) |trace_id| {
            var trace_hex: [32]u8 = undefined;
            _ = std.fmt.bufPrint(
                &trace_hex,
                "{}",
                .{std.fmt.fmtSliceHexLower(&trace_id)},
            ) catch return;
            try writer.print("\"traceId\":\"{s}\",", .{trace_hex});
        }
        if (log_record.span_id) |span_id| {
            var span_hex: [16]u8 = undefined;
            _ = std.fmt.bufPrint(
                &span_hex,
                "{}",
                .{std.fmt.fmtSliceHexLower(&span_id)},
            ) catch return;
            try writer.print("\"spanId\":\"{s}\",", .{span_hex});
        }
        if (log_record.trace_flags) |flags| {
            try writer.print("\"flags\":{}", .{flags.toU8()});
            if (dropped_attributes_count > 0) {
                try writer.writeAll(",");
            }
        }

        if (dropped_attributes_count > 0) {
            try writer.print("\"droppedAttributesCount\":{}", .{dropped_attributes_count});
        } else {
            if (log_record.trace_flags == null) {
                try writer.writeAll("\"droppedAttributesCount\":0");
            }
        }

        try writer.writeAll("}");
    }

    fn serializeLogBody(
        self: *const OTLPExporter,
        body: otel.LogBody,
        writer: *std.Io.Writer,
    ) !void {
        switch (body) {
            .string_value => |string_value| {
                try writer.writeAll("{\"stringValue\":");
                try writeJsonString(writer, string_value);
                try writer.writeAll("}");
            },
            .int_value => |int_value| {
                try writer.writeAll("{\"intValue\":\"");
                try writer.print("{}", .{int_value});
                try writer.writeAll("\"}");
            },
            .double_value => |double_value| {
                try writer.writeAll("{\"doubleValue\":");
                try writer.print("{d}", .{double_value});
                try writer.writeAll("}");
            },
            .bool_value => |bool_value| {
                try writer.writeAll("{\"boolValue\":");
                try writer.print("{}", .{bool_value});
                try writer.writeAll("}");
            },
            .bytes_value => |bytes_value| {
                try writer.writeAll("{\"bytesValue\":");
                try writer.writeByte('"');
                try std.base64.standard.Encoder.encodeWriter(writer, bytes_value);
                try writer.writeByte('"');
                try writer.writeAll("}");
            },
            .array_value => |array_value| {
                try writer.writeAll("{\"arrayValue\":{\"values\":[");
                for (array_value, 0..) |item, index| {
                    if (index > 0) {
                        try writer.writeAll(",");
                    }
                    try self.serializeLogBody(item, writer);
                }
                try writer.writeAll("]}}");
            },
            .kvlist_value => |kvlist_value| {
                try writer.writeAll("{\"kvlistValue\":{\"values\":[");
                for (kvlist_value, 0..) |kv_item, index| {
                    if (index > 0) {
                        try writer.writeAll(",");
                    }
                    try self.serializeAttribute(kv_item, writer);
                }
                try writer.writeAll("]}}");
            },
        }
    }

    fn serializeAttribute(
        self: *const OTLPExporter,
        attr: field.Field,
        writer: *std.Io.Writer,
    ) !void {
        _ = self;
        assert(attr.value != .null);

        try writer.writeAll("{\"key\":");
        try writeJsonString(writer, attr.key);
        try writer.writeAll(",\"value\":");

        switch (attr.value) {
            .string => |string_value| {
                try writer.writeAll("{\"stringValue\":");
                try writeJsonString(writer, string_value);
                try writer.writeAll("}");
            },
            .int => |int_value| {
                try writer.writeAll("{\"intValue\":\"");
                try writer.print("{}", .{int_value});
                try writer.writeAll("\"}");
            },
            .uint => |uint_value| {
                try writer.writeAll("{\"intValue\":\"");
                try writer.print("{}", .{uint_value});
                try writer.writeAll("\"}");
            },
            .float => |float_value| {
                try writer.writeAll("{\"doubleValue\":");
                try writer.print("{d}", .{float_value});
                try writer.writeAll("}");
            },
            .boolean => |bool_value| {
                try writer.writeAll("{\"boolValue\":");
                try writer.print("{}", .{bool_value});
                try writer.writeAll("}");
            },
            .null => unreachable,
            .redacted => try writer.writeAll("{\"stringValue\":\"[REDACTED]\"}"),
        }

        try writer.writeAll("}");
    }
};

pub fn createExporter(
    header_storage: []OTLPExporter.Header,
    backend: Backend,
    config: ExporterConfig,
) !OTLPExporter {
    const endpoint = switch (backend) {
        .jaeger => config.endpoint orelse "http://localhost:14268/api/traces",
        .otlp_http => config.endpoint orelse "http://localhost:4318/v1/logs",
        .otlp_grpc => config.endpoint orelse "http://localhost:4317/v1/logs",
        .custom => config.endpoint orelse return error.MissingEndpoint,
    };

    var exporter = OTLPExporter.init(endpoint, header_storage);

    if (config.api_key) |api_key| {
        try exporter.setApiKey(api_key);
    }
    if (config.timeout_ms) |timeout_ms| {
        exporter.setTimeout(timeout_ms);
    }
    if (config.compression) |compression| {
        exporter.setCompression(compression);
    }

    return exporter;
}

pub const Backend = enum {
    jaeger,
    otlp_http,
    otlp_grpc,
    custom,
};

pub const ExporterConfig = struct {
    endpoint: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    compression: ?OTLPExporter.Compression = null,
};

const testing = std.testing;

test "OTLP exporter creation" {
    var header_storage: [4]OTLPExporter.Header = undefined;
    var exporter = OTLPExporter.init("http://localhost:4318/v1/logs", &header_storage);
    defer exporter.deinit();

    try exporter.setApiKey("Bearer test-key");
    try exporter.setHeader("X-Custom-Header", "test-value");
    exporter.setTimeout(5000);
    exporter.setCompression(.gzip);

    try testing.expect(exporter.headerSlice().len == 2);
}

test "OTLP log serialization" {
    var header_storage: [4]OTLPExporter.Header = undefined;
    var exporter = OTLPExporter.init("http://localhost:4318/v1/logs", &header_storage);
    defer exporter.deinit();

    const resource = otel.Resource.init().withService("test-service", "1.0.0");
    const scope = otel.InstrumentationScope.init("test-logger");

    const attributes = [_]field.Field{
        field.Field.string("environment", "test"),
        field.Field.int("user_id", 12345),
    };

    const log_record = otel.LogRecord.init(
        .info,
        "Test log message",
        &attributes,
        null,
        resource,
        scope,
    );

    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    try exporter.exportLogs(&writer, &[_]otel.LogRecord{log_record});

    const json = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "resourceLogs"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "scopeLogs"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "logRecords"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "test-service"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "Test log message"));
}

test "OTLP exporter groups records by resource and scope" {
    var header_storage: [4]OTLPExporter.Header = undefined;
    var exporter = OTLPExporter.init("http://localhost:4318/v1/logs", &header_storage);
    defer exporter.deinit();

    const resource_a = otel.Resource.init().withService("service-a", "1.0.0");
    const resource_b = otel.Resource.init().withService("service-b", "1.0.0");
    const scope_a = otel.InstrumentationScope.init("scope-a");
    const scope_b = otel.InstrumentationScope.init("scope-b");

    const log_record_a = otel.LogRecord.init(.info, "first", &.{}, null, resource_a, scope_a);
    const log_record_b = otel.LogRecord.init(.info, "second", &.{}, null, resource_b, scope_b);

    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    try exporter.exportLogs(&writer, &[_]otel.LogRecord{ log_record_a, log_record_b });

    const json = writer.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"service-a\""));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"service-b\""));
    try testing.expect(std.mem.containsAtLeast(u8, json, 2, "\"resource\":"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"scope-a\""));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"scope-b\""));
}

test "OTLP exporter drops null attributes instead of emitting invalid values" {
    var header_storage: [4]OTLPExporter.Header = undefined;
    var exporter = OTLPExporter.init("http://localhost:4318/v1/logs", &header_storage);
    defer exporter.deinit();

    const resource = otel.Resource.init().withService("null-test", "1.0.0");
    const scope = otel.InstrumentationScope.init("null-scope");
    const attributes = [_]field.Field{
        field.Field.string("visible", "value"),
        field.Field.null_value("optional"),
    };

    const log_record = otel.LogRecord.init(.info, "null attr", &attributes, null, resource, scope);

    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    try exporter.exportLog(&writer, log_record);

    const json = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, json, "\"optional\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"stringValue\":null") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"droppedAttributesCount\":1") != null);
}

test "Backend exporter creation" {
    var header_storage: [4]OTLPExporter.Header = undefined;

    const config = ExporterConfig{
        .api_key = "test-key",
        .timeout_ms = 5000,
        .compression = .gzip,
    };

    var exporter = try createExporter(&header_storage, .otlp_http, config);
    defer exporter.deinit();

    try testing.expect(exporter.headerSlice().len == 1);
}
