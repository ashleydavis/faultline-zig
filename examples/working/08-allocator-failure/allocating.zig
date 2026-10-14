// A function that allocates, with the branch it takes when the allocator gives out. Faultline makes
// the allocation fail, so no scenario is written for that branch.

const std = @import("std");

// Copies the text, or returns an empty string when there was no room for it.
pub fn copyOrEmpty(allocator: std.mem.Allocator, text: []const u8) []const u8 {
    const copied = allocator.dupe(u8, text) catch {
        return "";
    };
    return copied;
}
