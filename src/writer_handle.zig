const std = @import("std");

pub const Handle = struct {
    writer: *std.Io.Writer,

    pub fn init(target: anytype) Handle {
        return .{
            .writer = interface_ptr(target),
        };
    }

    pub fn deinit(self: *Handle) void {
        _ = self;
    }

    pub fn flush(self: *Handle) std.Io.Writer.Error!void {
        try self.writer.flush();
    }

    pub fn ioWriter(self: *Handle) *std.Io.Writer {
        return self.writer;
    }
};

pub fn interface_ptr(writer: anytype) *std.Io.Writer {
    const T = @TypeOf(writer);
    const type_info = @typeInfo(T);

    comptime {
        if (type_info != .pointer) {
            @compileError("Expected a mutable pointer to a std.Io.Writer-backed type.");
        }
        if (type_info.pointer.size != .one) {
            @compileError("Expected a mutable pointer to a std.Io.Writer-backed type.");
        }
        if (type_info.pointer.is_const) {
            @compileError("Expected a mutable pointer to a std.Io.Writer-backed type.");
        }
    }

    const Child = type_info.pointer.child;

    if (comptime Child == std.Io.Writer) {
        return writer;
    }

    if (comptime @hasDecl(Child, "ioWriter")) {
        return writer.ioWriter();
    }

    if (comptime has_writer_field(Child, "interface")) {
        return &writer.interface;
    }

    if (comptime has_writer_field(Child, "writer")) {
        return &writer.writer;
    }

    @compileError("Expected a pointer to std.Io.Writer-backed state.");
}

fn has_writer_field(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasField(T, field_name)) {
        return false;
    }

    return @TypeOf(@field(@as(T, undefined), field_name)) == std.Io.Writer;
}
