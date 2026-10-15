const std = @import("std");
const args = @import("args.zig");

test "no arguments gives every default" {
    const parsed = try args.parse(&.{});

    try std.testing.expectEqualStrings("", parsed.repository);
    try std.testing.expect(parsed.report == null);
    try std.testing.expect(parsed.replay == null);
    try std.testing.expect(!parsed.worker);
    try std.testing.expect(!parsed.no_color);
    try std.testing.expect(parsed.results_cache == null);
    try std.testing.expect(parsed.crashes == null);
    try std.testing.expect(!parsed.no_cache);
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
        "--results-cache", "cache",
        "--crashes",    "crashes.txt",
        "--cache-salt", "salt",
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
    try std.testing.expectEqualStrings("cache", parsed.results_cache.?);
    try std.testing.expectEqualStrings("crashes.txt", parsed.crashes.?);
    try std.testing.expectEqualStrings("salt", parsed.cache_salt);
}

test "the flags that take no value are read" {
    const parsed = try args.parse(&.{ "--worker", "--no-color", "--no-cache" });

    try std.testing.expect(parsed.worker);
    try std.testing.expect(parsed.no_color);
    try std.testing.expect(parsed.no_cache);
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

test "how many workers run at once is read and is null unless given" {
    const given = try args.parse(&.{ "--jobs", "4" });
    const not_given = try args.parse(&.{"--worker"});

    try std.testing.expectEqual(@as(?usize, 4), given.jobs);
    try std.testing.expectEqual(@as(?usize, null), not_given.jobs);
}

test "a count of workers that is zero or not a number or missing is refused" {
    try std.testing.expectError(error.BadNumber, args.parse(&.{ "--jobs", "0" }));
    try std.testing.expectError(error.BadNumber, args.parse(&.{ "--jobs", "many" }));
    try std.testing.expectError(error.MissingValue, args.parse(&.{"--jobs"}));
}

test "the file a worker writes its progress to is read" {
    const parsed = try args.parse(&.{ "--progress-file", "cache/progress0" });

    try std.testing.expectEqualStrings("cache/progress0", parsed.progress_file.?);
}
