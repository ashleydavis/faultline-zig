const std = @import("std");
const kcov_run = @import("kcov_run.zig");

// A stand-in for kcov. It answers `--version` and otherwise writes every argument it was given,
// one per line, into the output directory, which is its third argument (after `--cobertura-only`
// and the include path) and exits cleanly.
const fake_kcov =
    \\#!/usr/bin/env bash
    \\if [ "$1" = "--version" ]; then
    \\    exit 0
    \\fi
    \\printf '%s\n' "$@" > "$3/args.txt"
    \\exit 0
    \\
;

// A kcov that answers `--version` and whose run exits with a failure status, which is what a
// worker that failed looks like from outside.
const failing_kcov =
    \\#!/usr/bin/env bash
    \\if [ "$1" = "--version" ]; then
    \\    exit 0
    \\fi
    \\exit 3
    \\
;

// A kcov that answers `--version` and whose run is ended by a signal.
const killed_kcov =
    \\#!/usr/bin/env bash
    \\if [ "$1" = "--version" ]; then
    \\    exit 0
    \\fi
    \\kill -KILL $$
    \\
;

// A kcov that cannot be run: even `--version` fails.
const broken_kcov =
    \\#!/usr/bin/env bash
    \\exit 1
    \\
;

// Writes an executable script called `name` into `dir`.
fn writeScript(dir: std.Io.Dir, name: []const u8, text: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = text });
    const file = try dir.openFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .executable_file);
}

// The path of `name` inside the temporary directory, relative to the working directory the way
// `std.testing.tmpDir` makes it. Free with `std.testing.allocator`.
fn pathIn(tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "runWorker starts kcov with the arguments kcov takes and then the worker and its arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "fake-kcov.sh", fake_kcov);

    const kcov = try pathIn(&tmp, "fake-kcov.sh");
    defer std.testing.allocator.free(kcov);
    const out_dir = try pathIn(&tmp, "pass-1");
    defer std.testing.allocator.free(out_dir);

    try kcov_run.runWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
        .worker_args = &.{ "--function", "parse" },
    });

    const seen = try tmp.dir.readFileAlloc(std.testing.io, "pass-1/args.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(seen);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "--cobertura-only\n--include-path=/nowhere/sources\n{s}\n/nowhere/worker\n--function\nparse\n",
        .{out_dir},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, seen);
}

test "runWorker empties the output directory, so an earlier run's coverage is not counted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "fake-kcov.sh", fake_kcov);
    try tmp.dir.createDirPath(std.testing.io, "pass-1");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pass-1/earlier-run.txt", .data = "covered" });

    const kcov = try pathIn(&tmp, "fake-kcov.sh");
    defer std.testing.allocator.free(kcov);
    const out_dir = try pathIn(&tmp, "pass-1");
    defer std.testing.allocator.free(out_dir);

    try kcov_run.runWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
    });

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "pass-1/earlier-run.txt", .{}));
}

test "runWorker with no worker arguments passes only the worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "fake-kcov.sh", fake_kcov);

    const kcov = try pathIn(&tmp, "fake-kcov.sh");
    defer std.testing.allocator.free(kcov);
    const out_dir = try pathIn(&tmp, "out");
    defer std.testing.allocator.free(out_dir);

    try kcov_run.runWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
    });

    const seen = try tmp.dir.readFileAlloc(std.testing.io, "out/args.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(seen);
    try std.testing.expect(std.mem.endsWith(u8, seen, "\n/nowhere/worker\n"));
}

test "runWorker makes the output directory when it is not there" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "fake-kcov.sh", fake_kcov);

    const kcov = try pathIn(&tmp, "fake-kcov.sh");
    defer std.testing.allocator.free(kcov);
    const out_dir = try pathIn(&tmp, "deep/er/pass");
    defer std.testing.allocator.free(out_dir);

    try kcov_run.runWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
    });

    var made = try tmp.dir.openDir(std.testing.io, "deep/er/pass", .{});
    made.close(std.testing.io);
}

test "runWorker fails when the worker exits with a failure status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "failing-kcov.sh", failing_kcov);

    const kcov = try pathIn(&tmp, "failing-kcov.sh");
    defer std.testing.allocator.free(kcov);
    const out_dir = try pathIn(&tmp, "out");
    defer std.testing.allocator.free(out_dir);

    try std.testing.expectError(error.WorkerFailed, kcov_run.runWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
    }));
}

test "runWorker fails when a signal ends the worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "killed-kcov.sh", killed_kcov);

    const kcov = try pathIn(&tmp, "killed-kcov.sh");
    defer std.testing.allocator.free(kcov);
    const out_dir = try pathIn(&tmp, "out");
    defer std.testing.allocator.free(out_dir);

    try std.testing.expectError(error.WorkerWasKilled, kcov_run.runWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
    }));
}

// Starts a worker under the kcov script `name` and checks it until it ends, as the driver does.
fn startAndCheck(script: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "kcov.sh", script);
    const kcov = try pathIn(&tmp, "kcov.sh");
    defer std.testing.allocator.free(kcov);
    const out_dir = try pathIn(&tmp, "out");
    defer std.testing.allocator.free(out_dir);

    var child = try kcov_run.startWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
    });
    errdefer child.kill(std.testing.io);
    while (!try kcov_run.checkWorker(&child)) {
        var a_moment: std.os.linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&a_moment, null);
    }
    try std.testing.expect(child.id == null);
}

