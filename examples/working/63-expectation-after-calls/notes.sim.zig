// An expectation function: something that must be true after every call of a function in
// `notes.zig`, whatever values the call was made with and whatever failure was injected into it.

const std = @import("std");
const sim = @import("sim");
const notes = @import("notes.zig");

// The note file is the only file the module may leave behind.
pub fn onlyTheNoteExists(context: *sim.ExpectationContext) anyerror!void {
    var directory = try std.Io.Dir.cwd().openDir(context.io, ".", .{ .iterate = true });
    defer directory.close(context.io);

    var names: usize = 0;
    var others: usize = 0;
    var entries = directory.iterate();
    while (try entries.next(context.io)) |entry| {
        names += 1;
        if (!std.mem.eql(u8, entry.name, notes.note_path)) {
            others += 1;
        }
    }
    try context.expect(@src(), others == 0, "no file other than the note to be left behind");
}
