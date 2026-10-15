const std = @import("std");
const sim = @import("sim");
const settings = @import("settings.zig");

// Writes a settings file and reads its first line. Faultline runs it again with each failure the
// run can meet, so the branch for a file that opens but cannot be read is exercised too.
pub fn readsTheSettingsFileScenario(context: *sim.ScenarioContext) anyerror!void {
    try std.Io.Dir.cwd().createDirPath(context.io, "/home/settings");
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = "/home/settings/theme.txt",
        .data = "dark\nlarge\n",
    });
    const line = try settings.firstLine(context.io, context.allocator, "/home/settings/theme.txt");
    try context.expect(@src(), std.mem.eql(u8, line, "dark"), "the first line of the file to be read");
}
