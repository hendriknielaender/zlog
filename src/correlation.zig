const std = @import("std");
const assert = std.debug.assert;
const trace_mod = @import("trace.zig");
const config = @import("config.zig");

pub const Span = struct {
    trace_context: trace_mod.TraceContext,
    name: []const u8,
    start_time: i128,
    thread_id: u32,
    
    id: u64,
    parent_id: ?u64,
    task_id: u64,

    pub fn init(span_name: []const u8, parent_span_bytes: ?[8]u8, trace_ctx: trace_mod.TraceContext) Span {
        assert(span_name.len > 0);
        assert(span_name.len < 256);
        assert(!trace_mod.is_all_zero_id(trace_ctx.trace_id[0..]));
        assert(parent_span_bytes == null or !trace_mod.is_all_zero_id(parent_span_bytes.?[0..]));
        
        const span_trace_context = trace_ctx.createChild(trace_ctx.trace_flags.sampled);
        const timestamp_ns = std.time.nanoTimestamp();
        const thread_id_current = std.Thread.getCurrentId();
        
        const span_id_legacy = std.mem.readInt(u64, &span_trace_context.parent_id, .big);
        const parent_id_legacy = if (parent_span_bytes) |pb| std.mem.readInt(u64, &pb, .big) else null;
        const task_id_legacy = trace_mod.extract_short_from_trace_id(span_trace_context.trace_id);
        
        const span_result = Span{
            .trace_context = span_trace_context,
            .name = span_name,
            .start_time = timestamp_ns,
            .thread_id = @intCast(thread_id_current),
            .id = span_id_legacy,
            .parent_id = parent_id_legacy,
            .task_id = task_id_legacy,
        };
        
        assert(!trace_mod.is_all_zero_id(span_result.trace_context.parent_id[0..]));
        assert(span_result.start_time > 0);
        assert(span_result.thread_id > 0);
        return span_result;
    }
    
    pub fn initLegacy(span_name: []const u8, parent_span_id: ?u64, task_context_id: u64) Span {
        assert(span_name.len > 0);
        assert(span_name.len < 256);
        assert(task_context_id >= 1);
        assert(parent_span_id == null or parent_span_id.? >= 1);
        
        const trace_id_expanded = trace_mod.expand_short_to_trace_id(task_context_id);
        const parent_id_bytes = trace_mod.generate_span_id();
        const trace_ctx = trace_mod.TraceContext{
            .version = 0x00,
            .trace_id = trace_id_expanded,
            .parent_id = parent_id_bytes,
            .trace_flags = trace_mod.TraceFlags.sampled_only(false),
        };
        
        var parent_span_bytes: ?[8]u8 = null;
        if (parent_span_id) |pid| {
            var pb: [8]u8 = undefined;
            std.mem.writeInt(u64, &pb, pid, .big);
            parent_span_bytes = pb;
        }
        
        return init(span_name, parent_span_bytes, trace_ctx);
    }
    
    pub fn getSpanIdBytes(self: *const Span) [8]u8 {
        return self.trace_context.parent_id;
    }
};

pub const TaskContext = struct {
    trace_context: trace_mod.TraceContext,
    span_stack: std.BoundedArray([8]u8, 32),
    
    id: u64,
    parent_id: ?u64,
    
    pub fn init(parent_context_id: ?u64) TaskContext {
        assert(parent_context_id == null or parent_context_id.? >= 1);
        
        const trace_ctx = trace_mod.TraceContext.init(false);
        const span_stack_empty = std.BoundedArray([8]u8, 32).init(0) catch unreachable;
        
        const legacy_task_id = trace_mod.extract_short_from_trace_id(trace_ctx.trace_id);
        const legacy_parent_id = if (parent_context_id) |pid| pid else null;
        
        const context_result = TaskContext{
            .trace_context = trace_ctx,
            .span_stack = span_stack_empty,
            .id = legacy_task_id,
            .parent_id = legacy_parent_id,
        };
        
        assert(context_result.id >= 1 or !trace_mod.is_all_zero_id(trace_ctx.trace_id[0..8]));
        assert(context_result.span_stack.len == 0);
        assert(context_result.span_stack.capacity() == 32);
        return context_result;
    }
    
    pub fn fromTraceContext(trace_ctx: trace_mod.TraceContext) TaskContext {
        assert(trace_ctx.version == 0x00);
        assert(!trace_mod.is_all_zero_id(trace_ctx.trace_id[0..]));
        
        const span_stack_empty = std.BoundedArray([8]u8, 32).init(0) catch unreachable;
        const legacy_task_id = trace_mod.extract_short_from_trace_id(trace_ctx.trace_id);
        
        const context_result = TaskContext{
            .trace_context = trace_ctx,
            .span_stack = span_stack_empty,
            .id = legacy_task_id,
            .parent_id = null,
        };
        
        assert(!trace_mod.is_all_zero_id(context_result.trace_context.trace_id[0..]));
        return context_result;
    }
    
    pub fn pushSpan(self: *TaskContext, span_id_bytes: [8]u8) !void {
        assert(!trace_mod.is_all_zero_id(self.trace_context.trace_id[0..]));
        assert(!trace_mod.is_all_zero_id(span_id_bytes[0..]));
        assert(self.span_stack.len < self.span_stack.capacity());
        
        const initial_stack_len = self.span_stack.len;
        try self.span_stack.append(span_id_bytes);
        
        assert(self.span_stack.len == initial_stack_len + 1);
        assert(std.mem.eql(u8, &self.span_stack.get(self.span_stack.len - 1), &span_id_bytes));
    }
    
    pub fn pushSpanLegacy(self: *TaskContext, span_context_id: u64) !void {
        assert(span_context_id >= 1);
        
        var span_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &span_bytes, span_context_id, .big);
        try self.pushSpan(span_bytes);
    }
    
    pub fn popSpan(self: *TaskContext) ?[8]u8 {
        assert(!trace_mod.is_all_zero_id(self.trace_context.trace_id[0..]));
        
        if (self.span_stack.len == 0) return null;
        
        const initial_stack_len = self.span_stack.len;
        const popped_span_bytes = self.span_stack.pop();
        
        assert(self.span_stack.len == initial_stack_len - 1);
        assert(!trace_mod.is_all_zero_id(popped_span_bytes[0..]));
        return popped_span_bytes;
    }
    
    pub fn popSpanLegacy(self: *TaskContext) ?u64 {
        const span_bytes = self.popSpan() orelse return null;
        return std.mem.readInt(u64, &span_bytes, .big);
    }
    
    pub fn currentSpan(self: *const TaskContext) ?[8]u8 {
        assert(!trace_mod.is_all_zero_id(self.trace_context.trace_id[0..]));
        
        if (self.span_stack.len == 0) return null;
        
        const current_span_bytes = self.span_stack.get(self.span_stack.len - 1);
        assert(!trace_mod.is_all_zero_id(current_span_bytes[0..]));
        return current_span_bytes;
    }
    
    pub fn currentSpanLegacy(self: *const TaskContext) ?u64 {
        const span_bytes = self.currentSpan() orelse return null;
        return std.mem.readInt(u64, &span_bytes, .big);
    }
    
    pub fn createChildTraceContext(self: *const TaskContext, sampling_decision: bool) trace_mod.TraceContext {
        assert(!trace_mod.is_all_zero_id(self.trace_context.trace_id[0..]));
        return self.trace_context.createChild(sampling_decision);
    }
};

