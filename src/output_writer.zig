const std = @import("std");

pub const OutputWriter = union(enum) {
    borrowed: *std.Io.Writer,
    owned_file: OwnedFileWriter,

    const OwnedFileWriter = struct {
        allocator: std.mem.Allocator,
        buffer: []u8,
        file_writer: std.Io.File.Writer,
    };

    pub fn borrowedWriter(writer: *std.Io.Writer) OutputWriter {
        return .{ .borrowed = writer };
    }

    pub fn ownedFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        file: std.Io.File,
        buffer_size: u32,
    ) !OutputWriter {
        std.debug.assert(buffer_size > 0);

        const buffer = try allocator.alloc(u8, @intCast(buffer_size));
        return .{
            .owned_file = .{
                .allocator = allocator,
                .buffer = buffer,
                .file_writer = file.writer(io, buffer),
            },
        };
    }

    pub fn ownedStderr(
        allocator: std.mem.Allocator,
        io: std.Io,
        buffer_size: u32,
    ) !OutputWriter {
        return ownedFile(allocator, io, std.Io.File.stderr(), buffer_size);
    }

    pub fn interface(self: *OutputWriter) *std.Io.Writer {
        return switch (self.*) {
            .borrowed => |writer| writer,
            .owned_file => |*owned| &owned.file_writer.interface,
        };
    }

    pub fn writeAll(self: *OutputWriter, bytes: []const u8) !void {
        try self.interface().writeAll(bytes);
    }

    pub fn flush(self: *OutputWriter) !void {
        try self.interface().flush();
    }

    pub fn deinit(self: *OutputWriter) void {
        switch (self.*) {
            .borrowed => {},
            .owned_file => |*owned| {
                owned.file_writer.interface.flush() catch |err| {
                    std.debug.panic("owned output writer flush failed during deinit: {}", .{err});
                };
                owned.allocator.free(owned.buffer);
            },
        }
        self.* = undefined;
    }
};
