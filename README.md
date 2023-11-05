# zlog is a structured logging library for Zig.
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/LICENSE)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/hendriknielaender/zlog)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/hendriknielaender/zlog/blob/HEAD/CONTRIBUTING.md)
<img src="logo.png" alt="zlog logo" align="right" width="20%"/>

zlog is a structured logging library for Zig. It aims to provide a robust and extensible logging system that can handle the needs of complex applications while maintaining high performance.

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
    var handler = zlog.LogHandler{};
    var logger = zlog.Logger(zlog.LogHandler){
        .outputFormat = OutputFormat.PlainText,
        .handler = handler,
    };

    try logger.info("Hello, World!", null);
    var kv_pair = kv.kv("error", "NullPointerException");
    try logger.err("Something went wrong!", &[_]kv.KeyValue{kv_pair});
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

## Contributing

The main purpose of this repository is to continue to evolve zlog, making it faster and more efficient. We are grateful to the community for contributing bugfixes and improvements. Read below to learn how you can take part in improving zBench.

### Contributing Guide

Read our [contributing guide](CONTRIBUTING.md) to learn about our development process, how to propose bugfixes and improvements, and how to build and test your changes to zlog.

### License

zlog is [MIT licensed](./LICENSE).