test "a worker started without waiting is seen to end cleanly, to fail and to be killed" {
    try startAndCheck(fake_kcov);
    try std.testing.expectError(error.WorkerFailed, startAndCheck(failing_kcov));
    try std.testing.expectError(error.WorkerWasKilled, startAndCheck(killed_kcov));
}

test "runWorker fails when kcov itself cannot be started" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try pathIn(&tmp, "out");
    defer std.testing.allocator.free(out_dir);
    const kcov = try pathIn(&tmp, "no-such-kcov");
    defer std.testing.allocator.free(kcov);

    try std.testing.expectError(error.FileNotFound, kcov_run.runWorker(std.testing.allocator, std.testing.io, .{
        .kcov = kcov,
        .out_dir = out_dir,
        .sources_root = "/nowhere/sources",
        .worker = "/nowhere/worker",
    }));
}

test "includeArgument restricts kcov to the sources root" {
    const argument = try kcov_run.includeArgument(std.testing.allocator, "/cache/sources");
    defer std.testing.allocator.free(argument);
    try std.testing.expectEqualStrings("--include-path=/cache/sources", argument);
}

test "coveragePathOf names the file kcov writes in the output directory" {
    const path = try kcov_run.coveragePathOf(std.testing.allocator, "/cache/pass-2");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/cache/pass-2/cov.xml", path);
}

test "isKcovRunnable is true for a kcov that answers --version and false for one that does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "fake-kcov.sh", fake_kcov);
    try writeScript(tmp.dir, "broken-kcov.sh", broken_kcov);

    const working = try pathIn(&tmp, "fake-kcov.sh");
    defer std.testing.allocator.free(working);
    const broken = try pathIn(&tmp, "broken-kcov.sh");
    defer std.testing.allocator.free(broken);
    const missing = try pathIn(&tmp, "no-such-kcov");
    defer std.testing.allocator.free(missing);

    try std.testing.expect(kcov_run.isKcovRunnable(std.testing.io, working, null));
    try std.testing.expect(!kcov_run.isKcovRunnable(std.testing.io, broken, null));
    try std.testing.expect(!kcov_run.isKcovRunnable(std.testing.io, missing, null));
}

test "requireKcov writes nothing and succeeds when kcov can be run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "fake-kcov.sh", fake_kcov);
    const kcov = try pathIn(&tmp, "fake-kcov.sh");
    defer std.testing.allocator.free(kcov);

    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try kcov_run.requireKcov(std.testing.io, &written.writer, kcov, null);
    try std.testing.expectEqual(@as(usize, 0), written.written().len);
}

// Checks `text` is exactly one sentence: a capital letter first, one full stop that ends it and
// one line ending after that.
fn expectOneSentence(text: []const u8) !void {
    try std.testing.expect(text.len > 2);
    try std.testing.expect(std.ascii.isUpper(text[0]));
    try std.testing.expect(std.mem.endsWith(u8, text, ".\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
    // No full stop followed by a space, which is where a second sentence would start.
    try std.testing.expect(std.mem.indexOf(u8, text, ". ") == null);
}

test "requireKcov refuses with one sentence when kcov is not there" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try pathIn(&tmp, "no-such-kcov");
    defer std.testing.allocator.free(missing);

    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try std.testing.expectError(
        error.KcovNotFound,
        kcov_run.requireKcov(std.testing.io, &written.writer, missing, null),
    );

    try expectOneSentence(written.written());
    try std.testing.expect(std.mem.indexOf(u8, written.written(), "Faultline needs kcov to see which lines ran") != null);
    try std.testing.expect(std.mem.indexOf(u8, written.written(), missing) != null);
    try std.testing.expect(std.mem.indexOf(u8, written.written(), "docs/USER-GUIDE.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, written.written(), "\"Install kcov\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written.written(), "-Dkcov=<path>") != null);
}

test "requireKcov refuses a kcov that is there but cannot run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeScript(tmp.dir, "broken-kcov.sh", broken_kcov);
    const broken = try pathIn(&tmp, "broken-kcov.sh");
    defer std.testing.allocator.free(broken);

    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try std.testing.expectError(
        error.KcovNotFound,
        kcov_run.requireKcov(std.testing.io, &written.writer, broken, null),
    );
    try expectOneSentence(written.written());
}

test "requireKcov refuses a bare name that is on no PATH" {
    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();
    try std.testing.expectError(
        error.KcovNotFound,
        kcov_run.requireKcov(std.testing.io, &written.writer, "faultline-no-such-kcov-binary", null),
    );
    try expectOneSentence(written.written());
}

test "the user guide has the Install kcov heading the refusal points to" {
    const guide = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/USER-GUIDE.md", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(guide);
    try std.testing.expect(std.mem.indexOf(u8, guide, "Install kcov") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide, "-Dkcov=<path>") != null);
}
