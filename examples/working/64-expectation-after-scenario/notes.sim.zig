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

// A scenario: it saves a note and says what must be true afterwards. `onlyTheNoteExists` above runs
// after it too, because it is in the same sim file.
pub fn savingLeavesTheNote(context: *sim.ScenarioContext) anyerror!void {
    try notes.save(context.io, "hello");

    var buffer: [16]u8 = undefined;
    const contents = try std.Io.Dir.cwd().readFile(context.io, notes.note_path, &buffer);
    try context.expect(@src(), std.mem.eql(u8, contents, "hello"), "the note to hold what was saved");
}
