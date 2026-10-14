// The program Faultline builds for a project: what runs when `zig build flt` runs it.
//
// There are three ways it runs, told apart by its command line. As the driver it checks kcov is
// there, copies nothing and writes nothing into the project, starts a worker under kcov for each
// pass over the project's functions and scenarios, reads which lines ran, and prints the report.
// As a worker (`--worker`) it makes the calls it was given in a work file and writes down what it
// found. With `--replay` it makes exactly the calls a replay token names and says how they went.

const std = @import("std");
const args_mod = @import("args.zig");
const checklist_mod = @import("checklist.zig");
const coverage = @import("coverage.zig");
const covered_lines = @import("covered_lines.zig");
const isolate = @import("isolate.zig");
const kcov_run = @import("kcov_run.zig");
const output_mod = @import("output.zig");
const project_mod = @import("project.zig");
const replay_mod = @import("replay.zig");
const report_mod = @import("report.zig");
const selection_mod = @import("selection.zig");
const style_mod = @import("style.zig");
const worker = @import("worker.zig");

// How many failures the terminal gets. The rest are in the report file, which holds every one.
// Ten for the same reason as the checklist: a project with many defects would otherwise bury the
// coverage number under pages of them.
const failure_limit: usize = 10;

// What the program exits with. Zero only when every code path was exercised and nothing failed.
const exit_ok: u8 = 0;
const exit_failed: u8 = 1;

// The panic handler: leaves a crash to the process that watches it, because every call runs in a
// child process whose crash is its parent's to report.
pub const panic = std.debug.FullPanic(isolate.panicInChild);

// The `main` of the program for one project. `Subject` is a `project.Project(...)`.
pub fn mainFor(comptime Subject: type) fn (std.process.Init.Minimal) u8 {
    return struct {
        fn main(init: std.process.Init.Minimal) u8 {
            return run(Subject, init) catch |err| {
                output_mod.print("Faultline stopped with {t}.\n", .{err});
                return exit_failed;
            };
        }
    }.main;
}

fn run(comptime Subject: type, init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list: std.ArrayList([]const u8) = .empty;
    var iterator = init.args.iterate();
    _ = iterator.next();
    while (iterator.next()) |argument| {
        try list.append(allocator, argument);
    }
    const args = args_mod.parse(list.items) catch |err| {
        output_mod.print("The command line was not understood: {t}.\n", .{err});
        return exit_failed;
    };

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const code = try runParsed(Subject, allocator, io, init, args);
    if (args.exit_file) |path| {
        try writeExitFile(io, path, code);
        return exit_ok;
    }
    return code;
}

// Writes the exit code as text, for the build step that fails the build from it.
pub fn writeExitFile(io: std.Io, path: []const u8, code: u8) !void {
    var buffer: [4]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{code}) catch unreachable;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

fn runParsed(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, init: std.process.Init.Minimal, args: args_mod.Args) !u8 {
    if (args.replay) |token| {
        return replayToken(Subject, allocator, io, args, token);
    }
    if (args.worker) {
        try runWorker(Subject, allocator, io, args);
        return exit_ok;
    }
    return drive(Subject, allocator, io, init, args);
}

// ---------------------------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------------------------

fn replayToken(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, args: args_mod.Args, token: []const u8) !u8 {
    const verdict = try replay_mod.run(Subject, allocator, allocator, io, .{ .sources_root = args.sources_root }, token);
    switch (verdict) {
        .passed => {
            output_mod.print("The replay of \"{s}\" passed.\n", .{token});
            return exit_ok;
        },
        .failed => |failure| {
            output_mod.print("The replay of \"{s}\" failed.\n", .{token});
            report_mod.printFailure(failure, subjectName(Subject, failure));
            return exit_failed;
        },
        .not_found => output_mod.print("The replay token names a function or scenario that this project does not have.\n", .{}),
        .bad_token => |err| output_mod.print("The replay token could not be read: {t}.\n", .{err}),
        .not_replayable => output_mod.print("The replay token names a function that cannot be called with what this project provides.\n", .{}),
    }
    return exit_failed;
}

// What a failure is about, for the sentence that reports it.
pub fn subjectName(comptime Subject: type, failure: worker.Failure) []const u8 {
    // A project with no scenarios or no functions has an empty table, which cannot be indexed.
    if (failure.is_scenario) {
        if (comptime Subject.scenario_entries.len == 0) {
            return "";
        }
        return Subject.scenario_entries[failure.index].name;
    }
    if (comptime Subject.function_entries.len == 0) {
        return "";
    }
    return Subject.function_entries[failure.index].name;
}

// ---------------------------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------------------------

