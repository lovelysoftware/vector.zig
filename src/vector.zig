const std = @import("std");
const testing = std.testing;

pub const sift = @import("sift.zig");

test {
    testing.refAllDecls(@This());
}
