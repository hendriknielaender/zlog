const std = @import("std");

/// EventLoop is a thin compatibility wrapper over Zig 0.16's native `std.Io`
/// runtime. Under the hood we use the fully-supported `Io.Threaded`
/// implementation, which schedules work immediately and does not require
/// manual polling.
pub const EventLoop = struct {
    threaded: std.Io.Threaded,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .threaded = std.Io.Threaded.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *Self) void {
        self.threaded.deinit();
    }

    /// Retained for API compatibility. The threaded backend has no explicit
    /// polling step, so this is intentionally a no-op.
    pub fn runOnce(self: *Self) !void {
        _ = self;
    }

    /// Retained for API compatibility. The threaded backend runs tasks as soon
    /// as they are spawned, so there is no separate loop to drive here.
    pub fn run(self: *Self) !void {
        _ = self;
    }

    pub fn io(self: *Self) std.Io {
        return self.threaded.io();
    }
};
