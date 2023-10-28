pub const KeyValue = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        String: []const u8,
        Int: i64,
        Float: f64,
    };
};
