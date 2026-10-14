// A function that writes, with the branch it takes when the write fails. Faultline makes the write
// fail, so no scenario is written for that branch.

const std = @import("std");

// Writes the text and says whether it all went out.
pub fn writeLine(writer: *std.Io.Writer, text: []const u8) bool {
    writer.writeAll(text) catch {
        return false;
    };
    return true;
}
