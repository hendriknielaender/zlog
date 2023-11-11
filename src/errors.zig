const std = @import("std");

pub const ZlogError = error{
    HandlerFailure,
    InvalidLevel,
    // ... other relevant errors ...
};
