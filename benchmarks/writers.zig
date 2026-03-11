const std = @import("std");

pub const NullWriter = struct {
    writer: std.Io.Writer = .{
        .buffer = &.{},
        .vtable = &vtable,
    },

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .sendFile = std.Io.Writer.unimplementedSendFile,
        .flush = std.Io.Writer.noopFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        w.end = 0;
        if (data.len == 0) return 0;
        return std.Io.Writer.countSplat(data, splat);
    }
};
