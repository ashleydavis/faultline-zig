// A function that reads a file. The filesystem is held in memory, so the function never touches the
// machine and leaves nothing behind.

const std = @import("std");

// What a setting says when the file will not give it up.
pub const fallback = "quiet";

// The file this module is written in terms of.
pub const settings_path = "settings.txt";

// Reads the whole file, or returns `fallback` when it cannot. Three branches: no such file, a file
// that opens and will not read, and a file with nothing in it.
pub fn setting(io: std.Io, path: []const u8, into: []u8) []const u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        return fallback;
    };
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const read = reader.interface.readSliceShort(into) catch {
        return fallback;
    };
    if (read == 0) {
        return fallback;
    }
    return into[0..read];
}
