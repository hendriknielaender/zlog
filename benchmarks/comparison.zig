const std = @import("std");
const zbench = @import("zbench");
const zlog = @import("zlog");

// Simple comparison benchmarks to put zlog performance in context

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    // zlog benchmarks
    try bench.add("zlog_simple", benchZlogSimple, .{});
    try bench.add("zlog_structured", benchZlogStructured, .{});

    // Standard library alternatives
    try bench.add("std_fmt_simple", benchStdFmtSimple, .{});
    try bench.add("std_fmt_structured", benchStdFmtStructured, .{});

    // Memory operations for context
    try bench.add("memory_copy_4kb", benchMemoryCopy, .{});
    try bench.add("string_concat", benchStringConcat, .{});

    try bench.run(std.io.getStdOut().writer());
}

fn benchZlogSimple(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        logger.info("User logged in successfully", &.{});
    }
}

fn benchZlogStructured(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var logger = zlog.Logger(.{}).init(null_writer.writer().any());

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        logger.info("User action", &.{
            zlog.field.string("user_id", "12345"),
            zlog.field.string("action", "login"),
            zlog.field.int("timestamp", 1634567890),
        });
    }
}

fn benchStdFmtSimple(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var buffer: [4096]u8 = undefined;

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        const formatted = std.fmt.bufPrint(&buffer, "{{\"level\":\"Info\",\"message\":\"User logged in successfully\"}}\n", .{}) catch unreachable;
        _ = null_writer.writer().write(formatted) catch {};
    }
}

fn benchStdFmtStructured(allocator: std.mem.Allocator) void {
    _ = allocator;
    var null_writer = NullWriter{};
    var buffer: [4096]u8 = undefined;

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        const formatted = std.fmt.bufPrint(
            &buffer,
            "{{\"level\":\"Info\",\"message\":\"User action\",\"user_id\":\"{s}\",\"action\":\"{s}\",\"timestamp\":{d}}}\n",
            .{ "12345", "login", 1634567890 },
        ) catch unreachable;
        _ = null_writer.writer().write(formatted) catch {};
    }
}

fn benchMemoryCopy(allocator: std.mem.Allocator) void {
    _ = allocator;
    var source: [4096]u8 = undefined;
    var dest: [4096]u8 = undefined;

    @memset(&source, 0x42);

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        @memcpy(&dest, &source);
    }
}

fn benchStringConcat(allocator: std.mem.Allocator) void {
    _ = allocator;
    var buffer: [4096]u8 = undefined;

    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        _ = std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ "prefix", "middle", "suffix" }) catch unreachable;
    }
}
