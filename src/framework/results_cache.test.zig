const std = @import("std");
const results_cache = @import("results_cache.zig");
const module_table = @import("../cmd/module_table.zig");
const worker = @import("worker.zig");

test "a stored result reads back what was written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tallies = [_]worker.Tally{.{ .index = 1, .calls = 40, .specifications = 6, .is_cut_short = false }};
    const failures = [_]worker.Failure{.{ .is_scenario = false, .index = 0, .kind = .crash, .token = "a.zig:run;seed=7", .complaint = "panic:\tboom" }};
    const written: results_cache.Entry = .{
        .file = "src/a.zig",
        .key = 0xfeed,
        .contributors = &.{ .{ .file = "src/a.zig", .key = 0xfeed }, .{ .file = "src/b.zig", .key = 9 } },
        .marks = &.{.{ .function = "run", .marks = "tm." }},
        .tallies = &tallies,
        .failures = &failures,
    };
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    try results_cache.writeEntry(&text.writer, written);

    const read = (try results_cache.readEntry(arena.allocator(), text.written())).?;

    try std.testing.expectEqualStrings("src/a.zig", read.file);
    try std.testing.expectEqual(@as(u64, 0xfeed), read.key);
    try std.testing.expectEqual(@as(usize, 2), read.contributors.len);
    try std.testing.expectEqualStrings("src/b.zig", read.contributors[1].file);
    try std.testing.expectEqual(@as(u64, 9), read.contributors[1].key);
    try std.testing.expectEqualStrings("run", read.marks[0].function);
    try std.testing.expectEqualStrings("tm.", read.marks[0].marks);
    try std.testing.expectEqual(@as(usize, 40), read.tallies[0].calls);
    try std.testing.expectEqualStrings("panic:\tboom", read.failures[0].complaint);
}

test "a stored result of another format version or no format at all is not read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(?results_cache.Entry, null), try results_cache.readEntry(arena.allocator(), "faultline-results 999\nfile\ta.zig\nkey\t1\n"));
    try std.testing.expectEqual(@as(?results_cache.Entry, null), try results_cache.readEntry(arena.allocator(), "something else\n"));
    try std.testing.expectEqual(@as(?results_cache.Entry, null), try results_cache.readEntry(arena.allocator(), ""));
}

test "importsOf finds every import and embed with a string literal and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\const std = @import("std");
        \\const b = @import("lib/b.zig");
        \\const words = @embedFile("words.txt");
        \\const text = "@import(\"not.zig\")";
        \\const other = @typeName(u8);
        \\
    ;

    const found = try results_cache.importsOf(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("std", found[0].target);
    try std.testing.expectEqualStrings("lib/b.zig", found[1].target);
    try std.testing.expectEqual(.embed, found[2].builtin);
    try std.testing.expectEqualStrings("words.txt", found[2].target);
}

test "entryPath names a file under the directory that differs from one path to another" {
    const first = try results_cache.entryPath(std.testing.allocator, "cache", "src/a.zig");
    defer std.testing.allocator.free(first);
    const second = try results_cache.entryPath(std.testing.allocator, "cache", "src/b.zig");
    defer std.testing.allocator.free(second);

    try std.testing.expect(std.mem.startsWith(u8, first, "cache/"));
    try std.testing.expect(std.mem.endsWith(u8, first, ".txt"));
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

// A copy of a project's files in a temporary directory, for working out keys from.
const Fixture = struct {
    directory: std.testing.TmpDir,
    root: []const u8,

    fn init() !Fixture {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try directory.dir.realPath(std.testing.io, &buffer);
        return .{ .directory = directory, .root = try std.testing.allocator.dupe(u8, buffer[0..length]) };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.root);
        self.directory.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            try self.directory.dir.createDirPath(std.testing.io, parent);
        }
        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn keyOf(self: *Fixture, modules: []const module_table.Module, roots: []const []const u8) !?u64 {
        return results_cache.keyOf(std.testing.allocator, std.testing.io, .{
            .sources_root = self.root,
            .repository = self.root,
            .modules = modules,
            .salt = "faultline",
        }, roots);
    }
};

