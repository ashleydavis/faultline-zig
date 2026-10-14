// Tests for the walk: what it takes, what it skips and why and how `include` and `exclude` pick
// files and directories. Each builds its own tree in a temporary directory.

const std = @import("std");
const walk = @import("walk.zig");

// Source that parses and declares something to call.
const valid_source = "pub fn add(a: u32) u32 {\n    return a + 1;\n}\n";

// Writes a file in a fixture tree, making the directories above it.
fn write(dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(std.testing.io, parent);
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = text });
}

// Fails unless the files taken have exactly these paths, in this order.
fn expectPaths(files: []const walk.Found, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, files.len);
    for (expected, files) |want, got| {
        try std.testing.expectEqualStrings(want, got.path);
    }
}

// The reason recorded for a path, or null when the walk did not record it.
fn reasonFor(records: []const walk.Record, path: []const u8) ?walk.Reason {
    for (records) |record| {
        if (std.mem.eql(u8, record.path, path)) {
            return record.reason;
        }
    }
    return null;
}

test "collect takes source files and sim files and gives each its kind in path order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/b.zig", valid_source);
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/a.sim.zig", "const sim = @import(\"sim\");\npub fn make() u32 {\n    return 1;\n}\n");

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{ "src/a.sim.zig", "src/a.zig", "src/b.zig" });
    try std.testing.expectEqual(walk.Kind.sim, files[0].kind);
    try std.testing.expectEqual(walk.Kind.source, files[1].kind);
    try std.testing.expectEqual(walk.Kind.source, files[2].kind);
}

test "collect pairs a sim file with the source file beside it and leaves a lone file unpaired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/a.sim.zig", valid_source);
    try write(tmp.dir, "src/b.zig", valid_source);
    try write(tmp.dir, "other/c.sim.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{ "other/c.sim.zig", "src/a.sim.zig", "src/a.zig", "src/b.zig" });
    try std.testing.expect(files[0].partner == null);
    try std.testing.expectEqualStrings("src/a.zig", files[1].partner.?);
    try std.testing.expectEqualStrings("src/a.sim.zig", files[2].partner.?);
    try std.testing.expect(files[3].partner == null);
}

test "collect does not pair a sim file with a source file the selection left out" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/a.sim.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{"src/a.sim.zig"} });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{"src/a.sim.zig"});
    try std.testing.expect(files[0].partner == null);
}

test "collect skips a directory whose name starts with a dot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, ".cache/b.zig", valid_source);

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.dot_directory, reasonFor(records, ".cache").?);
    try std.testing.expectEqual(walk.Reason.taken_source, reasonFor(records, "src/a.zig").?);
    try std.testing.expect(reasonFor(records, ".cache/b.zig") == null);
}

test "collect skips a directory whose name is listed in .gitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, ".gitignore", "# a comment\nvendor/\n*.log\nnested/pattern\n");
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "vendor/b.zig", valid_source);
    try write(tmp.dir, "src/vendor/c.zig", valid_source);

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.ignored_directory, reasonFor(records, "vendor").?);
    try std.testing.expectEqual(walk.Reason.ignored_directory, reasonFor(records, "src/vendor").?);
    try std.testing.expectEqual(walk.Reason.taken_source, reasonFor(records, "src/a.zig").?);
}

test "collect skips the root of a linked git worktree and walks a directory with a real .git directory name inside" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "linked/.git", "gitdir: ../.git/worktrees/linked\n");
    try write(tmp.dir, "linked/b.zig", valid_source);
    try write(tmp.dir, "plain/.git/config", "x\n");
    try write(tmp.dir, "plain/c.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeFiles(std.testing.allocator, files);
    try expectPaths(files, &.{ "plain/c.zig", "src/a.zig" });

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);
    try std.testing.expectEqual(walk.Reason.worktree_root, reasonFor(records, "linked").?);
}

test "collect skips files that are not Zig, tests, sim tests, build files and fuzz entry points" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/notes.md", "text\n");
    try write(tmp.dir, "src/a.test.zig", valid_source);
    try write(tmp.dir, "src/a.sim.test.zig", valid_source);
    try write(tmp.dir, "build.zig", valid_source);
    try write(tmp.dir, "build.zig.zon", ".{}\n");
    try write(tmp.dir, "src/fuzz_parser.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeFiles(std.testing.allocator, files);
    try expectPaths(files, &.{"src/a.zig"});

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);
    try std.testing.expectEqual(walk.Reason.test_file, reasonFor(records, "src/a.test.zig").?);
    try std.testing.expectEqual(walk.Reason.sim_test_file, reasonFor(records, "src/a.sim.test.zig").?);
    try std.testing.expectEqual(walk.Reason.build_script, reasonFor(records, "build.zig").?);
    try std.testing.expectEqual(walk.Reason.build_manifest, reasonFor(records, "build.zig.zon").?);
    try std.testing.expectEqual(walk.Reason.fuzz_file, reasonFor(records, "src/fuzz_parser.zig").?);
    // A document is not listed: naming every one in a project would bury the files that matter.
    try std.testing.expect(reasonFor(records, "src/notes.md") == null);
}

test "collect skips a file that imports the framework unless it is named as a sim file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/harness.zig", "const sim = @import(\"sim\");\npub fn run() void {}\n");
    try write(tmp.dir, "src/quoted.zig", "const text = \"@import(\\\"sim\\\")\";\npub fn run() void {}\n");

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.imports_framework, reasonFor(records, "src/harness.zig").?);
    // The same text inside a string literal is not an import.
    try std.testing.expectEqual(walk.Reason.taken_source, reasonFor(records, "src/quoted.zig").?);
}