fn runWorker(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, args: args_mod.Args) !void {
    const work_path = args.work orelse return error.NoWorkFile;
    const result_path = args.result orelse return error.NoResultFile;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, work_path, allocator, .unlimited);
    const items = try worker.readWork(allocator, text);

    worker.progress_is_watched = std.Io.File.stderr().isTty(io) catch false;

    var results = try worker.run(Subject, allocator, io, .{
        .seed = args.seed orelse 0,
        .sources_root = args.sources_root,
    }, items);
    defer results.deinit();

    var buffer: std.Io.Writer.Allocating = .init(allocator);
    try worker.writeResults(&buffer.writer, results);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = result_path, .data = buffer.written() });
}

// ---------------------------------------------------------------------------------------------
// The driver
// ---------------------------------------------------------------------------------------------

// What the run knows about one function of the project after the passes.
pub const Standing = struct {
    // How many calls the function got.
    calls: usize = 0,

    // How many specifications were made for it.
    specifications: usize = 0,

    // Whether it got any calls at all.
    was_called: bool = false,
};

fn drive(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, init: std.process.Init.Minimal, given: args_mod.Args) !u8 {
    // The directory of source copies arrives relative to where the program stands, and kcov reports
    // files by absolute path, so it is made absolute before anything compares the two.
    var args = given;
    args.sources_root = try std.Io.Dir.cwd().realPathFileAlloc(io, given.sources_root, allocator);

    const started_at = std.Io.Clock.Timestamp.now(io, .awake);

    var environ_map = try init.environ.createMap(allocator);
    defer environ_map.deinit();

    // Colour is off when asked for on the command line and when `NO_COLOR` is set, the convention
    // every other tool follows.
    const style = style_mod.Style.init(!args.no_color and environ_map.get("NO_COLOR") == null);

    const kcov_path = args.kcov orelse kcov_run.default_kcov;
    {
        var said: std.Io.Writer.Allocating = .init(allocator);
        kcov_run.requireKcov(io, &said.writer, kcov_path, &environ_map) catch |err| switch (err) {
            error.KcovNotFound => {
                output_mod.print("{s}\n", .{said.written()});
                return exit_failed;
            },
            else => return err,
        };
    }

    const selection: selection_mod.Selection = .{ .file = args.only_file, .function = args.only_function };

    // Which functions are in this run, and the code paths of every function in the files they
    // are in.
    var selected: std.ArrayList(usize) = .empty;
    for (Subject.function_entries, 0..) |entry, index| {
        if (selection.includesFunction(entry.file, entry.name)) {
            try selected.append(allocator, index);
        }
    }
    var checklists: std.ArrayList(coverage.Checklist) = .empty;
    var checklist_files: std.ArrayList([]const u8) = .empty;
    for (Subject.source_files) |file| {
        if (!selection.includesFile(file)) {
            continue;
        }
        const source = readSource(allocator, io, args.sources_root, file) catch continue;
        const built = coverage.buildFile(allocator, file, source) catch continue;
        for (built) |one| {
            if (selection.function) |only_function| {
                const wanted = std.mem.eql(u8, only_function, one.function) or
                    std.mem.eql(u8, selection_mod.bareName(only_function), one.function);
                if (!wanted) {
                    continue;
                }
            }
            try checklists.append(allocator, one);
        }
        try checklist_files.append(allocator, file);
    }

    output_mod.print("\n  Read {d} source file{s}, with {d} function{s} to exercise.\n", .{
        checklist_files.items.len,
        plural(checklist_files.items.len),
        selected.items.len,
        plural(selected.items.len),
    });

    const exe_path = try std.process.executablePathAlloc(io, allocator);
    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    const seed = std.mem.readInt(u64, &seed_bytes, .little);

    const standings = try allocator.alloc(Standing, Subject.function_entries.len);
    @memset(standings, .{});
    var failures: std.ArrayList(worker.Failure) = .empty;

    try std.Io.Dir.cwd().createDirPath(io, args.kcov_output);

    // First pass: every function with the values Faultline picks, and every scenario.
    var first: std.ArrayList(worker.WorkItem) = .empty;
    for (selected.items) |index| {
        if (Subject.function_entries[index].can_call) {
            try first.append(allocator, .{ .function = .{ .index = index, .phase = .normal } });
        }
    }
    for (Subject.scenario_entries, 0..) |entry, index| {
        if (selection.includesScenario(entry.file)) {
            try first.append(allocator, .{ .scenario = index });
        }
    }
    output_mod.print("  Reading which code paths those calls exercised.\n", .{});
    try runPass(Subject, allocator, io, &environ_map, args, exe_path, seed, 1, first.items, checklists.items, standings, &failures);

    // Second pass: for each function with a code path still not exercised, the values read from
    // the conditions in its source.
    var second: std.ArrayList(worker.WorkItem) = .empty;
    for (selected.items) |index| {
        const entry = Subject.function_entries[index];
        if (!entry.can_call) {
            continue;
        }
        if (hasUntickedPath(checklists.items, entry.file, entry.name)) {
            try second.append(allocator, .{ .function = .{ .index = index, .phase = .conditions } });
        }
    }
    if (second.items.len != 0) {
        try runPass(Subject, allocator, io, &environ_map, args, exe_path, seed, 2, second.items, checklists.items, standings, &failures);
    }

    const elapsed = started_at.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    return report(Subject, allocator, io, args, style, selected.items, checklist_files.items.len, checklists.items, standings, failures.items, elapsed.raw.nanoseconds);
}