test "a key changes when the file or a file it imports changes and not when another file does" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("src/a.zig", "const b = @import(\"lib/b.zig\");\n");
    try fixture.write("src/lib/b.zig", "pub fn b() void {}\n");
    try fixture.write("src/c.zig", "pub fn c() void {}\n");
    const first = (try fixture.keyOf(&.{}, &.{"src/a.zig"})).?;

    try fixture.write("src/c.zig", "pub fn c() u8 { return 1; }\n");
    try std.testing.expectEqual(first, (try fixture.keyOf(&.{}, &.{"src/a.zig"})).?);

    try fixture.write("src/lib/b.zig", "pub fn b() u8 { return 2; }\n");
    const after_import = (try fixture.keyOf(&.{}, &.{"src/a.zig"})).?;
    try std.testing.expect(first != after_import);

    try fixture.write("src/a.zig", "const b = @import(\"lib/b.zig\");\n// changed\n");
    try std.testing.expect(after_import != (try fixture.keyOf(&.{}, &.{"src/a.zig"})).?);
}

test "a key follows an import of a module of the project to the file it is rooted in" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("src/a.zig", "const lib = @import(\"lib\");\n");
    try fixture.write("src/lib/root.zig", "pub fn b() void {}\n");
    const modules = [_]module_table.Module{.{ .name = "lib", .place = .project, .path = "src/lib/root.zig" }};
    const first = (try fixture.keyOf(&modules, &.{"src/a.zig"})).?;

    try fixture.write("src/lib/root.zig", "pub fn b() u8 { return 2; }\n");

    try std.testing.expect(first != (try fixture.keyOf(&modules, &.{"src/a.zig"})).?);
}

test "a file that imports a module the build generates has no key" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("src/a.zig", "const options = @import(\"options\");\n");
    const modules = [_]module_table.Module{.{ .name = "options", .place = .generated, .path = "" }};

    try std.testing.expectEqual(@as(?u64, null), try fixture.keyOf(&modules, &.{"src/a.zig"}));
}

test "a key changes with the salt" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("src/a.zig", "pub fn a() void {}\n");
    const first = (try fixture.keyOf(&.{}, &.{"src/a.zig"})).?;
    const other = (try results_cache.keyOf(std.testing.allocator, std.testing.io, .{
        .sources_root = fixture.root,
        .repository = fixture.root,
        .modules = &.{},
        .salt = "another faultline",
    }, &.{"src/a.zig"})).?;

    try std.testing.expect(first != other);
}

test "unitsToRun uses a stored result whose key and contributors' keys are unchanged" {
    const units = [_]results_cache.Unit{
        .{ .file = "a.zig", .key = 1, .entry = .{ .file = "a.zig", .key = 1, .contributors = &.{.{ .file = "a.zig", .key = 1 }} } },
    };
    const to_run = try results_cache.unitsToRun(std.testing.allocator, &units);
    defer std.testing.allocator.free(to_run);

    try std.testing.expectEqualSlices(bool, &.{false}, to_run);
}

test "unitsToRun runs a file with no result, another key or no key" {
    const units = [_]results_cache.Unit{
        .{ .file = "a.zig", .key = 1, .entry = null },
        .{ .file = "b.zig", .key = 2, .entry = .{ .file = "b.zig", .key = 3 } },
        .{ .file = "c.zig", .key = null, .entry = .{ .file = "c.zig", .key = 3 } },
    };
    const to_run = try results_cache.unitsToRun(std.testing.allocator, &units);
    defer std.testing.allocator.free(to_run);

    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, to_run);
}

test "unitsToRun runs a file again when a file that exercised its code paths changed" {
    const units = [_]results_cache.Unit{
        .{ .file = "lookup.zig", .key = 1, .entry = .{ .file = "lookup.zig", .key = 1, .contributors = &.{.{ .file = "caller.zig", .key = 5 }} } },
        .{ .file = "caller.zig", .key = 6, .entry = .{ .file = "caller.zig", .key = 5 } },
    };
    const to_run = try results_cache.unitsToRun(std.testing.allocator, &units);
    defer std.testing.allocator.free(to_run);

    try std.testing.expectEqualSlices(bool, &.{ true, true }, to_run);
}

test "unitsToRun runs again every file that exercised the code paths of a file that runs again" {
    const units = [_]results_cache.Unit{
        .{ .file = "lookup.zig", .key = 2, .entry = .{ .file = "lookup.zig", .key = 1, .contributors = &.{.{ .file = "caller.zig", .key = 5 }} } },
        .{ .file = "caller.zig", .key = 5, .entry = .{ .file = "caller.zig", .key = 5 } },
        .{ .file = "other.zig", .key = 7, .entry = .{ .file = "other.zig", .key = 7 } },
    };
    const to_run = try results_cache.unitsToRun(std.testing.allocator, &units);
    defer std.testing.allocator.free(to_run);

    try std.testing.expectEqualSlices(bool, &.{ true, true, false }, to_run);
}
