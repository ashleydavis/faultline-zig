// A function that grows a list it is given. Faultline builds the list from its elements with the
// allocator it gives the call, so growing it is what a real caller's list would do.

const std = @import("std");

// Appends `text` to `out` in double quotes.
pub fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    try out.append(allocator, '"');
    try out.appendSlice(allocator, text);
    try out.append(allocator, '"');
}
