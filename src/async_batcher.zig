const std = @import("std");
const assert = std.debug.assert;
const writer_handle = @import("writer_handle.zig");

pub fn Batcher(
    comptime entry_size: usize,
    comptime queue_size: u32,
    comptime batch_size: u32,
) type {
    comptime {
        assert(entry_size >= 256);
        assert(entry_size <= 65536);
        assert(queue_size > 0);
        assert(batch_size > 0);
    }

    return struct {
        const Self = @This();
        const write_buffer_size: usize = write_buffer_bytes();

        const Entry = struct {
            data: [entry_size]u8 = undefined,
            len: u32 = 0,
        };

        const Queue = struct {
            entries: [queue_size]Entry = undefined,
            head: u32 = 0,
            tail: u32 = 0,
            count: u32 = 0,
            mutex: std.Thread.Mutex = .{},

            fn push(self: *Queue, data: []const u8) !void {
                assert(data.len > 0);
                assert(data.len <= entry_size);
                assert(self.count <= queue_size);

                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.count == queue_size) {
                    return error.QueueFull;
                }

                const tail_index: usize = @intCast(self.tail);
                assert(tail_index < self.entries.len);

                self.entries[tail_index].len = @intCast(data.len);
                @memcpy(self.entries[tail_index].data[0..data.len], data);

                self.tail = advance_index(self.tail, queue_size);
                self.count += 1;

                assert(self.count <= queue_size);
            }

            fn pop_batch(self: *Queue, batch_entries: []Entry) u32 {
                assert(batch_entries.len > 0);
                assert(batch_entries.len <= batch_size);
                assert(self.count <= queue_size);

                self.mutex.lock();
                defer self.mutex.unlock();

                const batch_len_u32: u32 = @intCast(batch_entries.len);
                const pop_count: u32 = @min(self.count, batch_len_u32);

                for (0..pop_count) |index| {
                    const source_index: usize = @intCast(self.head);
                    const target_index: usize = index;
                    assert(source_index < self.entries.len);
                    assert(target_index < batch_entries.len);

                    batch_entries[target_index] = self.entries[source_index];
                    self.head = advance_index(self.head, queue_size);
                }

                self.count -= pop_count;
                assert(self.count <= queue_size);
                return pop_count;
            }

            fn size(self: *Queue) u32 {
                self.mutex.lock();
                defer self.mutex.unlock();

                assert(self.count <= queue_size);
                return self.count;
            }
        };

        pub const State = struct {
            queue: Queue = .{},
            batch_entries: [batch_size]Entry = undefined,
            write_buffer: [write_buffer_size]u8 = undefined,
        };

        pub const Metrics = struct {
            flush_count: u64,
            logs_dropped: u64,
            logs_written: u64,
            queue_size: u32,
            write_failures: u64,
        };

        writer: writer_handle.Handle,
        writer_mutex: std.Thread.Mutex = .{},
        state: *State,
        logs_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        logs_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        flush_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        write_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        pub fn init(output_writer: anytype, state: *State) Self {
            assert(@TypeOf(state.*) == State);
            assert(state.queue.count == 0);

            return .{
                .writer = writer_handle.Handle.init(output_writer),
                .state = state,
            };
        }

        pub fn deinit(self: *Self) void {
            self.flush_pending();
            self.flush_writer() catch {
                _ = self.write_failures.fetchAdd(1, .monotonic);
            };
            self.writer.deinit();
        }

        pub fn enqueue(self: *Self, data: []const u8) void {
            assert(data.len > 0);
            assert(data.len <= entry_size);

            self.state.queue.push(data) catch {
                _ = self.logs_dropped.fetchAdd(1, .monotonic);
                return;
            };
        }

        pub fn flush(self: *Self) std.Io.Writer.Error!void {
            self.flush_pending();
            try self.flush_writer();
        }

        pub fn drain(self: *Self) void {
            self.flush_pending();
        }

        pub fn flush_pending(self: *Self) void {
            while (true) {
                const pop_count = self.state.queue.pop_batch(&self.state.batch_entries);
                if (pop_count == 0) {
                    break;
                }

                self.write_batch(self.state.batch_entries[0..pop_count]);
                _ = self.flush_count.fetchAdd(1, .monotonic);
            }
        }

        pub fn metrics(self: *const Self) Metrics {
            return .{
                .flush_count = self.flush_count.load(.monotonic),
                .logs_dropped = self.logs_dropped.load(.monotonic),
                .logs_written = self.logs_written.load(.monotonic),
                .queue_size = self.state.queue.size(),
                .write_failures = self.write_failures.load(.monotonic),
            };
        }

        fn flush_writer(self: *Self) std.Io.Writer.Error!void {
            self.writer_mutex.lock();
            defer self.writer_mutex.unlock();

            try self.writer.flush();
        }

        fn write_batch(self: *Self, batch_entries: []const Entry) void {
            assert(batch_entries.len > 0);
            assert(batch_entries.len <= batch_size);

            var batch_writer = std.Io.Writer.fixed(&self.state.write_buffer);
            append_entries(&batch_writer, batch_entries) catch unreachable;

            self.writer_mutex.lock();
            defer self.writer_mutex.unlock();

            const batch_bytes = batch_writer.buffered();
            assert(batch_bytes.len > 0);
            assert(batch_bytes.len <= self.state.write_buffer.len);

            self.writer.ioWriter().writeAll(batch_bytes) catch {
                _ = self.logs_dropped.fetchAdd(@intCast(batch_entries.len), .monotonic);
                _ = self.write_failures.fetchAdd(1, .monotonic);
                return;
            };

            _ = self.logs_written.fetchAdd(@intCast(batch_entries.len), .monotonic);
        }

        fn append_entries(writer: *std.Io.Writer, batch_entries: []const Entry) !void {
            for (batch_entries) |entry| {
                const entry_len: usize = entry.len;
                assert(entry_len > 0);
                assert(entry_len <= entry_size);
                try writer.writeAll(entry.data[0..entry_len]);
            }
        }

        fn write_buffer_bytes() usize {
            const total_bytes = @as(u64, batch_size) * @as(u64, entry_size);
            assert(total_bytes <= std.math.maxInt(usize));
            return @intCast(total_bytes);
        }

        fn advance_index(index: u32, capacity: u32) u32 {
            assert(capacity > 0);
            assert(index < capacity);

            const next_index = index + 1;
            if (next_index < capacity) {
                return next_index;
            }

            return 0;
        }
    };
}
