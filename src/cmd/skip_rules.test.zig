// Tests for the rules the walk asks of each file and directory.

const std = @import("std");
const rules = @import("skip_rules.zig");

test "reasonForName names the rule that skips a file by its name" {
    try std.testing.expectEqual(rules.Reason.build_script, rules.reasonForName("build.zig").?);
    try std.testing.expectEqual(rules.Reason.build_manifest, rules.reasonForName("build.zig.zon").?);
    try std.testing.expectEqual(rules.Reason.not_zig_file, rules.reasonForName("notes.md").?);
    try std.testing.expectEqual(rules.Reason.sim_test_file, rules.reasonForName("a.sim.test.zig").?);
    try std.testing.expectEqual(rules.Reason.test_file, rules.reasonForName("a.test.zig").?);
    try std.testing.expectEqual(rules.Reason.fuzz_file, rules.reasonForName("fuzz_parser.zig").?);
}

test "reasonForName allows source files and sim files" {
    try std.testing.expect(rules.reasonForName("a.zig") == null);
    try std.testing.expect(rules.reasonForName("a.sim.zig") == null);
    try std.testing.expect(rules.reasonForName("my_fuzz_helper.zig") == null);
}

test "isSimName tells a sim file from a source file and a sim test" {
    try std.testing.expect(rules.isSimName("a.sim.zig"));
    try std.testing.expect(!rules.isSimName("a.zig"));
    try std.testing.expect(!rules.isSimName("a.sim.test.zig"));
}

test "isUnder matches the entry itself, what is below it and the project root and not a name sharing a prefix" {
    try std.testing.expect(rules.isUnder("src", "src"));
    try std.testing.expect(rules.isUnder("src", "src/a.zig"));
    try std.testing.expect(rules.isUnder("src", "src/deep/a.zig"));
    try std.testing.expect(rules.isUnder("", "anything/at/all.zig"));
    try std.testing.expect(!rules.isUnder("src", "srcs/a.zig"));
    try std.testing.expect(!rules.isUnder("src/a.zig", "src"));
}

test "isUnderOneOf is true when any entry covers the path" {
    try std.testing.expect(rules.isUnderOneOf(&.{ "lib", "src" }, "src/a.zig"));
    try std.testing.expect(!rules.isUnderOneOf(&.{ "lib", "src" }, "docs/a.zig"));
    try std.testing.expect(!rules.isUnderOneOf(&.{}, "src/a.zig"));
}

test "trimPath takes off a leading dot slash and trailing slashes and turns a dot into the root" {
    try std.testing.expectEqualStrings("src/a.zig", rules.trimPath("./src/a.zig"));
    try std.testing.expectEqualStrings("src", rules.trimPath("src/"));
    try std.testing.expectEqualStrings("src", rules.trimPath("./src//"));
    try std.testing.expectEqualStrings("", rules.trimPath("."));
    try std.testing.expectEqualStrings("", rules.trimPath("./"));
    try std.testing.expectEqualStrings("src", rules.trimPath("src"));
}

test "ignoredDirectoryNames reads plain names and leaves comments and patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".gitignore",
        .data = "# comment\n\n/zig-out/\n.zig-cache\n*.log\ndocs/build\nvendor\r\n!keep\n",
    });

    const names = try rules.ignoredDirectoryNames(std.testing.allocator, std.testing.io, tmp.dir);
    defer rules.freeNames(std.testing.allocator, names);

    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("zig-out", names[0]);
    try std.testing.expectEqualStrings(".zig-cache", names[1]);
    try std.testing.expectEqualStrings("vendor", names[2]);
}

test "ignoredDirectoryNames returns no names when there is no .gitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const names = try rules.ignoredDirectoryNames(std.testing.allocator, std.testing.io, tmp.dir);
    defer rules.freeNames(std.testing.allocator, names);

    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "isIgnored matches whole names only" {
    try std.testing.expect(rules.isIgnored(&.{ "vendor", "zig-out" }, "vendor"));
    try std.testing.expect(!rules.isIgnored(&.{ "vendor", "zig-out" }, "vendors"));
    try std.testing.expect(!rules.isIgnored(&.{}, "vendor"));
}

test "isWorktreeRoot is true for a .git file and false for a .git directory or none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "linked");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked/.git", .data = "gitdir: elsewhere\n" });
    try tmp.dir.createDirPath(std.testing.io, "plain/.git");
    try tmp.dir.createDirPath(std.testing.io, "empty");

    try std.testing.expect(rules.isWorktreeRoot(std.testing.io, tmp.dir, "linked"));
    try std.testing.expect(!rules.isWorktreeRoot(std.testing.io, tmp.dir, "plain"));
    try std.testing.expect(!rules.isWorktreeRoot(std.testing.io, tmp.dir, "empty"));
}

test "isHarness is true for a file importing the framework however it is laid out" {
    try std.testing.expect(rules.isHarness("const sim = @import(\"sim\");\n"));
    try std.testing.expect(rules.isHarness("const s = @import( \"sim\" );\n"));
    try std.testing.expect(rules.isHarness("pub fn f() void {\n    _ = @import(\"std\");\n    _ = @import(\"sim\");\n}\n"));
}

test "isHarness is false for other imports and for the name inside a string or a comment" {
    try std.testing.expect(!rules.isHarness("const std = @import(\"std\");\n"));
    try std.testing.expect(!rules.isHarness("const text = \"@import(\\\"sim\\\")\";\n"));
    try std.testing.expect(!rules.isHarness("// @import(\"sim\")\nconst a = 1;\n"));
    try std.testing.expect(!rules.isHarness("const a = \"sim\";\n"));
    try std.testing.expect(!rules.isHarness("const a = @import(\"simulation\");\n"));
}

test "parsesAsZig accepts declarations and refuses broken source and a top level that is not declarations" {
    try std.testing.expect(try rules.parsesAsZig(std.testing.allocator, "const a = 1;\npub fn f() void {}\ntest {}\n"));
    try std.testing.expect(try rules.parsesAsZig(std.testing.allocator, ""));
    try std.testing.expect(!try rules.parsesAsZig(std.testing.allocator, "pub fn (((\n"));
    try std.testing.expect(!try rules.parsesAsZig(std.testing.allocator, "\"one\",\n\"two\",\n"));
}

test "isTaken is true only for the reasons that mean the walk took the path" {
    inline for (@typeInfo(rules.Reason).@"enum".fields) |field| {
        const reason: rules.Reason = @enumFromInt(field.value);
        const expected = reason == .taken_source or reason == .taken_sim or reason == .searched_directory;
        try std.testing.expectEqual(expected, reason.isTaken());
    }
}
