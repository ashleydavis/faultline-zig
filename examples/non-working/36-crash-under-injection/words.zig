// A function that crashes only when an allocation fails.

const std = @import("std");

// The first word of the text, in memory of its own. The `catch unreachable` says an allocation
// cannot fail, and Faultline injects the failure that proves it can.
pub fn firstWord(allocator: std.mem.Allocator, text: []const u8) []u8 {
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    return allocator.dupe(u8, text[0..end]) catch unreachable;
}
