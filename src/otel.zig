const std = @import("std");
const assert = std.debug.assert;
const config = @import("config.zig");
const field = @import("field.zig");
const trace_mod = @import("trace.zig");

/// OpenTelemetry Log Severity Numbers as per specification
/// https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
pub const SeverityNumber = enum(u8) {
    unspecified = 0,
    trace = 1,
    trace2 = 2,
    trace3 = 3,
    trace4 = 4,
    debug = 5,
    debug2 = 6,
    debug3 = 7,
    debug4 = 8,
    info = 9,
    info2 = 10,
    info3 = 11,
    info4 = 12,
    warn = 13,
    warn2 = 14,
    warn3 = 15,
    warn4 = 16,
    err = 17,
    err2 = 18,
    err3 = 19,
    err4 = 20,
    fatal = 21,
    fatal2 = 22,
    fatal3 = 23,
    fatal4 = 24,

    pub fn fromLevel(level: config.Level) SeverityNumber {
        return switch (level) {
            .trace => .trace,
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
            .fatal => .fatal,
        };
    }

    pub fn severityText(self: SeverityNumber) []const u8 {
        return switch (self) {
            .unspecified => "UNSPECIFIED",
            .trace, .trace2, .trace3, .trace4 => "TRACE",
            .debug, .debug2, .debug3, .debug4 => "DEBUG",
            .info, .info2, .info3, .info4 => "INFO",
            .warn, .warn2, .warn3, .warn4 => "WARN",
            .err, .err2, .err3, .err4 => "ERROR",
            .fatal, .fatal2, .fatal3, .fatal4 => "FATAL",
        };
    }
};

/// OpenTelemetry Resource represents the entity producing telemetry
pub const Resource = struct {
    service_name: []const u8 = "unknown_service",
    service_version: ?[]const u8 = null,
    service_namespace: ?[]const u8 = null,
    service_instance_id: ?[]const u8 = null,

    // Process attributes
    process_pid: ?u32 = null,
    process_executable_name: ?[]const u8 = null,
    process_executable_path: ?[]const u8 = null,
    process_command_line: ?[]const u8 = null,
    process_runtime_name: ?[]const u8 = null,
    process_runtime_version: ?[]const u8 = null,

    // Host attributes
    host_name: ?[]const u8 = null,
    host_id: ?[]const u8 = null,
    host_type: ?[]const u8 = null,
    host_arch: ?[]const u8 = null,

    // OS attributes
    os_type: ?[]const u8 = null,
    os_description: ?[]const u8 = null,
    os_name: ?[]const u8 = null,
    os_version: ?[]const u8 = null,

    pub fn init() Resource {
        return Resource{
            .os_type = switch (@import("builtin").os.tag) {
                .linux => "linux",
                .windows => "windows",
                .macos => "darwin",
                .freebsd => "freebsd",
                else => "unknown",
            },
            .host_arch = switch (@import("builtin").cpu.arch) {
                .x86_64 => "amd64",
                .aarch64 => "arm64",
                .x86 => "386",
                else => "unknown",
            },
        };
    }
    pub fn withProcessInfo(self: Resource) Resource {
        assert(self.service_name.len > 0);

        var updated = self;
        // Auto-detect process information at runtime
        updated.process_pid = switch (@import("builtin").os.tag) {
            .linux => @intCast(std.os.linux.getpid()),
            .windows => @intCast(std.os.windows.kernel32.GetCurrentProcessId()),
            .macos => @intCast(std.c.getpid()),
            else => null,
        };

        assert(updated.service_name.len > 0);
        return updated;
    }
    pub fn withService(self: Resource, name: []const u8, version: ?[]const u8) Resource {
        assert(name.len > 0);
        assert(name.len < 256);

        var updated = self;
        updated.service_name = name;
        updated.service_version = version;

        assert(updated.service_name.len > 0);
        return updated;
    }
};

