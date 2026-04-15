> [!WARNING]  
> Still work in progress.

# zlog - structured logging for zig
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/LICENSE)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/hendriknielaender/zlog)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/CONTRIBUTING.md)
<img src="logo.png" alt="zlog logo" align="right" width="20%"/>

zlog is a high-performance, zero-allocation structured logging library for Zig with full OpenTelemetry support. Designed for system-level applications requiring maximum performance and observability, zlog provides clean anonymous struct logging with comprehensive tracing capabilities.

---

## Getting Started

### Installation

1. Add to `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "1.0.0",
    .dependencies = .{
        .zlog = .{
            .url = "https://github.com/hendriknielaender/zlog/archive/<COMMIT>.tar.gz",
            .hash = "<HASH>",
        },
    },
}
```

> **Note**: zlog now uses Zig 0.16's native `std.Io` runtime. No external event-loop dependency is required.

2. Configure in `build.zig`:

```zig
const zlog_module = b.dependency("zlog", opts).module("zlog");
exe.root_module.addImport("zlog", zlog_module);
```

### Basic Usage

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    var logger = try zlog.Logger(.{ .async_mode = true }).initAsyncOwnedStderr(init.gpa, init.io);
    defer logger.deinit();
    
    // Clean, ergonomic logging with anonymous structs
    logger.info("Service started", .{
        .version = "1.0.0",
        .port = 8080,
    });
    
    // Type inference handles everything at compile time
    logger.info("User action", .{
        .user = "alice",
        .user_id = 12345,
        .success = true,
        .duration_ms = 45.7,
    });
    
    // With trace context for distributed tracing
    const trace_ctx = zlog.TraceContext.init(true);
    logger.infoWithTrace("Request processed", trace_ctx, .{
        .endpoint = "/api/users",
        .status_code = 200,
    });

    // Flush queued async work before shutdown
    try logger.runEventLoopUntilDone();
}
```

### Async Logging

For maximum throughput in high-load scenarios:

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const config = zlog.Config{
        .async_mode = true,
        .async_queue_size = 1024,
        .batch_size = 32,
        .enable_simd = true,
    };

    var logger = try zlog.Logger(config).initAsyncOwnedStderr(init.gpa, init.io);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    
    // Log messages per second
    for (0..1_000_000) |i| {
        logger.infoWithTrace("High throughput message", trace_ctx, .{
            .iteration = @as(u64, @intCast(i)),
            .service = "api",
        });
    }
    
    // Final flush
    try logger.runEventLoopUntilDone();
}
```

### Custom Configuration

```zig
const Config = zlog.Config{
    .level = .debug,           // Minimum level to log
    .max_fields = 64,          // Maximum fields per message  
    .buffer_size = 8192,       // Buffer size for formatting
    .async_mode = true,        // Enable async logging
    .async_queue_size = 2048,  // Async queue size
    .batch_size = 64,          // Batch size for async writes
    .enable_simd = true,       // Enable SIMD optimizations
};

// Async logger using Zig 0.16's native std.Io runtime
var logger = try zlog.Logger(Config).initAsyncOwnedStderr(allocator, io);
defer logger.deinit();

// Or sync logger
var sync_logger = try zlog.Logger(.{}).initOwnedStderr(allocator, io);
defer sync_logger.deinit();
```

## Anonymous Struct API

zlog uses anonymous structs exclusively for clean, type-safe logging:

```zig
// Type inference handles everything at compile time
logger.info("User login", .{
    .user_id = "12345",           // string
    .username = "john_doe",       // string  
    .attempt = 1,                 // int
    .success = true,              // bool
    .ip_address = "192.168.1.100", // string
    .session_duration = 3.14,     // float
    .metadata = null,             // null
});

// Clean syntax for all log levels
logger.debug("Debug info", .{ .component = "auth", .step = 1 });
logger.warn("Warning", .{ .threshold = 0.8, .current = 0.95 });
logger.err("Error", .{ .code = 500, .message = "Internal error" });
```

## Field Redaction

zlog provides a hybrid compile-time and runtime redaction system for sensitive data:

### Compile-time Redaction (Zero Cost)

```zig
// Define sensitive fields at compile-time
var logger = zlog.loggerWithRedaction(.{
    .redacted_fields = &.{ "password", "api_key", "ssn" },
});

// These fields will be automatically redacted with zero runtime cost
logger.info("User login", &.{
    zlog.field.string("username", "alice"),
    zlog.field.string("password", "secret123"), // Output: [REDACTED:string]
});
```

### Runtime Redaction (Dynamic)

```zig
var redaction_storage: [8][]const u8 = undefined;
var redaction_config = zlog.RedactionConfig.init(&redaction_storage);
defer redaction_config.deinit();

try redaction_config.addKey("credit_card");
try redaction_config.addKey("phone");

var logger = zlog.Logger(.{}).initWithRedaction(writer, &redaction_config);
```

### Hybrid Approach

```zig
// Combine compile-time and runtime redaction
const SecureLogger = zlog.LoggerWithRedaction(.{}, .{
    .redacted_fields = &.{ "password", "token" }, // Compile-time
});

var logger = SecureLogger.initWithRedaction(writer, &runtime_config);
```

## Log Levels

```zig
logger.trace("Detailed trace", &.{});  // Lowest priority
logger.debug("Debug info", &.{});      
logger.info("Information", &.{});      // Default level
logger.warn("Warning", &.{});          
logger.err("Error occurred", &.{});    
logger.fatal("Fatal error", &.{});     // Highest priority
```

## Performance Benchmarks

zlog is designed for zero-allocation logging with exceptional performance:

