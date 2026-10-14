const std = @import("std");
const crash_view = @import("crash_view.zig");

// What a traced replay writes for a crash inside the standard library reached from the project.
const written =
    \\panic: attempt to unwrap error: NotDir
    \\error return context:
    \\/zig/lib/std/Io/Dir.zig:1005:5: 0x131d28b in deleteFile (flt-sim)
    \\    return io.vtable.dirDeleteFile(io.userdata, dir, sub_path);
    \\    ^
    \\stack trace:
    \\/zig/lib/std/Io/Dir.zig:1475:41: 0x1345f97 in deleteTree (flt-sim)
    \\                        error.NotDir => unreachable,
    \\                                        ^
    \\/project/src/lib/from.zig:245:38: 0x133f3ce in fetchText (flt-sim)
    \\    defer std.Io.Dir.cwd().deleteTree(io, temp_root) catch {};
    \\                                     ^
    \\/project/.zig-cache/o/abc/src/cmd/add.zig:121:23: 0x1338101 in run__anon_7 (flt-sim)
    \\        return runFrom(ctx, args.global, spec);
    \\                      ^
    \\/faultline/src/framework/call.zig:123:17: 0x177e8b5 in runCall (flt-sim)
    \\
;

test "parse reads the message, where the error came from and every frame of the stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const trace = try crash_view.parse(arena.allocator(), written);

    try std.testing.expectEqualStrings("attempt to unwrap error: NotDir", trace.message);
    try std.testing.expectEqual(@as(usize, 1), trace.origin.len);
    try std.testing.expectEqualStrings("deleteFile", trace.origin[0].function);
    try std.testing.expectEqual(@as(usize, 4), trace.stack.len);
    try std.testing.expectEqualStrings("/project/src/lib/from.zig", trace.stack[1].path);
    try std.testing.expectEqual(@as(u32, 245), trace.stack[1].line);
    try std.testing.expectEqual(@as(u32, 38), trace.stack[1].column);
    try std.testing.expectEqualStrings("run", trace.stack[2].function);
}

test "frameOf reads a frame line and nothing else" {
    const frame = crash_view.frameOf("/a/b.zig:12:3: 0xff in run (flt-sim)").?;

    try std.testing.expectEqualStrings("/a/b.zig", frame.path);
    try std.testing.expectEqual(@as(u32, 12), frame.line);
    try std.testing.expectEqual(@as(u32, 3), frame.column);
    try std.testing.expectEqualStrings("run", frame.function);
    try std.testing.expectEqual(@as(?crash_view.Frame, null), crash_view.frameOf("    return x;"));
    try std.testing.expectEqual(@as(?crash_view.Frame, null), crash_view.frameOf("panic: integer overflow"));
}

test "projectPath takes a file of the copy or of the project and nothing else" {
    try std.testing.expectEqualStrings("src/cmd/add.zig", crash_view.projectPath("/copy/src/cmd/add.zig", "/copy", "/project").?);
    try std.testing.expectEqualStrings("src/lib/from.zig", crash_view.projectPath("/project/src/lib/from.zig", "/copy", "/project").?);
    try std.testing.expectEqual(@as(?[]const u8, null), crash_view.projectPath("/zig/lib/std/Io/Dir.zig", "/copy", "/project"));
    try std.testing.expectEqual(@as(?[]const u8, null), crash_view.projectPath("/projectile/a.zig", "/copy", "/project"));
}

test "shortPath names a standard library file from std" {
    try std.testing.expectEqualStrings("std/Io/Dir.zig", crash_view.shortPath("/zig/lib/std/Io/Dir.zig"));
    try std.testing.expectEqualStrings("/other/a.zig", crash_view.shortPath("/other/a.zig"));
}