/// OpenTelemetry Instrumentation Scope
pub const InstrumentationScope = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    schema_url: ?[]const u8 = null,

    pub fn init(name: []const u8) InstrumentationScope {
        assert(name.len > 0);
        assert(name.len < 256);

        const result = InstrumentationScope{ .name = name };
        assert(result.name.len > 0);
        return result;
    }

    pub fn withVersion(self: InstrumentationScope, version: []const u8) InstrumentationScope {
        assert(self.name.len > 0);
        assert(version.len > 0);

        var updated = self;
        updated.version = version;

        assert(updated.name.len > 0);
        assert(updated.version.?.len > 0);
        return updated;
    }
};

/// OpenTelemetry LogRecord as per specification
/// https://opentelemetry.io/docs/specs/otel/logs/data-model/
pub const LogRecord = struct {
    // Core fields
    timestamp: u64, // Unix nanoseconds
    observed_timestamp: u64, // Unix nanoseconds
    severity_number: SeverityNumber,
    severity_text: ?[]const u8 = null,
    body: LogBody,
    attributes: []const field.Field,

    // Trace correlation
    trace_id: ?[16]u8 = null,
    span_id: ?[8]u8 = null,
    trace_flags: ?trace_mod.TraceFlags = null,

    // Context
    resource: Resource,
    instrumentation_scope: InstrumentationScope,

    pub fn init(
        level: config.Level,
        message: []const u8,
        attributes: []const field.Field,
        trace_ctx: ?trace_mod.TraceContext,
        resource: Resource,
        scope: InstrumentationScope,
    ) LogRecord {
        assert(@intFromEnum(level) <= @intFromEnum(config.Level.fatal));
        assert(message.len > 0);
        assert(message.len < 65536);
        assert(attributes.len <= 1024);
        assert(resource.service_name.len > 0);
        assert(scope.name.len > 0);

        const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
        const severity = SeverityNumber.fromLevel(level);

        const result = LogRecord{
            .timestamp = now_ns,
            .observed_timestamp = now_ns,
            .severity_number = severity,
            .severity_text = severity.severityText(),
            .body = LogBody{ .string_value = message },
            .attributes = attributes,
            .trace_id = if (trace_ctx) |ctx| ctx.trace_id else null,
            .span_id = if (trace_ctx) |ctx| ctx.parent_id else null,
            .trace_flags = if (trace_ctx) |ctx| ctx.trace_flags else null,
            .resource = resource,
            .instrumentation_scope = scope,
        };

        assert(result.timestamp > 0);
        assert(result.observed_timestamp > 0);
        assert(@intFromEnum(result.severity_number) <= 24);
        assert(result.body.asString().?.len > 0);
        return result;
    }
};

/// OpenTelemetry LogBody can be various types
pub const LogBody = union(enum) {
    string_value: []const u8,
    int_value: i64,
    double_value: f64,
    bool_value: bool,
    bytes_value: []const u8,
    array_value: []const LogBody,
    kvlist_value: []const field.Field,

    pub fn asString(self: LogBody) ?[]const u8 {
        assert(@TypeOf(self) == LogBody);

        const result = switch (self) {
            .string_value => |s| s,
            else => null,
        };

        if (result) |s| {
            assert(s.len >= 0);
        }
        return result;
    }
};

/// OTel-compliant configuration
pub const OTelConfig = struct {
    base_config: config.Config = .{},
    resource: Resource = Resource.init(),
    instrumentation_scope: InstrumentationScope = InstrumentationScope.init("zlog"),
    enable_otel_format: bool = false,

    pub fn withOTelFormat(self: OTelConfig) OTelConfig {
        assert(self.resource.service_name.len > 0);

        var updated = self;
        updated.enable_otel_format = true;

        assert(updated.enable_otel_format == true);
        return updated;
    }

    pub fn withResource(self: OTelConfig, resource: Resource) OTelConfig {
        assert(resource.service_name.len > 0);
        assert(self.instrumentation_scope.name.len > 0);

        var updated = self;
        updated.resource = resource;

        assert(updated.resource.service_name.len > 0);
        return updated;
    }

    pub fn withScope(self: OTelConfig, scope: InstrumentationScope) OTelConfig {
        assert(scope.name.len > 0);
        assert(self.resource.service_name.len > 0);

        var updated = self;
        updated.instrumentation_scope = scope;

        assert(updated.instrumentation_scope.name.len > 0);
        return updated;
    }
};

