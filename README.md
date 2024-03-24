# zlog - High-Performance Logging in Zig
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/LICENSE)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/hendriknielaender/zlog)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/CONTRIBUTING.md)
<img src="logo.png" alt="zlog logo" align="right" width="20%"/>

zlog is a high-performance, extensible logging library for Zig, designed to offer both simplicity and power in logging for system-level applications. Inspired by the best features of modern loggers and tailored for the Zig ecosystem, `zlog` brings structured, efficient, and flexible logging to your development toolkit.

## Key Features

- **High Performance**: Minimizes overhead, ensuring logging doesn't slow down your application.
- **Asynchronous Logging**: Non-blocking logging to maintain application performance.
- **Structured Logging**: Supports JSON and other structured formats for clear, queryable logs.
- **Customizable Log Levels**: Tailor log levels to fit your application's needs.
- **Redaction Capabilities**: Securely redact sensitive information from your logs.
- **Extensible Architecture**: Plug in additional handlers for specialized logging (e.g., file, network).
- **Cross-Platform Compatibility**: Consistent functionality across different platforms.
- **Intuitive API**: A simple, clear API that aligns with Zig's philosophy.

## Getting Started

### Installation

1. Declare zlog as a dependency in `build.zig.zon`:

    ```diff
    .{
        .name = "my-project",
        .version = "1.0.0",
        .paths = .{""},
        .dependencies = .{
    +       .zlog = .{
    +           .url = "https://github.com/hendriknielaender/zlog/archive/<COMMIT>.tar.gz",
    +       },
        },
    }
    ```

2. Add it to your `build.zig`:

    ```diff
    const std = @import("std");

    pub fn build(b: *std.Build) void {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

    +   const opts = .{ .target = target, .optimize = optimize };
    +   const zlog_module = b.dependency("zlog", opts).module("zlog");

        const exe = b.addExecutable(.{
            .name = "test",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });
    +   exe.addModule("zlog", zlog_module);
        exe.install();

        ...
    }
    ```

3. Get zlog package hash:

    ```
    $ zig build
    my-project/build.zig.zon:6:20: error: url field is missing corresponding hash field
            .url = "https://github.com/hendriknielaender/zlog/archive/<COMMIT>.tar.gz",
                   ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    note: expected .hash = "<HASH>",
    ```

4. Update `build.zig.zon` package hash value:

    ```diff
    .{
        .name = "my-project",
        .version = "1.0.0",
        .paths = .{""},
        .dependencies = .{
            .zlog = .{
                .url = "https://github.com/hendriknielaender/zlog/archive/<COMMIT>.tar.gz",
    +           .hash = "<HASH>",
            },
        },
    }
    ```

### Basic Usage

```zig
const zlog = @import("zlog");

// Set up your logger
var logger = zlog.Logger.init(allocator, zlog.Level.Info, zlog.OutputFormat.JSON, handler);
```

Here is a basic usage example of zlog:
```zig
// Simple logging
logger.log("This is an info log message");

// Asynchronous logging
logger.asyncLog("This is an error log message");
```

### Structured Logging
```zig
// Log with structured data
logger.info("Test message", &[_]kv.KeyValue{
    kv.KeyValue{ .key = "key1", .value = kv.Value{ .String = "value1" } },
    kv.KeyValue{ .key = "key2", .value = kv.Value{ .Int = 42 } },
    kv.KeyValue{ .key = "key3", .value = kv.Value{ .Float = 3.14 } },
});
```

## Contributing

The main purpose of this repository is to continue to evolve zlog, making it faster and more efficient. We are grateful to the community for contributing bugfixes and improvements. Read below to learn how you can take part in improving zBench.

### Contributing Guide

Read our [contributing guide](CONTRIBUTING.md) to learn about our development process, how to propose bugfixes and improvements, and how to build and test your changes to zlog.

### License

zlog is [MIT licensed](./LICENSE).
