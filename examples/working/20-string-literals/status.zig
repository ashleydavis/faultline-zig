// A branch that turns on a string written in this source, reached by a value Faultline reads from
// the condition.

const std = @import("std");

// Whether the response says everything is well. No boundary value of a string equals "OK", so the
// true side is reached by the string Faultline reads from the condition.
pub fn succeeded(status: []const u8) bool {
    if (std.mem.eql(u8, status, "OK")) {
        return true;
    } else {
        return false;
    }
}