test "injectedFailures says in words which failures the token injects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const one = (try crash_view.injectedFailures(arena.allocator(), "a.zig:run;seed=1;values=f0;fail=delete#1/not_a_directory")).?;
    try std.testing.expectEqualStrings("the 2nd delete call fail with \"not a directory\"", one);
    const two = (try crash_view.injectedFailures(arena.allocator(), "a.zig:run;seed=1;fail=allocator#2/allocation_fails,read#12/file_not_found")).?;
    try std.testing.expectEqualStrings("the 3rd allocator call fail with \"allocation fails\" and the 13th read call fail with \"file not found\"", two);
    try std.testing.expectEqual(@as(?[]const u8, null), try crash_view.injectedFailures(arena.allocator(), "a.zig:run;seed=1;values=b0"));
}

test "hintFor gives each kind of panic its own advice, the standard library its own and a false alarm its own" {
    try std.testing.expect(std.mem.indexOf(u8, crash_view.hintFor("attempt to unwrap error: NotDir", true, false), "`try`") != null);
    try std.testing.expect(std.mem.indexOf(u8, crash_view.hintFor("attempt to use null value", true, false), "null") != null);
    try std.testing.expect(std.mem.indexOf(u8, crash_view.hintFor("index out of bounds: index 5, len 5", true, false), "`len`") != null);
    try std.testing.expect(std.mem.indexOf(u8, crash_view.hintFor("integer overflow", true, false), "`+%`") != null);
    try std.testing.expect(std.mem.indexOf(u8, crash_view.hintFor("integer overflow", false, false), "function your code called") != null);
    try std.testing.expect(std.mem.startsWith(u8, crash_view.hintFor("attempt to unwrap error: NotDir", false, true), "Likely a false alarm."));
    try std.testing.expect(std.mem.indexOf(u8, crash_view.hintFor("something else", true, false), "Return an error") != null);
}

test "plainMessage says which error reached an unreachable and leaves other messages to Zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("NotDir reached an `unreachable` in deleteTree", (try crash_view.plainMessage(allocator, "attempt to unwrap error: NotDir", "error.NotDir => unreachable,", "deleteTree")).?);
    try std.testing.expectEqualStrings("it reached an `unreachable` in run", (try crash_view.plainMessage(allocator, "reached unreachable code", "else => unreachable,", "run")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try crash_view.plainMessage(allocator, "attempt to unwrap error: NotDir", "const x = try y;", "run"));
    try std.testing.expectEqual(@as(?[]const u8, null), try crash_view.plainMessage(allocator, "integer overflow", "x - 1 unreachable", "run"));
}

