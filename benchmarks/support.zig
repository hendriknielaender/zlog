const std = @import("std");

pub fn runtimeIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn nowNs() i128 {
    return @as(i128, std.Io.Timestamp.now(runtimeIo(), .awake).nanoseconds);
}

pub fn nowMs() i64 {
    return std.Io.Timestamp.now(runtimeIo(), .real).toMilliseconds();
}

pub fn sleepMs(ms: i64) void {
    runtimeIo().sleep(.fromMilliseconds(ms), .awake) catch {};
}

pub fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

pub fn perSecond(count: usize, duration_ns: i128) f64 {
    const seconds = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;
    if (seconds <= 0.0) return 0.0;
    return @as(f64, @floatFromInt(count)) / seconds;
}

pub const LatencyWriter = struct {
    bytes_written: std.atomic.Value(u64) = .init(0),
    io: std.Io,
    latency_ns: i128,
    writer: std.Io.Writer,

    pub fn init(io: std.Io, latency_ns: i128, buffer: []u8) LatencyWriter {
        return .{
            .io = io,
            .latency_ns = latency_ns,
            .writer = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    pub fn totalBytes(self: *const LatencyWriter) u64 {
        return self.bytes_written.load(.monotonic) + self.writer.buffered().len;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LatencyWriter = @alignCast(@fieldParentPtr("writer", w));
        if (self.latency_ns > 0) busyWait(self.io, self.latency_ns);

        const consumed = std.Io.Writer.countSplat(data, splat);
        _ = self.bytes_written.fetchAdd(w.buffered().len + consumed, .monotonic);
        w.end = 0;
        return consumed;
    }
};

fn busyWait(io: std.Io, ns: i128) void {
    const start = @as(i128, std.Io.Timestamp.now(io, .awake).nanoseconds);
    while (@as(i128, std.Io.Timestamp.now(io, .awake).nanoseconds) - start < ns) {
        std.atomic.spinLoopHint();
    }
}
