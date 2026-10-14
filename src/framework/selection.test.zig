const std = @import("std");
const selection = @import("selection.zig");

test "a run that is narrowed to nothing includes everything" {
    const all: selection.Selection = .{};

    try std.testing.expect(!all.isNarrowed());
    try std.testing.expect(all.includesFunction("src/a.zig", "run"));
    try std.testing.expect(all.includesFile("src/a.zig"));
    try std.testing.expect(all.includesScenario("src/a.sim.zig"));
}

test "naming a file includes only the functions in it" {
    const only: selection.Selection = .{ .file = "src/a.zig" };

    try std.testing.expect(only.isNarrowed());
    try std.testing.expect(only.includesFunction("src/a.zig", "run"));
    try std.testing.expect(!only.includesFunction("src/b.zig", "run"));
    try std.testing.expect(only.includesFile("src/a.zig"));
    try std.testing.expect(!only.includesFile("src/b.zig"));
}

test "a leading dot and slash on the named file is ignored" {
    const only: selection.Selection = .{ .file = "./src/a.zig" };

    try std.testing.expect(only.includesFunction("src/a.zig", "run"));
}

test "naming a function includes it by its own name or as Owner.name" {
    const only: selection.Selection = .{ .function = "bump" };

    try std.testing.expect(only.includesFunction("a.zig", "bump"));
    try std.testing.expect(only.includesFunction("a.zig", "Counter.bump"));
    try std.testing.expect(!only.includesFunction("a.zig", "reset"));

    const qualified: selection.Selection = .{ .function = "Counter.bump" };
    try std.testing.expect(qualified.includesFunction("a.zig", "Counter.bump"));
    try std.testing.expect(!qualified.includesFunction("a.zig", "Other.bump"));
}

test "naming both narrows to a function in that file" {
    const only: selection.Selection = .{ .file = "a.zig", .function = "run" };

    try std.testing.expect(only.includesFunction("a.zig", "run"));
    try std.testing.expect(!only.includesFunction("b.zig", "run"));
    try std.testing.expect(!only.includesFunction("a.zig", "other"));
}

test "naming a function leaves scenarios out and naming a file keeps the scenarios beside it" {
    const function: selection.Selection = .{ .function = "run" };
    const file: selection.Selection = .{ .file = "src/a.zig" };

    try std.testing.expect(!function.includesScenario("src/a.sim.zig"));
    try std.testing.expect(file.includesScenario("src/a.sim.zig"));
    try std.testing.expect(!file.includesScenario("src/b.sim.zig"));
}

test "bareName drops the struct a method belongs to" {
    try std.testing.expectEqualStrings("bump", selection.bareName("Counter.bump"));
    try std.testing.expectEqualStrings("run", selection.bareName("run"));
}

test "stemOf drops the extension of a source file or a sim file" {
    try std.testing.expectEqualStrings("src/a", selection.stemOf("src/a.sim.zig"));
    try std.testing.expectEqualStrings("src/a", selection.stemOf("src/a.zig"));
    try std.testing.expectEqualStrings("src/a.txt", selection.stemOf("src/a.txt"));
}
