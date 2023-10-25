<h1 align="center">
   <img src="logo.png" width="30%" height="30%" alt="zlog logo" title="zlog logo">
</h1>
<div align="center">
zlog is a structured logging library for Zig. It aims to provide a robust and extensible logging system that can handle the needs of complex applications while maintaining high performance.
</div>
<br><br>

## Features

- **Structured Logging**: Log messages are structured as key-value pairs, making it easy to filter and analyze logs.
- **Contextual Logging**: Attach contextual information to log entries, aiding in debugging and analysis.
- **Extensible Output Formats**: Supports multiple output formats like JSON, XML, and YAML, with the ability to define custom formats.
- **Hierarchical Loggers**: Create loggers in a hierarchy to control logging behavior at different levels of an application.
- **Log Levels**: Define log levels to control the verbosity of logging output.
- **Modular Design**: Separate components for log processing, formatting, and output, allowing for custom extensions.
- **Asynchronous Logging**: Log entries are processed asynchronously for better performance.
- **Back Pressure Handling**: Ensures the system remains responsive under heavy logging load.

## Installation

..

## Usage
Here is a basic usage example of zlog:
```zig
const zlog = @import("zlog");
const std = @import("std");

pub fn main() !void {
    var logger = zlog.Logger{
        .level = zlog.Level.Info,
    };

    logger.info("Hello, World!", .{});
    logger.error("Something went wrong!", .{
        .error = "NullPointerException",
    });
}
```

## Configuration
Customize your logger by setting various configuration options:
```zig
var logger = zlog.Logger{
    .level = zlog.Level.Debug,
    .outputFormat = zlog.OutputFormat.JSON,
    .output = std.io.getStdOut().writer(),
};
```

