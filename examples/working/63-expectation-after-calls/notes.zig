// A function that saves a note in a file. Faultline calls it with its own values and injects a
// failure at every place it can fail, and the expectation function in `notes.sim.zig` is checked
// after every one of those calls.

const std = @import("std");

// The only file this module ever writes.
pub const note_path = "note.txt";

// Writes the text to the note file.
pub fn save(io: std.Io, text: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = note_path, .data = text });
}
