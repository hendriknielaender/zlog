> [!WARNING]  
> Still work in progress.

# zlog - High-Performance Logging in Zig
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/LICENSE)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/hendriknielaender/zlog)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/CONTRIBUTING.md)
<img src="logo.png" alt="zlog logo" align="right" width="20%"/>

zlog is a safety-critical, high-performance structured logging library for Zig with zero allocations. Built following TigerBeetle engineering principles and NASA's Power of 10 rules for safety-critical code, zlog provides deterministic performance without hidden costs.

## Key Features

- **⚡ Zero Allocations**: All formatting happens in stack-allocated buffers - no hidden heap allocations
- **🎯 Structured Logging**: Type-safe key-value fields with compile-time validation
- **⚙️ Compile-Time Configuration**: Buffer sizes, field limits, and log levels configured at compile time
- **🔍 Level Filtering**: Efficient compile-time and runtime log level filtering (12ns)
- **📋 JSON Output**: First-class JSON formatting with optimized escaping
- **📦 Zero Dependencies**: Only Zig standard library

## Getting Started

### Installation

1. Declare zlog as a dependency in `build.zig.zon`:

    ```zig
    .{
        .name = "my-project",
        .version = "1.0.0",
        .paths = .{""},
        .dependencies = .{
            .zlog = .{
                .url = "https://github.com/hendriknielaender/zlog/archive/<COMMIT>.tar.gz",
                .hash = "<HASH>",
            },
        },
    }
    ```

2. Add it to your `build.zig`:

    ```zig
    const std = @import("std");

    pub fn build(b: *std.Build) void {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        const opts = .{ .target = target, .optimize = optimize };
        const zlog_module = b.dependency("zlog", opts).module("zlog");

        const exe = b.addExecutable(.{
            .name = "app",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zlog", zlog_module);
        b.installArtifact(exe);
    }
    ```

### Basic Usage

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    // Create a logger with default configuration
    var logger = zlog.default();
    
    // Simple logging
    logger.info("Application started", &.{});
    
    // Structured logging with fields
    logger.info("User logged in", &.{
        zlog.field.string("username", "alice"),
        zlog.field.uint("user_id", 12345),
        zlog.field.string("ip", "192.168.1.1"),
    });
    
    // Different log levels
    logger.debug("Debug information", &.{
        zlog.field.string("module", "auth"),
    });
    
    logger.err("Connection failed", &.{
        zlog.field.string("host", "api.example.com"),
        zlog.field.int("port", 443),
        zlog.field.float("timeout_seconds", 30.0),
    });
}
```

Output:
```json
{"level":"Info","message":"Application started"}
{"level":"Info","message":"User logged in","username":"alice","user_id":12345,"ip":"192.168.1.1"}
{"level":"Error","message":"Connection failed","host":"api.example.com","port":443,"timeout_seconds":30}
```

### Custom Configuration

```zig
// Create a logger with custom configuration
const Config = zlog.Config{
    .level = .debug,        // Minimum level to log
    .max_fields = 64,       // Maximum fields per message
    .buffer_size = 8192,    // Buffer size for formatting
};

var logger = zlog.Logger(Config).init(writer);
```

### Field Types

zlog supports multiple field types for structured logging:

```zig
// String fields
zlog.field.string("name", "Alice")

// Integer fields (signed and unsigned)
zlog.field.int("temperature", -10)
zlog.field.uint("count", 42)

// Floating point
zlog.field.float("pi", 3.14159)

// Boolean
zlog.field.boolean("enabled", true)

// Null values
zlog.field.null_value("optional_field")
```

### Log Levels

Available log levels in order of severity:

```zig
logger.trace("Detailed trace information", &.{});
logger.debug("Debug information", &.{});  
logger.info("Informational message", &.{});
logger.warn("Warning message", &.{});
logger.err("Error message", &.{});
logger.fatal("Fatal error", &.{});
```


## Building & Development

```bash
# Run tests
zig build test

# Run benchmarks
zig build bench

# Run isolated performance analysis
zig build isolated

# Run memory allocation benchmarks
zig build memory

# Build library
zig build

# Format code
zig fmt src/ benchmarks/
```

## Contributing

The main purpose of this repository is to continue to evolve zlog, making it faster and more efficient while maintaining the highest safety standards. We are grateful to the community for contributing bugfixes and improvements. 

Read our [contributing guide](CONTRIBUTING.md) to learn about our development process, which includes adherence to TigerStyle guidelines and safety-critical coding standards.

## License

zlog is [MIT licensed](./LICENSE).

---

*Built with ⚡ performance and 🛡️ safety in mind for production Zig applications.*
