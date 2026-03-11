> [!WARNING]  
> Still work in progress.

# zlog - structured logging for zig
[![MIT license][badge_license]][license_link]
![GitHub code size in bytes][badge_code_size]
[![PRs Welcome][badge_prs]][contributing_link]
<img src="logo.png" alt="zlog logo" align="right" width="20%"/>

zlog is a high-performance structured logging library for Zig with full OpenTelemetry support.
The synchronous formatting path avoids heap allocation, and async batching, redaction, and OTLP
export use caller-owned bounded state. Designed for system-level applications requiring maximum
performance and observability, zlog provides clean anonymous struct logging with comprehensive
tracing capabilities.

[badge_license]: https://img.shields.io/badge/license-MIT-blue.svg
[badge_code_size]: https://img.shields.io/github/languages/code-size/hendriknielaender/zlog
[badge_prs]: https://img.shields.io/badge/PRs-welcome-brightgreen.svg
[license_link]: https://github.com/hendriknielaender/zlog/blob/HEAD/LICENSE
[contributing_link]: https://github.com/hendriknielaender/zlog/blob/HEAD/CONTRIBUTING.md

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

> **Note**: zlog has no runtime dependency beyond Zig itself. Async logging uses caller-owned
> bounded state and explicit `drain()` / `flush()` calls.

2. Configure in `build.zig`:

```zig
const zlog_module = b.dependency("zlog", opts).module("zlog");
exe.root_module.addImport("zlog", zlog_module);
```

### Basic Usage

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    // Prefer std.fs.File.Writer so stdout/stderr stays buffered.
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr_writer.interface.flush() catch {};

    var logger = zlog.Logger(.{}).init(&stderr_writer);
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

    try logger.flush();
}
```

### Async Logging

For maximum throughput in high-load scenarios:

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    // Create async logger with caller-owned bounded state.
    const config = zlog.Config{
        .async_mode = true,
        .async_queue_size = 1024,
        .batch_size = 32,
        .enable_simd = true,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    var async_state = zlog.Logger(config).AsyncState{};
    var logger = zlog.Logger(config).initAsync(&stdout_writer, &async_state);
    defer logger.deinit();

    const trace_ctx = zlog.TraceContext.init(true);
    
    // Log messages per second
    for (0..1_000_000) |i| {
        logger.infoWithTrace("High throughput message", trace_ctx, &.{
            zlog.field.uint("iteration", i),
            zlog.field.string("service", "api"),
        });
        
        // Drain queued writes periodically.
        if (i % 1000 == 0) {
            logger.drain();
        }
    }
    
    try logger.flush();
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

var output_buffer: [4096]u8 = undefined;
var output_writer = std.fs.File.stdout().writer(&output_buffer);
defer output_writer.interface.flush() catch {};

// Async logger with caller-owned bounded state.
var async_state = zlog.Logger(Config).AsyncState{};
var logger = zlog.Logger(Config).initAsync(&output_writer, &async_state);
defer logger.deinit();
logger.drain();
try logger.flush();

// Or sync logger.
var sync_logger = zlog.Logger(.{}).init(&output_writer);
defer sync_logger.deinit();
try sync_logger.flush();
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
}, writer);

// These fields will be automatically redacted with zero runtime cost
logger.info("User login", &.{
    zlog.field.string("username", "alice"),
    zlog.field.string("password", "secret123"), // Output: [REDACTED:string]
});
```

### Runtime Redaction (Dynamic)

```zig
var redaction_storage: [16][]const u8 = undefined;
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

zlog is designed for zero-allocation synchronous logging and bounded-allocation async/export paths:

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

- **Zero Heap In Sync Hot Path**: Synchronous formatting avoids heap allocations
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
{
  "level":"INFO",
  "msg":"Request processed",
  "trace":"a1b2c3d4e5f67890a1b2c3d4e5f67890",
  "span":"1234567890abcdef",
  "ts":1640995200000,
  "tid":12345,
  "service":"api",
  "status_code":200
}
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

Pre-formatted hex strings eliminate per-log conversion overhead, which matters in ultra-high
throughput scenarios.

## OpenTelemetry Support

zlog provides full OpenTelemetry compliance with dedicated OTel loggers:

### Basic OTel Logger

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    // Create OpenTelemetry-compliant logger with caller-owned async state.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    var async_state = zlog.OTelLogger(.{
        .base_config = .{ .async_mode = true },
    }).AsyncState{};
    var otel_logger = zlog.otelLogger(&stdout_writer, &async_state);
    defer otel_logger.deinit();

    // Log with OTel semantic conventions
    otel_logger.info("HTTP request received", .{
        .@"http.method" = "GET",
        .@"http.url" = "/api/users",
        .@"http.status_code" = 200,
        .@"http.user_agent" = "curl/7.68.0",
    });

    try otel_logger.flush();
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

var async_state = zlog.OTelLogger(otel_config).AsyncState{};
var otel_logger = zlog.otelLoggerWithConfig(otel_config, writer, &async_state);
defer otel_logger.deinit();
otel_logger.drain();
try otel_logger.flush();
```

### OTLP Export

Serialize OTLP payloads with caller-owned header storage and transport:

```zig
var header_storage: [4]zlog.OTLPExporter.Header = undefined;
var exporter = zlog.OTLPExporter.init("http://localhost:4318/v1/logs", &header_storage);
defer exporter.deinit();

try exporter.setHeader("Authorization", "Bearer token123");

// Serialize the OTLP JSON payload to your chosen transport or buffer.
try exporter.exportLogs(writer, log_records);
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
std.time.sleep(100 * std.time.ns_per_ms);

// End the span with results
logger.spanEnd(span, .{
    .success = true,
    .token_type = "bearer",
});
```

Output includes automatic span correlation:
```json
{
  "level":"INFO",
  "msg":"user_authentication",
  "span_mark":"start",
  "span_id":123,
  "task_id":456,
  "thread_id":789,
  "user_id":"12345",
  "method":"oauth"
}
{
  "level":"INFO",
  "msg":"user_authentication",
  "span_mark":"end",
  "span_id":123,
  "task_id":456,
  "thread_id":789,
  "duration_ns":100000000,
  "success":true,
  "token_type":"bearer"
}
```

## Advanced Usage

### Explicit Queue Draining

Async logging is a bounded queue with explicit draining:

```zig
const zlog = @import("zlog");

var async_state = zlog.Logger(.{ .async_mode = true }).AsyncState{};
var logger = zlog.Logger(.{ .async_mode = true }).initAsync(writer, &async_state);
defer logger.deinit();

// You control when the queue is drained.
logger.drain();
try logger.flush();
```

### Drain vs Flush

- `drain()`: move queued entries to the writer without flushing the writer itself.
- `flush()`: drain the queue and flush the underlying writer.

## License

zlog is [MIT licensed](./LICENSE).
