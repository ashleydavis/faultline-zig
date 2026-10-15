// A function that reads a file from a directory it is given. Faultline gives a `std.Io.Dir`
// parameter the simulated current directory, so the read stays inside the simulated filesystem.

const std = @import("std");

// How long the settings file in `dir` is, or zero when there is none.
pub fn settingsLength(io: std.Io, dir: std.Io.Dir) usize {
    const stat = dir.statFile(io, "settings.yaml", .{}) catch {
        return 0;
    };
    return stat.size;
}
