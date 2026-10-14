// A function that writes a note in two steps.

const std = @import("std");

// The only file this module writes.
pub const note_path = "note.txt";

// Writes the text and then a newline to end the line. That is a mistake: a failure between the two
// writes leaves a note whose last line has no end.
pub fn save(io: std.Io, text: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, note_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, text);
    try file.writeStreamingAll(io, "\n");
}
