const std = @import("std");
const testing = std.testing;

test {
    testing.refAllDecls(@This());
}