test "collect skips a file that is not valid Zig and one whose top level is not declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/broken.zig", "pub fn (((\n");
    try write(tmp.dir, "src/tuple.zig", "\"one\",\n\"two\",\n");

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.does_not_parse, reasonFor(records, "src/broken.zig").?);
    try std.testing.expectEqual(walk.Reason.does_not_parse, reasonFor(records, "src/tuple.zig").?);
}

test "include with a file takes only that file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/b.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{"src/a.zig"} });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{"src/a.zig"});
}

test "include with a directory takes the files below it and nothing else" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/deep/b.zig", valid_source);
    try write(tmp.dir, "lib/c.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{"src"} });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{ "src/a.zig", "src/deep/b.zig" });
}

test "include takes a file and a directory together and accepts a leading dot slash and a trailing slash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "lib/c.zig", valid_source);
    try write(tmp.dir, "lib/d.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{ "./src/a.zig", "lib/" } });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{ "lib/c.zig", "lib/d.zig", "src/a.zig" });
}

test "include naming a directory and a file inside it takes the file once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{ "src", "src/a.zig" } });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{"src/a.zig"});
}

test "an empty include searches the whole project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "lib/c.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{} });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{ "lib/c.zig", "src/a.zig" });
}

test "include naming a path that is not in the project is reported as not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{ "src/a.zig", "missing" } });
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.not_found, reasonFor(records, "missing").?);
    try std.testing.expectEqual(walk.Reason.taken_source, reasonFor(records, "src/a.zig").?);
}

test "include naming a directory with a dot or an ignored name searches it because it was asked for" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, ".gitignore", "vendor\n");
    try write(tmp.dir, ".hidden/a.zig", valid_source);
    try write(tmp.dir, "vendor/b.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{ ".hidden", "vendor" } });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{ ".hidden/a.zig", "vendor/b.zig" });
}

test "include naming a file the rules skip reports why instead of taking it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.test.zig", valid_source);
    try write(tmp.dir, "README.md", "text\n");

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{ "src/a.test.zig", "README.md" } });
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.test_file, reasonFor(records, "src/a.test.zig").?);
    try std.testing.expectEqual(walk.Reason.not_zig_file, reasonFor(records, "README.md").?);
}

test "exclude with a file leaves that file out" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/b.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .exclude = &.{"src/b.zig"} });
    defer walk.freeFiles(std.testing.allocator, files);
    try expectPaths(files, &.{"src/a.zig"});

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{ .exclude = &.{"src/b.zig"} });
    defer walk.freeRecords(std.testing.allocator, records);
    try std.testing.expectEqual(walk.Reason.excluded, reasonFor(records, "src/b.zig").?);
}

test "exclude with a directory leaves everything below it out and does not search it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "bench/b.zig", valid_source);
    try write(tmp.dir, "bench/deep/c.zig", valid_source);
    try write(tmp.dir, "benchmark/d.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .exclude = &.{"bench/"} });
    defer walk.freeFiles(std.testing.allocator, files);
    // A directory that only starts with the same letters is a different directory.
    try expectPaths(files, &.{ "benchmark/d.zig", "src/a.zig" });

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{ .exclude = &.{"bench"} });
    defer walk.freeRecords(std.testing.allocator, records);
    try std.testing.expectEqual(walk.Reason.excluded, reasonFor(records, "bench").?);
    try std.testing.expect(reasonFor(records, "bench/b.zig") == null);
}

test "exclude wins over include" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/skip/b.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{"src"}, .exclude = &.{"src/skip"} });
    defer walk.freeFiles(std.testing.allocator, files);

    try expectPaths(files, &.{"src/a.zig"});
}

test "exclude naming a named file reports it as excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{ .include = &.{"src/a.zig"}, .exclude = &.{"src/a.zig"} });
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.excluded, reasonFor(records, "src/a.zig").?);
}

test "report records a searched directory, taken source and sim files and every reason has a sentence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/a.sim.zig", valid_source);

    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);

    try std.testing.expectEqual(walk.Reason.searched_directory, reasonFor(records, ".").?);
    try std.testing.expectEqual(walk.Reason.searched_directory, reasonFor(records, "src").?);
    try std.testing.expectEqual(walk.Reason.taken_source, reasonFor(records, "src/a.zig").?);
    try std.testing.expectEqual(walk.Reason.taken_sim, reasonFor(records, "src/a.sim.zig").?);
    for (records) |record| {
        if (std.mem.eql(u8, record.path, "src")) {
            try std.testing.expect(record.is_directory);
        }
        if (std.mem.eql(u8, record.path, "src/a.zig")) {
            try std.testing.expect(!record.is_directory);
        }
    }

    inline for (@typeInfo(walk.Reason).@"enum".fields) |field| {
        const reason: walk.Reason = @enumFromInt(field.value);
        const sentence = reason.sentence();
        try std.testing.expect(sentence.len > 0);
        try std.testing.expect(std.ascii.isUpper(sentence[0]));
        try std.testing.expectEqual(@as(u8, '.'), sentence[sentence.len - 1]);
    }
}

test "collect and report agree because they come from one walk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/a.zig", valid_source);
    try write(tmp.dir, "src/b.test.zig", valid_source);
    try write(tmp.dir, "src/c.zig", valid_source);

    const files = try walk.collect(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeFiles(std.testing.allocator, files);
    const records = try walk.report(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer walk.freeRecords(std.testing.allocator, records);

    var taken: usize = 0;
    for (records) |record| {
        if (!record.is_directory and record.reason.isTaken()) {
            taken += 1;
            var found = false;
            for (files) |file| {
                if (std.mem.eql(u8, file.path, record.path)) {
                    found = true;
                }
            }
            try std.testing.expect(found);
        }
    }
    try std.testing.expectEqual(files.len, taken);
}
