const std = @import("std");
const zbench = @import("zbench");
const zlog = @import("zlog");

// Null writer for performance testing without I/O overhead
const NullWriter = struct {
    const Self = @This();
    const Error = error{};
    const Writer = std.io.Writer(*Self, Error, write);

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    fn write(self: *Self, bytes: []const u8) Error!usize {
        _ = self;
        return bytes.len;
    }
};

// Global allocator for benchmarks
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn benchmarkRegularFields(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.Field.string("username", "john.doe@example.com"),
        zlog.Field.string("password", "super_secret_password_123"),
        zlog.Field.string("api_key", "sk_live_abcdef123456789"),
        zlog.Field.int("user_id", 12345),
        zlog.Field.float("balance", 1234.56),
    };

    logger.infoWithTrace("User activity - no redaction", trace_ctx, &fields);
}

fn benchmarkRedactedFields(allocator: std.mem.Allocator) void {
    // Set up redaction config for this benchmark
    var redaction_config = zlog.RedactionConfig.init(allocator);
    defer redaction_config.deinit();
    
    redaction_config.addKey("password") catch return;
    redaction_config.addKey("api_key") catch return;
    
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).initWithRedaction(null_writer.writer().any(), &redaction_config);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.Field.string("username", "john.doe@example.com"),
        zlog.Field.string("password", "super_secret_password_123"), // Will be redacted
        zlog.Field.string("api_key", "sk_live_abcdef123456789"), // Will be redacted
        zlog.Field.int("user_id", 12345),
        zlog.Field.float("balance", 1234.56),
    };

    logger.infoWithTrace("User activity - automatic redaction", trace_ctx, &fields);
}

fn benchmarkMixedFields(allocator: std.mem.Allocator) void {
    // Set up redaction config for some fields
    var redaction_config = zlog.RedactionConfig.init(allocator);
    defer redaction_config.deinit();
    
    redaction_config.addKey("password") catch return;
    redaction_config.addKey("session_token") catch return;
    redaction_config.addKey("secret_data") catch return;
    
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).initWithRedaction(null_writer.writer().any(), &redaction_config);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.Field.string("action", "user_login"),
        zlog.Field.string("username", "alice@example.com"),
        zlog.Field.string("password", "secretpassword123"), // Will be redacted
        zlog.Field.string("ip_address", "192.168.1.100"),
        zlog.Field.string("session_token", "abc123def456"), // Will be redacted
        zlog.Field.int("attempt", 1),
        zlog.Field.boolean("success", true),
    };

    logger.infoWithTrace("Mixed regular and redacted fields", trace_ctx, &fields);
}

fn benchmarkManyRedactedFields(allocator: std.mem.Allocator) void {
    // Set up redaction config for many fields
    var redaction_config = zlog.RedactionConfig.init(allocator);
    defer redaction_config.deinit();
    
    redaction_config.addKey("ssn") catch return;
    redaction_config.addKey("credit_card") catch return;
    redaction_config.addKey("cvv") catch return;
    redaction_config.addKey("pin") catch return;
    redaction_config.addKey("password") catch return;
    redaction_config.addKey("api_key") catch return;
    redaction_config.addKey("secret_token") catch return;
    
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).initWithRedaction(null_writer.writer().any(), &redaction_config);

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.Field.string("ssn", "123-45-6789"), // Will be redacted
        zlog.Field.string("credit_card", "4532123456789012"), // Will be redacted
        zlog.Field.string("cvv", "123"), // Will be redacted
        zlog.Field.string("pin", "1234"), // Will be redacted
        zlog.Field.string("password", "mypassword123"), // Will be redacted
        zlog.Field.string("api_key", "sk_live_abc123"), // Will be redacted
        zlog.Field.string("secret_token", "token_xyz789"), // Will be redacted
        zlog.Field.string("user_id", "USER-12345"),
        zlog.Field.boolean("verified", true),
        zlog.Field.string("country", "US"),
        zlog.Field.int("age", 30),
        zlog.Field.float("balance", 1500.75),
    };

    logger.infoWithTrace("Many redacted fields", trace_ctx, &fields);
}

fn benchmarkLegacyRedactedField(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    const trace_ctx = zlog.TraceContext.init(true);
    const fields = [_]zlog.Field{
        zlog.Field.string("username", "user@example.com"),
        // Manual redacted field (still supported for legacy use)
        zlog.Field{ 
            .key = "manual_redacted", 
            .value = .{ 
                .redacted = .{ 
                    .value_type = .string, 
                    .hint = "manual_hint" 
                } 
            } 
        },
        zlog.Field.int("request_count", 42),
    };

    logger.infoWithTrace("Legacy redacted field", trace_ctx, &fields);
}

pub fn main() !void {
    const allocator = gpa.allocator();
    
    var bench = zbench.Benchmark.init(allocator, .{
        .iterations = 1_000_000,
        .max_iterations = 10_000_000,
        .time_budget_ns = 2_000_000_000, // 2 seconds per benchmark
    });
    defer bench.deinit();
    
    std.debug.print("\n=== zlog Automatic Redaction Performance Benchmarks ===\n\n", .{});
    
    try bench.add("Regular fields (baseline)", benchmarkRegularFields, .{});
    try bench.add("Automatic redaction", benchmarkRedactedFields, .{});
    try bench.add("Mixed regular/redacted", benchmarkMixedFields, .{});
    try bench.add("Many redacted fields", benchmarkManyRedactedFields, .{});
    try bench.add("Legacy manual redaction", benchmarkLegacyRedactedField, .{});
    
    try bench.run(std.io.getStdOut().writer());
}