// Starts a worker under kcov for one pass, reads what it found and which lines ran, and adds both
// to what the run has so far.
fn runPass(
    comptime Subject: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    args: args_mod.Args,
    exe_path: []const u8,
    seed: u64,
    pass: usize,
    items: []const worker.WorkItem,
    checklists: []coverage.Checklist,
    standings: []Standing,
    failures: *std.ArrayList(worker.Failure),
) !void {
    const prefix = try std.fmt.allocPrint(allocator, "{s}/pass{d}", .{ args.kcov_output, pass });
    const work_path = try std.fmt.allocPrint(allocator, "{s}.work", .{prefix});
    const result_path = try std.fmt.allocPrint(allocator, "{s}.result", .{prefix});

    var work: std.Io.Writer.Allocating = .init(allocator);
    try worker.writeWork(&work.writer, items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = work_path, .data = work.written() });

    const seed_text = try std.fmt.allocPrint(allocator, "{d}", .{seed});
    const worker_args = [_][]const u8{
        "--worker",
        "--work",
        work_path,
        "--result",
        result_path,
        "--seed",
        seed_text,
        "--sources-root",
        args.sources_root,
    };
    const out_dir = try std.fmt.allocPrint(allocator, "{s}.kcov", .{prefix});
    try kcov_run.runWorker(allocator, io, .{
        .kcov = args.kcov orelse kcov_run.default_kcov,
        .out_dir = out_dir,
        .sources_root = args.sources_root,
        .worker = exe_path,
        .worker_args = &worker_args,
        .environ_map = environ_map,
    });

    const coverage_path = try kcov_run.coveragePathOf(allocator, out_dir);
    var covered = try covered_lines.readCobertura(allocator, io, coverage_path);
    defer covered.deinit();
    coverage.tickFromCovered(checklists, &covered, args.sources_root);

    const result_text = try std.Io.Dir.cwd().readFileAlloc(io, result_path, allocator, .unlimited);
    const results = try worker.readResults(allocator, result_text);
    for (results.tallies) |tally| {
        standings[tally.index].calls += tally.calls;
        standings[tally.index].specifications += tally.specifications;
        standings[tally.index].was_called = true;
    }
    for (results.failures) |failure| {
        var seen = false;
        for (failures.items) |earlier| {
            if (earlier.is_scenario == failure.is_scenario and earlier.index == failure.index and
                earlier.kind == failure.kind and earlier.line == failure.line and
                std.mem.eql(u8, earlier.text, failure.text) and std.mem.eql(u8, earlier.complaint, failure.complaint))
            {
                seen = true;
            }
        }
        if (!seen) {
            try failures.append(allocator, failure);
        }
    }
    _ = Subject;
}

pub fn readSource(allocator: std.mem.Allocator, io: std.Io, sources_root: []const u8, file: []const u8) ![:0]u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, sources_root, .{});
    defer directory.close(io);
    return directory.readFileAllocOptions(io, file, allocator, .unlimited, .of(u8), 0);
}

// Whether the function called `name` in `file` has a code path nothing exercised.
pub fn hasUntickedPath(checklists: []const coverage.Checklist, file: []const u8, name: []const u8) bool {
    const bare = selection_mod.bareName(name);
    for (checklists) |one| {
        if (std.mem.eql(u8, one.file, file) and std.mem.eql(u8, one.function, bare) and !one.allTicked()) {
            return true;
        }
    }
    return false;
}

pub fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

// ---------------------------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------------------------

