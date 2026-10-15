const std = @import("std");

// The first line of the settings file at `path`: "missing" when the file cannot be opened and
// "unreadable" when it opens but cannot be read. Only a file that exists can fail to be read, so
// that branch is reached by a scenario that writes the file first.
pub fn firstLine(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        return "missing";
    };
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const text = reader.interface.allocRemaining(allocator, .limited(1024)) catch {
        return "unreadable";
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    return lines.first();
}