test "write shows the inputs, the injected failure, both places in code, the stack from the command and a hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.createDirPath(std.testing.io, "project/src/lib");
    try directory.dir.createDirPath(std.testing.io, "zig/lib/std/Io");
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/lib/from.zig", .data = "fn fetchText() void {\n    const temp_root = x;\n    defer std.Io.Dir.cwd().deleteTree(io, temp_root) catch {};\n" });
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "zig/lib/std/Io/Dir.zig", .data = "switch (err) {\n        error.NotDir => unreachable,\n}\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..length];
    const repository = try std.fmt.allocPrint(allocator, "{s}/project", .{root});
    const copy = try std.fmt.allocPrint(allocator, "{s}/copy", .{root});
    const standard = try std.fmt.allocPrint(allocator, "{s}/zig/lib/std/Io/Dir.zig", .{root});
    const trace: crash_view.Trace = .{
        .message = "attempt to unwrap error: NotDir",
        .origin = &.{
            .{ .path = "/faultline/src/framework/filesystem_faults.zig", .line = 142, .column = 17, .function = "errorOf" },
            .{ .path = standard, .line = 1005, .column = 5, .function = "deleteFile" },
        },
        .stack = &.{
            .{ .path = standard, .line = 2, .column = 25, .function = "deleteTree" },
            .{ .path = try std.fmt.allocPrint(allocator, "{s}/src/lib/from.zig", .{repository}), .line = 3, .column = 38, .function = "fetchText" },
            .{ .path = try std.fmt.allocPrint(allocator, "{s}/src/cmd/add.zig", .{copy}), .line = 121, .column = 23, .function = "run" },
            .{ .path = "/faultline/src/framework/call.zig", .line = 123, .column = 17, .function = "runCall" },
        },
    };
    var out: std.Io.Writer.Allocating = .init(allocator);

    try crash_view.write(&out.writer, allocator, std.testing.io, trace, .{
        .subject = "run",
        .subject_file = "src/cmd/add.zig",
        .token = "src/cmd/add.zig:run;seed=1;values=f0;fail=delete#1/not_a_directory",
        .inputs = "projectWithOnePackage, fromOnly",
        .command = "zig build flt -Dreplay=\"t\"",
        .sources_root = copy,
        .repository = repository,
    });

    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "-- CRASH "));
    try std.testing.expect(std.mem.indexOf(u8, text, " src/lib/from.zig:3:38\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "run in src/cmd/add.zig crashed: NotDir reached an `unreachable` in deleteTree.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Zig's message: panic: attempt to unwrap error: NotDir\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "It was called with projectWithOnePackage, fromOnly.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Faultline made the 2nd delete call fail with \"not a directory\", in deleteFile at std/Io/Dir.zig:1005.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "It panicked in deleteTree at std/Io/Dir.zig:2:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2 |         error.NotDir => unreachable,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Your code called it at src/lib/from.zig:3:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3 |     defer std.Io.Dir.cwd().deleteTree(io, temp_root) catch {};\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n" ++ " " ** (1 + 3 + 37) ++ "^\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Stack trace, from the command to the panic:\n    zig build flt -Dreplay=\"t\"\n    run         src/cmd/add.zig:121:23\n    fetchText   src/lib/from.zig:3:38\n    deleteTree  std/Io/Dir.zig:2:25  panicked here\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "runCall") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hint: Likely a false alarm.") != null);
}

test "parse reads a trace written in colour" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const coloured = "\x1b[1mpanic: \x1b[0minteger overflow\nstack trace:\n\x1b[1m/a/b.zig:12:3\x1b[0m: \x1b[2m0xff in run (flt-sim)\x1b[0m\n";

    const trace = try crash_view.parse(arena.allocator(), coloured);

    try std.testing.expectEqualStrings("integer overflow", trace.message);
    try std.testing.expectEqual(@as(usize, 1), trace.stack.len);
    try std.testing.expectEqualStrings("/a/b.zig", trace.stack[0].path);
    try std.testing.expectEqualStrings("run", trace.stack[0].function);
}

test "withoutColour takes out every colour code and leaves the rest" {
    const plain = try crash_view.withoutColour(std.testing.allocator, "\x1b[31;1mred\x1b[0m and \x1b[2mdim\x1b[m");
    defer std.testing.allocator.free(plain);

    try std.testing.expectEqualStrings("red and dim", plain);
}

test "write colours the heading, the mark under the place and the hint when colour is on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "fn run() void {\n    _ = 1 - 2;\n}\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..length];
    const trace: crash_view.Trace = .{
        .message = "integer overflow",
        .stack = &.{.{ .path = try std.fmt.allocPrint(allocator, "{s}/a.zig", .{root}), .line = 2, .column = 11, .function = "run" }},
    };
    var out: std.Io.Writer.Allocating = .init(allocator);

    try crash_view.write(&out.writer, allocator, std.testing.io, trace, .{
        .subject = "run",
        .token = "a.zig:run;seed=1",
        .sources_root = "/no/copy",
        .repository = root,
        .style = .init(true),
    });

    const text = out.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "\x1b[31m\x1b[1m-- CRASH "));
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[36m\x1b[1ma.zig:2:11\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[31m\x1b[1m^\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[32m\x1b[1mHint:\x1b[0m") != null);
}
