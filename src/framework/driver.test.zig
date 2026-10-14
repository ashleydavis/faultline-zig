const std = @import("std");
const driver = @import("driver.zig");
const project = @import("project.zig");
const coverage = @import("coverage.zig");

const Alpha = struct {
    pub fn double(x: u32) u32 {
        return x *% 2;
    }
};

const files = struct {
    pub const sources = .{.{ .path = "alpha.zig", .namespace = Alpha }};
    pub const simulations = .{};
};

const Subject = project.Project(files);

// The driver is exercised end to end by the smoke tests, which build a real project and run it
// under kcov. This test makes sure the whole of it compiles for a project, which Zig only checks
// when something refers to the function.
test "the main for a project can be built" {
    const main = driver.mainFor(Subject);

    try std.testing.expect(@TypeOf(main) == fn (std.process.Init.Minimal) u8);
}

test "the helpers that find a function among the checklists agree on bare names" {
    const source =
        \\pub fn run() void {
        \\    if (true) {
        \\        return;
        \\    }
        \\}
        \\
    ;
    const checklists = try coverage.buildFile(std.testing.allocator, "a.zig", source);
    defer coverage.freeChecklists(std.testing.allocator, checklists);

    try std.testing.expect(driver.hasUntickedPath(checklists, "a.zig", "run"));
    try std.testing.expect(!driver.hasUntickedPath(checklists, "b.zig", "run"));
    try std.testing.expect(!driver.hasUntickedPath(checklists, "a.zig", "other"));
    try std.testing.expect(driver.containsName(&.{ "Counter.run", "other" }, "run"));
    try std.testing.expect(!driver.containsName(&.{"other"}, "run"));
    try std.testing.expectEqualStrings("", driver.plural(1));
    try std.testing.expectEqualStrings("s", driver.plural(2));
}

const worker = @import("worker.zig");

test "standingOf finds the standing of a function by file and bare name" {
    var standings = [_]driver.Standing{.{ .calls = 7, .was_called = true }};

    const found = driver.standingOf(Subject, &standings, "alpha.zig", "double");

    try std.testing.expectEqual(@as(usize, 7), found.?.calls);
    try std.testing.expect(driver.standingOf(Subject, &standings, "alpha.zig", "missing") == null);
    try std.testing.expect(driver.standingOf(Subject, &standings, "beta.zig", "double") == null);
}

test "subjectName is the name of the function a failure is about and empty for a project without scenarios" {
    const failure: worker.Failure = .{ .is_scenario = false, .index = 0, .kind = .crash, .token = "t" };
    const scenario_failure: worker.Failure = .{ .is_scenario = true, .index = 0, .kind = .crash, .token = "t" };

    try std.testing.expectEqualStrings("double", driver.subjectName(Subject, failure));
    try std.testing.expectEqualStrings("", driver.subjectName(Subject, scenario_failure));
}

test "firstLineOf is the line of the first code path of a function" {
    const source =
        \\
        \\pub fn run() void {
        \\    if (true) {
        \\        return;
        \\    }
        \\}
        \\
    ;
    const checklists = try coverage.buildFile(std.testing.allocator, "a.zig", source);
    defer coverage.freeChecklists(std.testing.allocator, checklists);

    try std.testing.expectEqual(@as(u32, 2), driver.firstLineOf(checklists, "a.zig", "run"));
    try std.testing.expectEqual(@as(u32, 0), driver.firstLineOf(checklists, "a.zig", "missing"));
}

test "readSource reads a file under the sources root as text ending in zero" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "pub fn run() void {}\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.dir.realPath(std.testing.io, &path_buffer);

    const source = try driver.readSource(std.testing.allocator, std.testing.io, path_buffer[0..length], "a.zig");
    defer std.testing.allocator.free(source);

    try std.testing.expectEqualStrings("pub fn run() void {}\n", source);
}

test "writeFullReport lists every code path and every failure and makes the folder it is written in" {
    const source = "pub fn run() void {\n    if (true) {\n        return;\n    }\n}\n";
    const checklists = try coverage.buildFile(std.testing.allocator, "a.zig", source);
    defer coverage.freeChecklists(std.testing.allocator, checklists);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/inside/report.txt", .{path_buffer[0..length]});
    defer std.testing.allocator.free(path);
    const failures = [_]worker.Failure{.{ .is_scenario = false, .index = 0, .kind = .crash, .token = "a.zig:double;seed=1", .complaint = "boom" }};

    // The driver gives this function an arena, which is released all at once, so the test does too.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try driver.writeFullReport(Subject, arena.allocator(), std.testing.io, path, checklists, &failures);

    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "not exercised a.zig:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "failed double crash: boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "-Dreplay=\"a.zig:double;seed=1\"") != null);
}

test "writeExitFile writes the exit code as text" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/flt-exit.txt", .{path_buffer[0..length]});
    defer std.testing.allocator.free(path);

    try driver.writeExitFile(std.testing.io, path, 1);

    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("1", text);
}

test "writeExitFile replaces what an earlier run wrote" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/flt-exit.txt", .{path_buffer[0..length]});
    defer std.testing.allocator.free(path);

    try driver.writeExitFile(std.testing.io, path, 1);
    try driver.writeExitFile(std.testing.io, path, 0);

    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("0", text);
}