const testing = std.testing;

test "SeverityNumber mapping from Level" {
    try testing.expect(SeverityNumber.fromLevel(.trace) == .trace);
    try testing.expect(SeverityNumber.fromLevel(.debug) == .debug);
    try testing.expect(SeverityNumber.fromLevel(.info) == .info);
    try testing.expect(SeverityNumber.fromLevel(.warn) == .warn);
    try testing.expect(SeverityNumber.fromLevel(.err) == .err);
    try testing.expect(SeverityNumber.fromLevel(.fatal) == .fatal);
}

test "SeverityNumber severity text" {
    try testing.expectEqualStrings("TRACE", SeverityNumber.trace.severityText());
    try testing.expectEqualStrings("DEBUG", SeverityNumber.debug.severityText());
    try testing.expectEqualStrings("INFO", SeverityNumber.info.severityText());
    try testing.expectEqualStrings("WARN", SeverityNumber.warn.severityText());
    try testing.expectEqualStrings("ERROR", SeverityNumber.err.severityText());
    try testing.expectEqualStrings("FATAL", SeverityNumber.fatal.severityText());
}

test "Resource initialization" {
    const resource = Resource.init();
    try testing.expectEqualStrings("unknown_service", resource.service_name);
    try testing.expect(resource.process_pid == null); // Not set by default
    try testing.expect(resource.os_type != null);
    try testing.expect(resource.host_arch != null);

    // Test with process info
    const resource_with_process = resource.withProcessInfo();
    try testing.expect(resource_with_process.process_pid != null);
}

test "Resource with service" {
    const resource = Resource.init().withService("my-service", "1.0.0");
    try testing.expectEqualStrings("my-service", resource.service_name);
    try testing.expectEqualStrings("1.0.0", resource.service_version.?);
}

test "InstrumentationScope creation" {
    const scope = InstrumentationScope.init("test-logger").withVersion("2.0.0");
    try testing.expectEqualStrings("test-logger", scope.name);
    try testing.expectEqualStrings("2.0.0", scope.version.?);
}

test "LogRecord creation" {
    const resource = Resource.init().withService("test-service", "1.0.0");
    const scope = InstrumentationScope.init("test-scope");
    const trace_ctx = trace_mod.TraceContext.init(true);

    const attributes = [_]field.Field{
        field.Field.string("key", "value"),
        field.Field.int("count", 42),
    };

    const log_record = LogRecord.init(
        .info,
        "Test message",
        &attributes,
        trace_ctx,
        resource,
        scope,
    );

    try testing.expect(log_record.severity_number == .info);
    try testing.expectEqualStrings("INFO", log_record.severity_text.?);
    try testing.expectEqualStrings("Test message", log_record.body.asString().?);
    try testing.expect(log_record.attributes.len == 2);
    try testing.expect(log_record.trace_id != null);
    try testing.expect(log_record.span_id != null);
    try testing.expectEqualStrings("test-service", log_record.resource.service_name);
    try testing.expectEqualStrings("test-scope", log_record.instrumentation_scope.name);
}

test "OTelConfig configuration" {
    var otel_config = OTelConfig{};
    otel_config = otel_config.withOTelFormat();
    otel_config = otel_config.withResource(Resource.init().withService("my-app", "2.1.0"));
    otel_config = otel_config.withScope(InstrumentationScope.init("my-logger").withVersion("1.5.0"));

    try testing.expect(otel_config.enable_otel_format == true);
    try testing.expectEqualStrings("my-app", otel_config.resource.service_name);
    try testing.expectEqualStrings("2.1.0", otel_config.resource.service_version.?);
    try testing.expectEqualStrings("my-logger", otel_config.instrumentation_scope.name);
    try testing.expectEqualStrings("1.5.0", otel_config.instrumentation_scope.version.?);
}
