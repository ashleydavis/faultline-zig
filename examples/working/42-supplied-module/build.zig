const std = @import("std");

pub fn build(b: *std.Build) void {
    // A module of the project's own. Registering it with `b.addModule` is what lets Faultline
    // see it: the build step hands every registered module to the program.
    _ = b.addModule("units", .{
        .root_source_file = b.path("units.zig"),
    });

    @import("faultline").addFaultTest(b, .{});
}