```bash
# Run all benchmarks
zig build benchmarks

# Individual benchmark categories
zig build benchmark-memory      # Memory allocation analysis
zig build benchmark-async       # Async performance
zig build benchmark-production  # Production workload simulation
zig build benchmark-comprehensive # Full feature benchmarks

# Run tests
zig build test
```

### Key Performance Features

- **Zero Allocations**: No heap allocations during logging operations
- **SIMD Optimizations**: Vectorized string operations where available  
- **Async Batching**: Intelligent batching with backpressure handling
- **Pre-formatted Traces**: Hex strings generated once, reused efficiently
- **Compile-time Field Validation**: Type safety with zero runtime cost

## Trace

Full distributed tracing support with pre-formatted hex strings for maximum performance:

```zig
const trace_ctx = zlog.TraceContext.init(true);
logger.infoWithTrace("Request processed", trace_ctx, .{
    .endpoint = "/api/users",
    .status_code = 200,
    .duration_ms = 45.7,
});
```

Output:
```json
{"level":"INFO","msg":"Request processed","trace":"a1b2c3d4e5f67890a1b2c3d4e5f67890","span":"1234567890abcdef","ts":1640995200000,"tid":12345,"service":"api","status_code":200}
```

zlog provides full W3C Trace Context specification compliance:

```zig
// Create trace context
const trace_ctx = zlog.TraceContext.init(true);

// Child spans maintain trace correlation
const child_ctx = trace_ctx.createChild(true);

// Extract for compatibility with other systems
const short_id = zlog.extract_short_from_trace_id(trace_ctx.trace_id);
```

Pre-formatted hex strings eliminate per-log conversion overhead, crucial for ultra-high throughput scenarios.

## OpenTelemetry Support

zlog provides full OpenTelemetry compliance with dedicated OTel loggers:

### Basic OTel Logger

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    var otel_logger = try zlog.OTelLogger(.{
        .base_config = .{ .async_mode = true },
    }).initAsyncOwnedStderr(init.gpa, init.io);
    defer otel_logger.deinit();

    // Log with OTel semantic conventions
    otel_logger.info("HTTP request received", .{
        .@"http.method" = "GET",
        .@"http.url" = "/api/users",
        .@"http.status_code" = 200,
        .@"http.user_agent" = "curl/7.68.0",
    });

    try otel_logger.runEventLoopUntilDone();
}
```

### Custom OTel Configuration

```zig
const otel_config = zlog.OTelConfig{
    .base_config = .{
        .async_mode = true,
        .level = .debug,
        .buffer_size = 8192,
    },
    .resource = .{
        .service_name = "my-service",
        .service_version = "1.0.0",
        .service_namespace = "production",
    },
    .instrumentation_scope = .{
        .name = "my-service-logger",
        .version = "1.0.0",
    },
};

var shared_runtime = zlog.EventLoop.init(allocator);
defer shared_runtime.deinit();

var otel_logger = try zlog.otelLoggerWithConfig(otel_config, &shared_runtime, allocator);
defer otel_logger.deinit();
```

### OTLP Export

Export logs directly to OpenTelemetry collectors:

```zig
const exporter = zlog.OTLPExporter.init(allocator, .{
    .endpoint = "http://localhost:4318/v1/logs",
    .headers = &.{
        .{ .key = "Authorization", .value = "Bearer token123" },
    },
});
defer exporter.deinit();

// Export log records
try exporter.export(&log_records);
```

### Semantic Conventions

Use standardized OpenTelemetry semantic conventions:

```zig
// HTTP semantic conventions
logger.info("Request processed", .{
    .@"http.method" = zlog.SemConv.HTTP.method.GET,
    .@"http.status_code" = 200,
    .@"http.route" = "/api/users/{id}",
});

// Database semantic conventions  
logger.debug("Database query", .{
    .@"db.system" = zlog.SemConv.DB.system.postgresql,
    .@"db.statement" = "SELECT * FROM users WHERE id = $1",
    .@"db.operation" = "SELECT",
});

// Common fields helper
const common = zlog.CommonFields{
    .service_name = "user-service",
    .service_version = "1.2.3",
    .environment = "production",
};
```

## Span Tracking & Correlation

Built-in span tracking for distributed tracing:

```zig
// Start a span (supports both syntaxes)
const span = logger.spanStart("user_authentication", .{
    .user_id = "12345",
    .method = "oauth",
});

// Your business logic here...

// End the span with results
logger.spanEnd(span, .{
    .success = true,
    .token_type = "bearer",
});
```

Output includes automatic span correlation:
```json
{"level":"INFO","msg":"user_authentication","span_mark":"start","span_id":123,"task_id":456,"thread_id":789,"user_id":"12345","method":"oauth"}
{"level":"INFO","msg":"user_authentication","span_mark":"end","span_id":123,"task_id":456,"thread_id":789,"duration_ns":100000000,"success":true,"token_type":"bearer"}
```

## Advanced Usage

### Shared Runtime Management

For advanced users who want to share a `std.Io` runtime across multiple components:

```zig
const zlog = @import("zlog");

var runtime = zlog.EventLoop.init(allocator);
defer runtime.deinit();

// `writer` is a `*std.Io.Writer`
var logger = try zlog.Logger(.{ .async_mode = true }).initAsyncWithEventLoop(
    writer,
    &runtime,
    allocator
);
defer logger.deinit();

try logger.runEventLoopUntilDone();
```

### Managed vs Shared Runtime

- **Managed (Recommended)**: Use `initAsync()` or `initAsyncOwnedStderr()` and let zlog create its own runtime.
- **Shared Runtime (Advanced)**: Use `initAsyncWithIo()` or `initAsyncWithEventLoop()` when you want zlog to reuse an existing `std.Io` runtime.

## License

zlog is [MIT licensed](./LICENSE).
