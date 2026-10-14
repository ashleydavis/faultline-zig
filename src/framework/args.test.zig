const std = @import("std");
const args = @import("args.zig");

test "no arguments gives every default" {
    const parsed = try args.parse(&.{});

    try std.testing.expectEqualStrings("", parsed.repository);
    try std.testing.expect(parsed.report == null);
    try std.testing.expect(parsed.replay == null);
    try std.testing.expect(!parsed.worker);
    try std.testing.expect(!parsed.no_color);
}

test "every option that takes a value is read" {
    const parsed = try args.parse(&.{
        "--repository", "project",
        "--report",     "full.txt",
        "--kcov",       "bin/kcov",
        "--kcov-out",   "out",
        "--sources-root", "copies",
        "--file",       "src/a.zig",
        "--function",   "run",
        "--replay",     "token",
        "--work",       "work.txt",
        "--result",     "result.txt",
        "--seed",       "42",
    });

    try std.testing.expectEqualStrings("project", parsed.repository);
    try std.testing.expectEqualStrings("full.txt", parsed.report.?);
    try std.testing.expectEqualStrings("bin/kcov", parsed.kcov.?);
    try std.testing.expectEqualStrings("out", parsed.kcov_output);
    try std.testing.expectEqualStrings("copies", parsed.sources_root);
    try std.testing.expectEqualStrings("src/a.zig", parsed.only_file.?);
    try std.testing.expectEqualStrings("run", parsed.only_function.?);
    try std.testing.expectEqualStrings("token", parsed.replay.?);
    try std.testing.expectEqualStrings("work.txt", parsed.work.?);
    try std.testing.expectEqualStrings("result.txt", parsed.result.?);
    try std.testing.expectEqual(@as(u64, 42), parsed.seed.?);
}

test "the flags that take no value are read" {
    const parsed = try args.parse(&.{ "--worker", "--no-color" });

    try std.testing.expect(parsed.worker);
    try std.testing.expect(parsed.no_color);
}

test "an option that is not known is refused" {
    try std.testing.expectError(error.UnknownOption, args.parse(&.{"--round"}));
}

test "an option with no value after it is refused" {
    try std.testing.expectError(error.MissingValue, args.parse(&.{"--file"}));
}

test "a seed that is not a number is refused" {
    try std.testing.expectError(error.BadNumber, args.parse(&.{ "--seed", "many" }));
}

test "the file the exit code is written to is read" {
    const parsed = try args.parse(&.{ "--exit-file", "cache/flt-exit.txt" });

    try std.testing.expectEqualStrings("cache/flt-exit.txt", parsed.exit_file.?);
}

test "no exit file is named unless one is given" {
    const parsed = try args.parse(&.{"--worker"});

    try std.testing.expect(parsed.exit_file == null);
}
