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

> **Note**: libxev is automatically included as a dependency of zlog and managed internally. No need to import or manage event loops manually.

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
    // High-performance async logger with managed event loop
    var logger = try zlog.default(std.heap.page_allocator);
    defer logger.deinitWithAllocator(std.heap.page_allocator);
    
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

    // Process async events (when using async logger)
    try logger.runEventLoop();
}
```

### Async Logging

For maximum throughput in high-load scenarios:

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();

    // Create async logger with managed event loop
    const config = zlog.Config{
        .async_mode = true,
        .async_queue_size = 1024,
        .batch_size = 32,
        .enable_simd = true,
    };

    const stdout = std.io.getStdOut().writer();
    var logger = try zlog.Logger(config).initAsync(stdout.any(), gpa.allocator());
    defer logger.deinitWithAllocator(gpa.allocator());

    const trace_ctx = zlog.TraceContext.init(true);
    
    // Log messages per second
    for (0..1_000_000) |i| {
        logger.infoWithTrace("High throughput message", trace_ctx, &.{
            zlog.field.uint("iteration", i),
            zlog.field.string("service", "api"),
        });
        
        // Process event loop periodically
        if (i % 1000 == 0) {
            try logger.runEventLoop();
        }
    }
    
    // Final flush
    try logger.runEventLoop();
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

// Async logger with managed event loop
var logger = try zlog.Logger(Config).initAsync(writer, allocator);
defer logger.deinitWithAllocator(allocator);

// Or sync logger (no event loop needed)
var sync_logger = zlog.Logger(.{}).init(writer);
```

## Anonymous Struct API

zlog uses anonymous structs exclusively for clean, type-safe logging:

```zig
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
var redaction_config = zlog.RedactionConfig.init(allocator);
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();

    // Create OpenTelemetry-compliant logger with managed event loop
    var otel_logger = try zlog.otelLogger(gpa.allocator());
    defer otel_logger.deinitWithAllocator(gpa.allocator());

    // Log with OTel semantic conventions
    otel_logger.info("HTTP request received", .{
        .@"http.method" = "GET",
        .@"http.url" = "/api/users",
        .@"http.status_code" = 200,
        .@"http.user_agent" = "curl/7.68.0",
    });
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

var otel_logger = try zlog.otelLoggerWithConfig(otel_config, allocator);
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
std.time.sleep(100 * std.time.ns_per_ms);

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

### Custom Event Loop Management

For advanced users who need to integrate with existing event loops:

```zig
const xev = @import("xev"); // Only needed for advanced usage
const zlog = @import("zlog");

// Create your own event loop
var loop = try xev.Loop.init(.{});
defer loop.deinit();

// Use the advanced API with custom event loop
var logger = try zlog.Logger(.{ .async_mode = true }).initAsyncWithEventLoop(
    writer, 
    &loop, 
    allocator
);
defer logger.deinit(); // No allocator needed since you manage the loop

// You control the event loop
try loop.run(.no_wait);
```

### Managed vs Custom Event Loop

- **Managed (Recommended)**: Use `initAsync()` - zlog handles everything
- **Custom (Advanced)**: Use `initAsyncWithEventLoop()` - you control the loop

The managed approach is recommended for most users as it provides the cleanest API.

## Contributing

We welcome contributions that maintain our safety and performance standards:

1. **Follow TigerStyle** - All code must comply with TigerBeetle guidelines
2. **Add comprehensive tests** - Both positive and negative test cases
3. **Include benchmarks** - Performance impact must be measured
4. **Zero regressions** - Existing functionality must not be degraded

Read our [contributing guide](CONTRIBUTING.md) for detailed development process.

## Building & Development

```bash
# Build library
zig build

# Run all tests
zig build test

# Run all benchmarks
zig build benchmarks

# Run examples
zig build examples

# Generate documentation
zig build docs

# Format code
zig fmt src/ benchmarks/ examples/
```

### Project Structure

```
src/
├── zlog.zig              # Main library interface
├── logger.zig            # Core logging implementation
├── otel_logger.zig       # OpenTelemetry-compliant logger
├── otel.zig              # OTel data structures
├── otlp_exporter.zig     # OTLP export functionality
├── semantic_conventions.zig # OTel semantic conventions
├── field.zig             # Field type definitions
├── trace.zig             # Distributed tracing support
├── correlation.zig       # Span and task correlation
├── redaction.zig         # Field redaction system
├── config.zig            # Configuration types
└── string_escape.zig     # JSON string escaping

benchmarks/               # Performance benchmarks
examples/                 # Usage examples
```

## License

zlog is [MIT licensed](./LICENSE).