pub const CorrelationContext = packed struct {
    task_id: u32,
    span_id: u32,
    thread_id: u16,
    level: config.Level,
    
    pub fn fromTraceContext(trace_ctx: trace_mod.TraceContext, span_bytes_optional: ?[8]u8, level_value: config.Level) CorrelationContext {
        assert(!trace_mod.is_all_zero_id(trace_ctx.trace_id[0..]));
        assert(@intFromEnum(level_value) <= @intFromEnum(config.Level.fatal));
        
        const task_id_legacy = trace_mod.extract_short_from_trace_id(trace_ctx.trace_id);
        const task_id_truncated = @as(u32, @truncate(task_id_legacy));
        
        const span_bytes = span_bytes_optional orelse trace_ctx.parent_id;
        const span_id_legacy = std.mem.readInt(u64, &span_bytes, .big);
        const span_id_truncated = @as(u32, @truncate(span_id_legacy));
        
        const thread_id_current = std.Thread.getCurrentId();
        const thread_id_truncated = @as(u16, @truncate(thread_id_current));
        
        assert(task_id_truncated >= 1 or !trace_mod.is_all_zero_id(trace_ctx.trace_id[0..8]));
        assert(thread_id_truncated > 0);
        
        return CorrelationContext{
            .task_id = task_id_truncated,
            .span_id = span_id_truncated,
            .thread_id = thread_id_truncated,
            .level = level_value,
        };
    }
    
    pub fn fromIds(task_id_u64: u64, span_id_optional: ?u64, level_value: config.Level) CorrelationContext {
        assert(task_id_u64 >= 1);
        assert(@intFromEnum(level_value) <= @intFromEnum(config.Level.fatal));
        
        const task_id_truncated = @as(u32, @truncate(task_id_u64));
        const span_id_value = span_id_optional orelse 0;
        const span_id_truncated = @as(u32, @truncate(span_id_value));
        const thread_id_current = std.Thread.getCurrentId();
        const thread_id_truncated = @as(u16, @truncate(thread_id_current));
        
        assert(task_id_truncated >= 1);
        assert(thread_id_truncated > 0);
        
        return CorrelationContext{
            .task_id = task_id_truncated,
            .span_id = span_id_truncated,
            .thread_id = thread_id_truncated,
            .level = level_value,
        };
    }
};

var task_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
var span_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

threadlocal var current_task_context: ?*TaskContext = null;

pub fn generate_task_id() u64 {
    const id_generated = task_id_counter.fetchAdd(1, .monotonic);
    assert(id_generated >= 1);
    assert(id_generated < std.math.maxInt(u64) - 1000);
    return id_generated;
}

pub fn getCurrentTaskContext() TaskContext {
    if (current_task_context) |context_ptr| {
        assert(context_ptr.id >= 1);
        assert(context_ptr.span_stack.capacity() == 32);
        return context_ptr.*;
    }
    const default_context = TaskContext.init(null);
    assert(default_context.id >= 1);
    assert(default_context.span_stack.len == 0);
    return default_context;
}

pub fn setTaskContext(context_ptr: *TaskContext) void {
    assert(context_ptr.id >= 1);
    assert(context_ptr.span_stack.capacity() == 32);
    assert(@TypeOf(context_ptr.*) == TaskContext);
    current_task_context = context_ptr;
}

pub fn createChildTaskContext() TaskContext {
    const parent_context = getCurrentTaskContext();
    assert(parent_context.id >= 1);
    const child_context = TaskContext.init(parent_context.id);
    assert(child_context.id >= 1);
    assert(child_context.parent_id.? == parent_context.id);
    return child_context;
}