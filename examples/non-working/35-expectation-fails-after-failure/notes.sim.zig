// An expectation function that holds when every call goes right and does not when a failure is
// injected between the two writes.

const std = @import("std");
const sim = @import("sim");
const notes = @import("notes.zig");

// Either there is no note or its last line has an end.
pub fn aNoteEndsItsLastLine(context: *sim.ExpectationContext) anyerror!void {
    var buffer: [64]u8 = undefined;
    const contents = std.Io.Dir.cwd().readFile(context.io, notes.note_path, &buffer) catch return;
    try context.expect(@src(), contents.len == 0 or contents[contents.len - 1] == '\n', "the last line of the note to end with a newline");
}
