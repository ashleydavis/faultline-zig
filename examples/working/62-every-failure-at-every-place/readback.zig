// A function with an error branch for each thing that can go wrong: writing, then opening and
// reading back.

const std = @import("std");

// What happened to a save.
pub const Outcome = enum { saved, could_not_write, file_vanished, could_not_read };

// Saves the text in a file and reads it back. Faultline injects every failure of each step at its
// place, so every `catch` here is exercised without a scenario.
pub fn saveAndReadBack(io: std.Io, text: []const u8) Outcome {
    const directory = std.Io.Dir.cwd();
    directory.writeFile(io, .{ .sub_path = "saved.txt", .data = text }) catch {
        return .could_not_write;
    };
    var buffer: [16]u8 = undefined;
    _ = directory.readFile(io, "saved.txt", &buffer) catch |err| switch (err) {
        error.FileNotFound => return .file_vanished,
        else => return .could_not_read,
    };
    return .saved;
}