fn report(
    comptime Subject: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.Args,
    style: style_mod.Style,
    selected: []const usize,
    file_count: usize,
    checklists: []coverage.Checklist,
    standings: []const Standing,
    failures: []const worker.Failure,
    elapsed_nanoseconds: i96,
) !u8 {
    output_mod.print("\nFault testing\n", .{});

    // A block per file with a line per function, in the order the files and functions are in.
    var previous_file: []const u8 = "";
    var exercised_functions: usize = 0;
    for (checklists) |one| {
        if (!std.mem.eql(u8, previous_file, one.file)) {
            output_mod.print("\n  {s}\n", .{one.file});
            previous_file = one.file;
        }
        const ticked = one.tickedCount();
        const total = one.paths.len;
        const standing = standingOf(Subject, standings, one.file, one.function);
        const mark = if (one.allTicked()) style.pass() else style.miss();
        if (standing != null and standing.?.was_called) {
            exercised_functions += 1;
            output_mod.print("    {s} {s: <32} {d}/{d} code paths, {d} calls\n", .{ mark, one.function, ticked, total, standing.?.calls });
        } else if (standing != null and !one.allTicked()) {
            output_mod.print("    {s} {s: <32} {d}/{d} code paths, never called\n", .{ mark, one.function, ticked, total });
        } else {
            output_mod.print("    {s} {s: <32} {d}/{d} code paths\n", .{ mark, one.function, ticked, total });
        }
    }

    const counts = coverage.countPaths(checklists);
    output_mod.print(
        "\n  Found {d} source file{s}, called {d} function{s} and exercised {d} of {d} code paths.\n",
        .{ file_count, plural(file_count), exercised_functions, plural(exercised_functions), counts.ticked, counts.total },
    );
    output_mod.print("  Every call ran against a simulated filesystem and network, with every failure injected at every call that could fail that way.\n", .{});

    // The code paths nothing exercised, and what to do about them.
    const unticked = try coverage.listUnticked(allocator, checklists);
    var items: std.ArrayList(checklist_mod.Item) = .empty;
    var never_called_functions: std.ArrayList([]const u8) = .empty;
    for (selected) |index| {
        const entry = Subject.function_entries[index];
        if (entry.can_call) {
            continue;
        }
        try never_called_functions.append(allocator, entry.name);
        const line = firstLineOf(checklists, entry.file, entry.name);
        try items.append(allocator, .{
            .kind = if (entry.is_generic) .generic_function else .value_factory,
            .type_name = entry.unbuildable,
            .file = entry.file,
            .line = line,
            .function = entry.name,
        });
    }
    for (unticked) |path| {
        const never_called = containsName(never_called_functions.items, path.function);
        if (!never_called) {
            try items.append(allocator, .{ .kind = .scenario, .name = path.name, .file = path.file, .line = path.line, .function = path.function });
        }
    }

    if (args.report) |report_path| {
        try writeFullReport(Subject, allocator, io, report_path, checklists, failures);
        output_mod.print("  Full detail is in {s}.\n", .{report_path});
    }

    // Failures come first, because a function that crashed is more urgent than a code path that
    // was not reached.
    if (failures.len != 0) {
        output_mod.print("\n", .{});
        const shown = @min(failures.len, failure_limit);
        for (failures[0..shown]) |failure| {
            report_mod.printFailure(failure, subjectName(Subject, failure));
        }
        if (failures.len > shown) {
            output_mod.print("  and {d} more failures, all of them in the report file.\n", .{failures.len - shown});
        }
    }

    checklist_mod.print(items.items, style, args.report orelse "the report file");
    checklist_mod.printCoverage(counts.ticked, counts.total, style);

    const seconds: i96 = @divTrunc(elapsed_nanoseconds, std.time.ns_per_s);
    output_mod.print("  Took {d}s.\n", .{seconds});
    if (counts.ticked != counts.total or failures.len != 0) {
        return exit_failed;
    }
    return exit_ok;
}

pub fn standingOf(comptime Subject: type, standings: []const Standing, file: []const u8, function: []const u8) ?Standing {
    for (Subject.function_entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.file, file) and std.mem.eql(u8, selection_mod.bareName(entry.name), function)) {
            return standings[index];
        }
    }
    return null;
}

pub fn firstLineOf(checklists: []const coverage.Checklist, file: []const u8, name: []const u8) u32 {
    const bare = selection_mod.bareName(name);
    for (checklists) |one| {
        if (std.mem.eql(u8, one.file, file) and std.mem.eql(u8, one.function, bare) and one.paths.len != 0) {
            return one.paths[0].line;
        }
    }
    return 0;
}

pub fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, selection_mod.bareName(candidate), name)) {
            return true;
        }
    }
    return false;
}

// Writes every code path, exercised or not, and every failure to the report file.
pub fn writeFullReport(
    comptime Subject: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    checklists: []const coverage.Checklist,
    failures: []const worker.Failure,
) !void {
    var text: std.Io.Writer.Allocating = .init(allocator);
    for (checklists) |one| {
        for (one.paths, one.ticked) |code_path, is_ticked| {
            try text.writer.print("{s} {s}:{d} {s} in {s}\n", .{ if (is_ticked) "exercised" else "not exercised", one.file, code_path.line, code_path.name, one.function });
        }
    }
    for (failures) |failure| {
        try text.writer.print("failed {s} {s}: {s} {s}\n", .{ subjectName(Subject, failure), @tagName(failure.kind), failure.complaint, failure.text });
        try text.writer.print("  replay with -Dreplay=\"{s}\"\n", .{failure.token});
    }
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
}

test {
    _ = @import("driver.test.zig");
}
