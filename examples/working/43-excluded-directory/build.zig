const std = @import("std");

pub fn build(b: *std.Build) void {
    @import("faultline").addFaultTest(b, .{
        // A benchmark is code, so Faultline would take it for source and ask for its code paths to
        // be covered. It exercises the code under test and is not that code, and nothing in the
        // tree says which is which, so the directory is named here.
        .exclude = &.{"bench"},
    });
}
