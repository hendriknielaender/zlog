> [!WARNING]  
> Still work in progress.

# zlog - structured logging for zig
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/LICENSE)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/hendriknielaender/zlog)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/CONTRIBUTING.md)
<img src="logo.png" alt="zlog logo" align="right" width="20%"/>

zlog is a structured logging library for Zig.


### 🎯 **Tracing**
Full distributed tracing support with pre-formatted hex strings for maximum performance:

```zig
const trace_ctx = zlog.TraceContextImpl.init(true);
logger.infoWithTrace("Request processed", trace_ctx, &.{
    zlog.field.string("service", "api"),
    zlog.field.uint("status_code", 200),
});
```

Output:
```json
{"level":"INFO","msg":"Request processed","trace":"a1b2c3d4e5f67890a1b2c3d4e5f67890","span":"1234567890abcdef","ts":1640995200000,"tid":12345,"service":"api","status_code":200}
```

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
        .libxev = .{
            .url = "https://github.com/mitchellh/libxev/archive/<COMMIT>.tar.gz", 
            .hash = "<HASH>",
        },
    },
}
```

2. Configure in `build.zig`:

```zig
const zlog_module = b.dependency("zlog", opts).module("zlog");
const libxev_module = b.dependency("libxev", opts).module("xev");

exe.root_module.addImport("zlog", zlog_module);
exe.root_module.addImport("xev", libxev_module); // For async logging
```

### Basic Usage

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    // High-performance sync logger
    var logger = zlog.default();
    
    // Simple logging with trace context
    const trace_ctx = zlog.TraceContextImpl.init(true);
    logger.infoWithTrace("Service started", trace_ctx, &.{
        zlog.field.string("version", "1.0.0"),
        zlog.field.uint("port", 8080),
    });
    
    // Different field types
    logger.info("User action", &.{
        zlog.field.string("user", "alice"),
        zlog.field.uint("user_id", 12345),
        zlog.field.boolean("success", true),
        zlog.field.float("duration_ms", 45.7),
    });
}
```

### Async Logging

For maximum throughput in high-load scenarios:

```zig
const std = @import("std");
const zlog = @import("zlog");
const xev = @import("xev");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();

    // Setup event loop
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Create async logger
    const config = zlog.Config{
        .async_mode = true,
        .async_queue_size = 1024,
        .batch_size = 32,
        .enable_simd = true,
    };

    const stdout = std.io.getStdOut().writer();
    var logger = try zlog.Logger(config).initAsync(stdout.any(), &loop, gpa.allocator());
    defer logger.deinit();

    const trace_ctx = zlog.TraceContextImpl.init(true);
    
    // Log messages per second
    for (0..1_000_000) |i| {
        logger.infoWithTrace("High throughput message", trace_ctx, &.{
            zlog.field.uint("iteration", i),
            zlog.field.string("service", "api"),
        });
        
        // Process event loop periodically
        if (i % 1000 == 0) {
            try loop.run(.no_wait);
        }
    }
    
    // Final flush
    try loop.run(.no_wait);
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

var logger = zlog.Logger(Config).init(writer);
```

## Field Types

All field types are strongly typed and validated at compile time:

```zig
// String fields
zlog.field.string("service", "api")

// Integer fields
zlog.field.int("temperature", -10)
zlog.field.uint("request_id", 12345)

// Floating point
zlog.field.float("duration_ms", 123.45)

// Boolean
zlog.field.boolean("success", true)

// Null values
zlog.field.null_value("optional_data")
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

Run comprehensive performance analysis:

```bash
# Run all benchmarks
zig build benchmarks

# Individual components (if needed)
zig build test
```

## Trace Context

zlog provides full W3C Trace Context specification compliance:

```zig
// Create trace context
const trace_ctx = zlog.TraceContextImpl.init(true);

// Child spans maintain trace correlation
const child_ctx = trace_ctx.createChild(true);

// Extract for compatibility with other systems
const short_id = zlog.extract_short_from_trace_id(trace_ctx.trace_id);
```

Pre-formatted hex strings eliminate per-log conversion overhead, crucial for ultra-high throughput scenarios.



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

# Format code
zig fmt src/ benchmarks/
```

## License

zlog is [MIT licensed](./LICENSE).
