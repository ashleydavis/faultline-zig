// Scenarios that make a file for the function to read. A call Faultline makes on its own meets an
// empty filesystem, so the branches that need a file that exists are reached from here.

const std = @import("std");
const sim = @import("sim");
const settings = @import("settings.zig");

// Makes a file in the in-memory filesystem and returns after closing it.
fn writeFile(context: *sim.ScenarioContext, path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(context.io, path, .{});
    defer file.close(context.io);

    var writer = file.writer(context.io, &.{});
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

// A file with a setting in it is read.
pub fn runFileReadsScenario(context: *sim.ScenarioContext) anyerror!void {
    try writeFile(context, settings.settings_path, "loud");

    var into: [16]u8 = undefined;
    const read = settings.setting(context.io, settings.settings_path, &into);

    try context.expect(@src(), std.mem.eql(u8, read, "loud"), "the setting in the file to be read");
}

// A file with nothing in it gives the fallback.
pub fn runEmptyFileScenario(context: *sim.ScenarioContext) anyerror!void {
    try writeFile(context, "empty.txt", "");

    var into: [16]u8 = undefined;
    const read = settings.setting(context.io, "empty.txt", &into);

    try context.expect(@src(), std.mem.eql(u8, read, settings.fallback), "an empty file to give the fallback");
}
