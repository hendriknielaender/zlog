const std = @import("std");
const assert = std.debug.assert;
const xev = @import("xev");

/// EventLoop provides a clean abstraction over the underlying event loop implementation.
/// This hides libxev details from users and provides a stable public API.
pub const EventLoop = struct {
    inner: xev.Loop,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new event loop
    pub fn init(allocator: std.mem.Allocator) !Self {
        assert(@TypeOf(allocator) == std.mem.Allocator);

        const inner_loop = try xev.Loop.init(.{});
        assert(@TypeOf(inner_loop) == xev.Loop);

        const result = Self{
            .inner = inner_loop,
            .allocator = allocator,
        };

        assert(@TypeOf(result.allocator) == std.mem.Allocator);
        return result;
    }

    /// Clean up the event loop
    pub fn deinit(self: *Self) void {
        assert(@TypeOf(self.*) == Self);
        assert(@TypeOf(self.inner) == xev.Loop);

        self.inner.deinit();
    }

    /// Run the event loop once without blocking
    pub fn runOnce(self: *Self) !void {
        assert(@TypeOf(self.*) == Self);
        assert(@TypeOf(self.inner) == xev.Loop);

        try self.inner.run(.no_wait);
    }

    /// Run the event loop until completion
    pub fn run(self: *Self) !void {
        assert(@TypeOf(self.*) == Self);
        assert(@TypeOf(self.inner) == xev.Loop);

        try self.inner.run(.until_done);
    }

    /// Get the underlying xev.Loop for internal library use only
    /// This method is not part of the public API and may change
    pub fn _getInternalLoop(self: *Self) *xev.Loop {
        assert(@TypeOf(self.*) == Self);
        assert(@TypeOf(self.inner) == xev.Loop);

        const loop_ptr = &self.inner;
        assert(@TypeOf(loop_ptr.*) == xev.Loop);
        return loop_ptr;
    }
};
