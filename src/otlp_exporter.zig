const std = @import("std");
const assert = std.debug.assert;
const otel = @import("otel.zig");
const field = @import("field.zig");

/// OTLP Logs Exporter for sending logs directly to OpenTelemetry backends
/// Implements the OTLP/HTTP protocol as specified in:
/// https://opentelemetry.io/docs/specs/otlp/
pub const OTLPExporter = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    headers: std.StringHashMap([]const u8),
    timeout_ms: u32,
    compression: Compression,

    pub const Compression = enum {
        none,
        gzip,
    };

    pub const ExportError = error{
        NetworkError,
        SerializationError,
        AuthenticationError,
        RateLimited,
        ServerError,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) OTLPExporter {
        return OTLPExporter{
            .allocator = allocator,
            .endpoint = endpoint,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .timeout_ms = 10000, // 10 seconds default
            .compression = .none,
        };
    }

    pub fn deinit(self: *OTLPExporter) void {
        self.headers.deinit();
    }

    pub fn setHeader(self: *OTLPExporter, key: []const u8, value: []const u8) !void {
        try self.headers.put(key, value);
    }

    pub fn setApiKey(self: *OTLPExporter, api_key: []const u8) !void {
        try self.setHeader("Authorization", api_key);
    }

    pub fn setTimeout(self: *OTLPExporter, timeout_ms: u32) void {
        self.timeout_ms = timeout_ms;
    }

    pub fn setCompression(self: *OTLPExporter, compression: Compression) void {
        self.compression = compression;
    }

    /// Export a batch of log records to the OTLP endpoint
    pub fn exportLogs(self: *OTLPExporter, log_records: []const otel.LogRecord) ExportError!void {
        // Serialize to OTLP JSON format
        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();

        try self.serializeLogsToOTLP(log_records, &json_buffer);

        // Send HTTP request
        try self.sendHttpRequest(json_buffer.items);
    }

    /// Export a single log record
    pub fn exportLog(self: *OTLPExporter, log_record: otel.LogRecord) ExportError!void {
        const records = [_]otel.LogRecord{log_record};
        try self.exportLogs(&records);
    }

    fn serializeLogsToOTLP(self: *OTLPExporter, log_records: []const otel.LogRecord, buffer: *std.ArrayList(u8)) !void {
        const writer = buffer.writer();

        try writer.writeAll("{\"resourceLogs\":[");

        // Group logs by resource (simplified - assumes all logs have same resource)
        if (log_records.len > 0) {
            try writer.writeAll("{\"resource\":");
            try self.serializeResource(log_records[0].resource, writer);

            try writer.writeAll(",\"scopeLogs\":[");

            // Group by instrumentation scope (simplified)
            try writer.writeAll("{\"scope\":");
            try self.serializeInstrumentationScope(log_records[0].instrumentation_scope, writer);

            try writer.writeAll(",\"logRecords\":[");

            for (log_records, 0..) |log_record, i| {
                if (i > 0) try writer.writeAll(",");
                try self.serializeLogRecord(log_record, writer);
            }

            try writer.writeAll("]}"); // Close scopeLogs
            try writer.writeAll("]}"); // Close resourceLogs
        }

        try writer.writeAll("]}"); // Close root
    }

    fn serializeResource(self: *OTLPExporter, resource: otel.Resource, writer: anytype) !void {
        _ = self;
        try writer.writeAll("{\"attributes\":[");

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

        if (resource.service_namespace) |namespace| {
            try writer.writeAll(",");
            try writer.writeAll("{\"key\":\"service.namespace\",\"value\":{\"stringValue\":\"");
            try writer.writeAll(namespace);
            try writer.writeAll("\"}}");
        }

        // Process attributes
        if (resource.process_pid) |pid| {
            try writer.writeAll(",");
            try writer.writeAll("{\"key\":\"process.pid\",\"value\":{\"intValue\":\"");
            try writer.print("{}", .{pid});
            try writer.writeAll("\"}}");
        }

        if (resource.process_executable_name) |name| {
            try writer.writeAll(",");
            try writer.writeAll("{\"key\":\"process.executable.name\",\"value\":{\"stringValue\":\"");
            try writer.writeAll(name);
            try writer.writeAll("\"}}");
        }

        // Host attributes
        if (resource.host_name) |name| {
            try writer.writeAll(",");
            try writer.writeAll("{\"key\":\"host.name\",\"value\":{\"stringValue\":\"");
            try writer.writeAll(name);
            try writer.writeAll("\"}}");
        }

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

        if (resource.os_description) |description| {
            try writer.writeAll(",");
            try writer.writeAll("{\"key\":\"os.description\",\"value\":{\"stringValue\":\"");
            try writer.writeAll(description);
            try writer.writeAll("\"}}");
        }

        try writer.writeAll("]}");
    }

    fn serializeInstrumentationScope(self: *OTLPExporter, scope: otel.InstrumentationScope, writer: anytype) !void {
        _ = self;
        try writer.writeAll("{\"name\":\"");
        try writer.writeAll(scope.name);
        try writer.writeAll("\"");

        if (scope.version) |version| {
            try writer.print(",\"version\":\"{s}\"", .{version});
        }

        if (scope.schema_url) |schema_url| {
            try writer.print(",\"schemaUrl\":\"{s}\"", .{schema_url});
        }

        try writer.writeAll("}");
    }

    fn serializeLogRecord(self: *OTLPExporter, log_record: otel.LogRecord, writer: anytype) !void {
        try writer.writeAll("{");

        // Timestamp
        try writer.print("\"timeUnixNano\":\"{}\",", .{log_record.timestamp});
        try writer.print("\"observedTimeUnixNano\":\"{}\",", .{log_record.observed_timestamp});

        // Severity
        try writer.print("\"severityNumber\":{},", .{@intFromEnum(log_record.severity_number)});
        if (log_record.severity_text) |severity_text| {
            try writer.print("\"severityText\":\"{s}\",", .{severity_text});
        }

        // Body
        try writer.writeAll("\"body\":");
        try self.serializeLogBody(log_record.body, writer);
        try writer.writeAll(",");

        // Attributes
        try writer.writeAll("\"attributes\":[");
        for (log_record.attributes, 0..) |attr, i| {
            if (i > 0) try writer.writeAll(",");
            try self.serializeAttribute(attr, writer);
        }
        try writer.writeAll("],");

        // Trace context
        if (log_record.trace_id) |trace_id| {
            var trace_hex: [32]u8 = undefined;
            _ = std.fmt.bufPrint(&trace_hex, "{}", .{std.fmt.fmtSliceHexLower(&trace_id)}) catch return;
            try writer.print("\"traceId\":\"{s}\",", .{trace_hex});
        }

        if (log_record.span_id) |span_id| {
            var span_hex: [16]u8 = undefined;
            _ = std.fmt.bufPrint(&span_hex, "{}", .{std.fmt.fmtSliceHexLower(&span_id)}) catch return;
            try writer.print("\"spanId\":\"{s}\",", .{span_hex});
        }

        if (log_record.trace_flags) |flags| {
            try writer.print("\"flags\":{}", .{flags.toU8()});
        } else {
            // Remove trailing comma if no flags
            try writer.writeAll("\"droppedAttributesCount\":0");
        }

        try writer.writeAll("}");
    }

    fn serializeLogBody(self: *OTLPExporter, body: otel.LogBody, writer: anytype) !void {
        switch (body) {
            .string_value => |s| {
                try writer.writeAll("{\"stringValue\":\"");
                try writer.writeAll(s);
                try writer.writeAll("\"}");
            },
            .int_value => |i| {
                try writer.writeAll("{\"intValue\":\"");
                try writer.print("{}", .{i});
                try writer.writeAll("\"}");
            },
            .double_value => |d| {
                try writer.writeAll("{\"doubleValue\":");
                try writer.print("{d}", .{d});
                try writer.writeAll("}");
            },
            .bool_value => |b| {
                try writer.writeAll("{\"boolValue\":");
                try writer.print("{}", .{b});
                try writer.writeAll("}");
            },
            .bytes_value => |bytes| {
                const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
                const encoded = self.allocator.alloc(u8, encoded_len) catch return;
                defer self.allocator.free(encoded);
                _ = std.base64.standard.Encoder.encode(encoded, bytes);
                try writer.writeAll("{\"bytesValue\":\"");
                try writer.writeAll(encoded);
                try writer.writeAll("\"}");
            },
            .array_value => |array| {
                try writer.writeAll("{\"arrayValue\":{\"values\":[");
                for (array, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(",");
                    try self.serializeLogBody(item, writer);
                }
                try writer.writeAll("]}}");
            },
            .kvlist_value => |kvlist| {
                try writer.writeAll("{\"kvlistValue\":{\"values\":[");
                for (kvlist, 0..) |kv, i| {
                    if (i > 0) try writer.writeAll(",");
                    try self.serializeAttribute(kv, writer);
                }
                try writer.writeAll("]}}");
            },
        }
    }

    fn serializeAttribute(self: *OTLPExporter, attr: field.Field, writer: anytype) !void {
        _ = self;
        try writer.writeAll("{\"key\":\"");
        try writer.writeAll(attr.key);
        try writer.writeAll("\",\"value\":");

        switch (attr.value) {
            .string => |s| {
                try writer.writeAll("{\"stringValue\":\"");
                try writer.writeAll(s);
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
                try writer.print("{d}", .{f});
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

        try writer.writeAll("}");
    }

    fn sendHttpRequest(self: *OTLPExporter, payload: []const u8) !void {
        // This is a simplified HTTP client implementation
        // In a real implementation, you would use a proper HTTP client library

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Parse endpoint URL
        const uri = std.Uri.parse(self.endpoint) catch return ExportError.NetworkError;

        // Prepare headers
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();

        try headers.append("Content-Type", "application/json");
        try headers.append("User-Agent", "zlog-otlp-exporter/1.0.0");

        // Add custom headers
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            try headers.append(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Compression
        if (self.compression == .gzip) {
            try headers.append("Content-Encoding", "gzip");
            // TODO: Implement gzip compression
        }

        // Make request
        var request = client.request(.POST, uri, headers, .{}) catch return ExportError.NetworkError;
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = payload.len };

        try request.start();
        try request.writeAll(payload);
        try request.finish();
        try request.wait();

        // Check response status
        switch (request.response.status) {
            .ok => {}, // Success
            .unauthorized => return ExportError.AuthenticationError,
            .too_many_requests => return ExportError.RateLimited,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => return ExportError.ServerError,
            else => return ExportError.NetworkError,
        }
    }
};

/// Convenience function to create an OTLP exporter for common backends
pub fn createExporter(allocator: std.mem.Allocator, backend: Backend, config: ExporterConfig) !OTLPExporter {
    const endpoint = switch (backend) {
        .jaeger => config.endpoint orelse "http://localhost:14268/api/traces",
        .otlp_http => config.endpoint orelse "http://localhost:4318/v1/logs",
        .otlp_grpc => config.endpoint orelse "http://localhost:4317/v1/logs",
        .custom => config.endpoint orelse return error.MissingEndpoint,
    };

    var exporter = OTLPExporter.init(allocator, endpoint);

    if (config.api_key) |api_key| {
        try exporter.setApiKey(api_key);
    }

    if (config.timeout_ms) |timeout| {
        exporter.setTimeout(timeout);
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
    const allocator = testing.allocator;

    var exporter = OTLPExporter.init(allocator, "http://localhost:4318/v1/logs");
    defer exporter.deinit();

    try exporter.setApiKey("Bearer test-key");
    try exporter.setHeader("X-Custom-Header", "test-value");
    exporter.setTimeout(5000);
    exporter.setCompression(.gzip);
}

test "OTLP log serialization" {
    const allocator = testing.allocator;

    var exporter = OTLPExporter.init(allocator, "http://localhost:4318/v1/logs");
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

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try exporter.serializeLogsToOTLP(&[_]otel.LogRecord{log_record}, &buffer);

    const json = buffer.items;
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "resourceLogs"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "scopeLogs"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "logRecords"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "test-service"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "Test log message"));
}

test "Backend exporter creation" {
    const allocator = testing.allocator;

    const config = ExporterConfig{
        .api_key = "test-key",
        .timeout_ms = 5000,
        .compression = .gzip,
    };

    var exporter = try createExporter(allocator, .otlp_http, config);
    defer exporter.deinit();
}
