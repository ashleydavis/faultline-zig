const std = @import("std");

pub fn build(b: *std.Build) void {
    @import("faultline").addFaultTest(b, .{
        // The code is under lib/text. Naming it turns off Faultline's own search for Zig files, so
        // only what is named here is fault tested.
        .include = &.{"lib/text"},
    });
}
