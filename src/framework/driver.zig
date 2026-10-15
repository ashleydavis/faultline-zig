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
const crash_view = @import("crash_view.zig");
const covered_lines = @import("covered_lines.zig");
const isolate = @import("isolate.zig");
const kcov_run = @import("kcov_run.zig");
const output_mod = @import("output.zig");
const plan_mod = @import("plan.zig");
const project_mod = @import("project.zig");
const replay_mod = @import("replay.zig");
const report_mod = @import("report.zig");
const run_cache = @import("run_cache.zig");
const selection_mod = @import("selection.zig");
const shards_mod = @import("shards.zig");
const style_mod = @import("style.zig");
const worker = @import("worker.zig");

// How many failures the terminal gets. The rest are in the report file, which holds every one. One,
// because each is shown in full, with its code and its stack trace, and a project with many
// defects would otherwise bury the summary under pages of them. Fixing the first and running
// again shows the next.
const failure_limit: usize = 1;

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
        return replayToken(Subject, allocator, io, init, args, token);
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

fn replayToken(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, init: std.process.Init.Minimal, args: args_mod.Args, token: []const u8) !u8 {
    isolate.is_trace_wanted = args.trace;
    const verdict = try replay_mod.run(Subject, allocator, allocator, io, .{
        .sources_root = args.sources_root,
        .keeps_whole_complaint = args.trace,
    }, token);
    if (args.trace) {
        // Only what the call wrote, for the driver that asked to read where it crashed.
        if (verdict == .failed) {
            output_mod.print("{s}", .{verdict.failed.complaint});
        }
        return if (verdict == .failed) exit_failed else exit_ok;
    }
    switch (verdict) {
        .passed => {
            output_mod.print("The replay of \"{s}\" passed.\n", .{token});
            return exit_ok;
        },
        .failed => |failure| {
            if (failure.kind == .crash) {
                // The trace names files by absolute path, so the copy's directory is made absolute
                // to tell the project's frames from the rest.
                var absolute = args;
                absolute.sources_root = try std.Io.Dir.cwd().realPathFileAlloc(io, args.sources_root, allocator);
                var environ_map = try init.environ.createMap(allocator);
                defer environ_map.deinit();
                const style = style_mod.Style.init(!args.no_color and environ_map.get("NO_COLOR") == null);
                const command = try std.fmt.allocPrint(allocator, "zig build flt -Dreplay=\"{s}\"", .{token});
                if (try crashViewOf(Subject, allocator, io, absolute, style, failure, command)) |view| {
                    // The command was typed a moment ago and stands at the root of the trace, so
                    // it is not repeated.
                    output_mod.print("The replay failed.\n\n{s}", .{view});
                    return exit_failed;
                }
            }
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
    worker.progress_file = args.progress_file;
    worker.progress_io = io;

    var results = try worker.run(Subject, allocator, io, .{
        .seed = args.seed orelse 0,
        .sources_root = args.sources_root,
    }, items);
    defer results.deinit();
    worker.finishProgress();

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

    // A function is taken only when the file's own source declares it. A file can hold a type of
    // the standard library under a name of its own, such as `const Object = std.ArrayHashMap(...)`,
    // and that type's methods are listed with the file's functions but are not the project's.
    var selected: std.ArrayList(usize) = .empty;
    for (Subject.function_entries, 0..) |entry, index| {
        if (selection.includesFunction(entry.file, entry.name) and hasChecklist(checklists.items, entry.file, entry.name)) {
            try selected.append(allocator, index);
        }
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

    // The files whose results an earlier run proved and that have not changed since are not
    // executed again: their results come from the cache and go into the report as the run that
    // made them found them.
    const cache_directory: ?[]const u8 = if (run_cache.isUsed(args)) args.results_cache else null;
    var cache: run_cache.State = .{};
    if (cache_directory) |directory| {
        cache = try run_cache.prepare(Subject, allocator, io, args, directory, checklists.items);
        try run_cache.load(Subject, allocator, cache, checklists.items, standings, &failures);
        printLoaded(cache);
    }
    var record: run_cache.Record = .{};

    try std.Io.Dir.cwd().createDirPath(io, args.kcov_output);
    var progress: RunProgress = .{ .started_at = started_at };

    // Rounds. kcov reports what ran only when the worker it watches exits, so the calls are made a
    // round at a time: each round makes the next calls of every function that still has a code path
    // not exercised, in the order its specifications are listed (its first values, then one value
    // changed at a time, then every combination), and the coverage read after it decides which
    // functions are done. A function is done when every one of its code paths is exercised and so
    // is every path of the functions in its file that Faultline does not call itself, or when it
    // has no calls left. The run stops when every function is done.
    const totals = try allocator.alloc(usize, Subject.function_entries.len);
    const next = try allocator.alloc(usize, Subject.function_entries.len);
    const done = try allocator.alloc(bool, Subject.function_entries.len);
    @memset(next, 0);
    @memset(done, false);
    var spec_arena = std.heap.ArenaAllocator.init(allocator);
    defer spec_arena.deinit();
    for (selected.items) |index| {
        const entry = Subject.function_entries[index];
        done[index] = !entry.can_call or cache.isLoaded(entry.file);
        totals[index] = if (done[index]) 0 else (try entry.list_specs(spec_arena.allocator(), io, seed, &.{})).len;
    }
    var round: usize = 1;
    while (true) : (round += 1) {
        const chunk = roundSize(round);
        var items: std.ArrayList(worker.WorkItem) = .empty;
        for (selected.items) |index| {
            if (done[index] or next[index] >= totals[index]) {
                continue;
            }
            const count = @min(chunk, totals[index] - next[index]);
            try items.append(allocator, .{ .function = .{ .index = index, .phase = .normal, .first = next[index], .count = count } });
            next[index] += count;
        }
        if (round == 1) {
            for (Subject.scenario_entries, 0..) |entry, index| {
                if (selection.includesScenario(entry.file) and !cache.isLoaded(entry.file)) {
                    try items.append(allocator, .{ .scenario = index });
                }
            }
        }
        if (items.items.len == 0) {
            break;
        }
        try runPass(Subject, allocator, io, &environ_map, args, exe_path, seed, round, items.items, checklists.items, standings, &failures, &progress, &record);
        for (selected.items) |index| {
            if (done[index]) {
                continue;
            }
            const entry = Subject.function_entries[index];
            var called: std.ArrayList([]const u8) = .empty;
            for (Subject.function_entries) |other| {
                if (other.can_call and std.mem.eql(u8, other.file, entry.file)) {
                    try called.append(allocator, other.name);
                }
            }
            const own_left = hasUntickedPath(checklists.items, entry.file, entry.name);
            const private_left = hasUntickedPathOutside(checklists.items, entry.file, called.items);
            if (!own_left and !private_left) {
                done[index] = true;
            } else if (next[index] >= totals[index]) {
                done[index] = true;
            }
        }
    }

    // Last pass: for each function with a code path still not exercised, the values read from
    // the conditions in its source.
    var second: std.ArrayList(worker.WorkItem) = .empty;
    for (selected.items) |index| {
        const entry = Subject.function_entries[index];
        if (!entry.can_call or cache.isLoaded(entry.file)) {
            continue;
        }
        if (hasUntickedPath(checklists.items, entry.file, entry.name)) {
            try second.append(allocator, .{ .function = .{ .index = index, .phase = .conditions } });
        }
    }
    if (second.items.len != 0) {
        try runPass(Subject, allocator, io, &environ_map, args, exe_path, seed, round, second.items, checklists.items, standings, &failures, &progress, &record);
    }

    // In the order of the tables, and in the order they were found within one function or
    // scenario, so the report lists them the same way whichever files' results came from the cache.
    std.sort.block(worker.Failure, failures.items, {}, isFailureBefore);

    if (cache_directory) |directory| {
        try run_cache.store(Subject, allocator, io, directory, cache, &record, checklists.items);
    }

    const elapsed = started_at.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    return report(Subject, allocator, io, args, style, cache, selected.items, checklist_files.items.len, checklists.items, standings, failures.items, elapsed.raw.nanoseconds);
}

// Runs one pass: splits its work into shards (see `shards.zig`), runs a worker under kcov for each,
// up to `jobs` at once, then reads what each shard found and which lines it ran, in shard order, and
// adds both to what the run has so far. Reading in shard order and not in the order the workers
// finish is what keeps the report the same whatever the number of workers.
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
    progress: *RunProgress,
    record: *run_cache.Record,
) !void {
    const files = try allocator.alloc([]const u8, items.len);
    defer allocator.free(files);
    for (items, files) |item, *file| {
        file.* = fileOfItem(Subject, item);
    }
    const split = try shards_mod.split(allocator, items, files);
    defer shards_mod.free(allocator, split);
    const jobs = jobsFor(args.jobs, std.Thread.getCpuCount() catch 1, split.len);
    const is_watched = std.Io.File.stderr().isTty(io) catch false;

    var prefixes = try allocator.alloc([]const u8, split.len);
    for (prefixes, 0..) |*prefix, number| {
        prefix.* = try std.fmt.allocPrint(allocator, "{s}/pass{d}.shard{d}", .{ args.kcov_output, pass, number });
    }
    const children = try allocator.alloc(?std.process.Child, split.len);
    defer allocator.free(children);
    @memset(children, null);
    const shard_calls = try allocator.alloc(usize, split.len);
    defer allocator.free(shard_calls);
    @memset(shard_calls, 0);
    // Whatever goes wrong, no worker is left running.
    defer {
        for (children) |*slot| {
            if (slot.*) |*child| {
                child.kill(io);
            }
        }
    }

    var next: usize = 0;
    var finished: usize = 0;
    var running: usize = 0;
    while (finished < split.len) {
        while (running < jobs and next < split.len) {
            children[next] = try startShard(allocator, io, environ_map, args, exe_path, seed, prefixes[next], split[next], is_watched);
            next += 1;
            running += 1;
        }
        for (children) |*slot| {
            if (slot.*) |*child| {
                if (try kcov_run.checkWorker(child)) {
                    slot.* = null;
                    running -= 1;
                    finished += 1;
                }
            }
        }
        if (is_watched) {
            readShardCalls(allocator, io, prefixes[0..next], shard_calls[0..next]);
            printPassProgress(allocator, io, progress.*, shard_calls, prefixes[0..next], children[0..next]);
        }
        if (finished < split.len) {
            var a_moment: std.os.linux.timespec = .{ .sec = 0, .nsec = worker_check_every_ns };
            _ = std.os.linux.nanosleep(&a_moment, null);
        }
    }
    if (is_watched) {
        readShardCalls(allocator, io, prefixes, shard_calls);
        for (shard_calls) |calls| {
            progress.calls_before += calls;
        }
        output_mod.print("", .{});
    }

    for (prefixes, split) |prefix, shard| {
        try mergeShard(allocator, io, args, prefix, fileOfItem(Subject, shard[0]), checklists, standings, failures, record);
    }
}

// The source file or sim file a work item's calls are of.
fn fileOfItem(comptime Subject: type, item: worker.WorkItem) []const u8 {
    // A project with no functions or no scenarios has an empty table, which cannot be indexed.
    switch (item) {
        .function => |function| {
            if (comptime Subject.function_entries.len == 0) {
                return "";
            }
            return Subject.function_entries[function.index].file;
        },
        .scenario => |index| {
            if (comptime Subject.scenario_entries.len == 0) {
                return "";
            }
            return Subject.scenario_entries[index].file;
        },
    }
}

// How often the driver looks for workers that have ended while a pass runs. Short against the
// time a worker takes, so a free slot is filled soon, and long enough that looking costs nothing.
const worker_check_every_ns = 50 * std.time.ns_per_ms;

// How many workers a pass runs at once: the number asked for, or one per processor core, and never
// more than there are shards or fewer than one.
pub fn jobsFor(asked: ?usize, cores: usize, shard_count: usize) usize {
    const wanted = asked orelse cores;
    return @max(1, @min(wanted, shard_count));
}

// Writes the work of one shard and starts its worker under kcov, with the paths its work, result,
// coverage and progress go to all starting with `prefix`.
fn startShard(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    args: args_mod.Args,
    exe_path: []const u8,
    seed: u64,
    prefix: []const u8,
    items: []const worker.WorkItem,
    is_watched: bool,
) !std.process.Child {
    const work_path = try std.fmt.allocPrint(allocator, "{s}.work", .{prefix});
    const result_path = try std.fmt.allocPrint(allocator, "{s}.result", .{prefix});
    const progress_path = try std.fmt.allocPrint(allocator, "{s}.progress", .{prefix});

    var work: std.Io.Writer.Allocating = .init(allocator);
    try worker.writeWork(&work.writer, items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = work_path, .data = work.written() });
    std.Io.Dir.cwd().deleteFile(io, progress_path) catch {};

    const seed_text = try std.fmt.allocPrint(allocator, "{d}", .{seed});
    var worker_args: std.ArrayList([]const u8) = .empty;
    try worker_args.appendSlice(allocator, &.{
        "--worker",
        "--work",
        work_path,
        "--result",
        result_path,
        "--seed",
        seed_text,
        "--sources-root",
        args.sources_root,
    });
    if (is_watched) {
        try worker_args.appendSlice(allocator, &.{ "--progress-file", progress_path });
    }
    const out_dir = try std.fmt.allocPrint(allocator, "{s}.kcov", .{prefix});
    return kcov_run.startWorker(allocator, io, .{
        .kcov = args.kcov orelse kcov_run.default_kcov,
        .out_dir = out_dir,
        .sources_root = args.sources_root,
        .worker = exe_path,
        .worker_args = worker_args.items,
        .environ_map = environ_map,
    });
}

// What the progress line carries from one pass to the next, so its count and its time are of the
// whole run and do not start again with every pass.
pub const RunProgress = struct {
    // How many calls the passes before this one finished.
    calls_before: usize = 0,

    // When the run started.
    started_at: std.Io.Clock.Timestamp,
};

// Sets `calls` to how many calls each shard's worker has finished, as its progress file says. A
// worker rewrites its file while the driver may be reading it, so a file that is missing or half
// written leaves that shard's count as it was, and the line never counts backwards.
pub fn readShardCalls(allocator: std.mem.Allocator, io: std.Io, prefixes: []const []const u8, calls: []usize) void {
    var buffer: [2048]u8 = undefined;
    for (prefixes, calls) |prefix, *count| {
        const path = std.fmt.bufPrint(&buffer, "{s}.progress", .{prefix}) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024)) catch continue;
        defer allocator.free(text);
        const read = worker.readProgress(text) orelse continue;
        count.* = @max(count.*, read.calls);
    }
}

// Prints one progress line for every worker of a pass: the calls the run has finished, which are
// the earlier passes' and `shard_calls`, how long it has been going, and the file and function of
// the last running worker that has said where it is.
fn printPassProgress(allocator: std.mem.Allocator, io: std.Io, progress: RunProgress, shard_calls: []const usize, prefixes: []const []const u8, children: []const ?std.process.Child) void {
    var calls: usize = progress.calls_before;
    for (shard_calls) |count| {
        calls += count;
    }
    var file: []const u8 = "";
    var function: []const u8 = "";
    var buffer: [2048]u8 = undefined;
    var latest: [1024]u8 = undefined;
    for (prefixes, children) |prefix, child| {
        const path = std.fmt.bufPrint(&buffer, "{s}.progress", .{prefix}) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024)) catch continue;
        defer allocator.free(text);
        const read = worker.readProgress(text) orelse continue;
        if (child != null and read.file.len != 0) {
            const both = std.fmt.bufPrint(&latest, "{s}\t{s}", .{ read.file, read.function }) catch continue;
            file = both[0..read.file.len];
            function = both[read.file.len + 1 ..];
        }
    }
    if (calls == 0) {
        return;
    }
    const elapsed = progress.started_at.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    var elapsed_buffer: [32]u8 = undefined;
    output_mod.printProgress("  Exercised {d} call{s} in {s}, now in {s} {s}.", .{
        calls,
        if (calls == 1) "" else "s",
        worker.elapsedText(&elapsed_buffer, @intCast(elapsed.raw.nanoseconds)),
        file,
        function,
    });
}

// Reads what the shard of `shard_file` whose paths start with `prefix` found and which lines it
// ran, adds both to what the run has so far and records them for the results cache.
pub fn mergeShard(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.Args,
    prefix: []const u8,
    shard_file: []const u8,
    checklists: []coverage.Checklist,
    standings: []Standing,
    failures: *std.ArrayList(worker.Failure),
    record: *run_cache.Record,
) !void {
    const out_dir = try std.fmt.allocPrint(allocator, "{s}.kcov", .{prefix});
    const coverage_path = try kcov_run.coveragePathOf(allocator, out_dir);
    var covered = try covered_lines.readCobertura(allocator, io, coverage_path);
    defer covered.deinit();
    coverage.tickFromCovered(checklists, &covered, args.sources_root);

    const result_path = try std.fmt.allocPrint(allocator, "{s}.result", .{prefix});
    const result_text = try std.Io.Dir.cwd().readFileAlloc(io, result_path, allocator, .unlimited);
    const results = try worker.readResults(allocator, result_text);
    try addResults(allocator, results, standings, failures);
    try record.add(allocator, shard_file, results, &covered, args.sources_root, checklists);
}

// Adds what a worker found to the run's standings and failures. A failure another shard already
// reported is not added again.
pub fn addResults(allocator: std.mem.Allocator, results: worker.Results, standings: []Standing, failures: *std.ArrayList(worker.Failure)) !void {
    try addFindings(allocator, results.tallies, results.failures, standings, failures);
}

// Adds tallies and failures to the run's standings and failures, as `addResults` does, for a caller
// that holds them without a `Results` around them.
pub fn addFindings(allocator: std.mem.Allocator, tallies: []const worker.Tally, found: []const worker.Failure, standings: []Standing, failures: *std.ArrayList(worker.Failure)) !void {
    for (tallies) |tally| {
        standings[tally.index].calls += tally.calls;
        standings[tally.index].specifications += tally.specifications;
        standings[tally.index].was_called = true;
    }
    for (found) |failure| {
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
}

pub fn readSource(allocator: std.mem.Allocator, io: std.Io, sources_root: []const u8, file: []const u8) ![:0]u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, sources_root, .{});
    defer directory.close(io);
    return directory.readFileAllocOptions(io, file, allocator, .unlimited, .of(u8), 0);
}

// How many specifications a function's calls take in round `round`: a small first round that holds
// its first values and the start of its single changes, then twice as many each round, so a function
// done early costs few calls and one that is not reaches its last specification in few rounds.
pub fn roundSize(round: usize) usize {
    // Large enough to hold a typical function's first values and single changes, so most functions
    // are done after one round.
    const first_round_size: usize = 32;
    // Twenty doublings is far beyond any function's count of specifications, and keeps the shift
    // from overflowing.
    const shift: u6 = @intCast(@min(round - 1, 20));
    return first_round_size << shift;
}

// Whether `file` has a code path not exercised in a function Faultline does not call itself, one
// that is not named in `called`. Such a function runs only through the callers in its file, so
// those callers are given the combinations of values that might reach it.
pub fn hasUntickedPathOutside(checklists: []const coverage.Checklist, file: []const u8, called: []const []const u8) bool {
    for (checklists) |one| {
        if (!std.mem.eql(u8, one.file, file) or one.allTicked()) {
            continue;
        }
        if (!containsName(called, one.function)) {
            return true;
        }
    }
    return false;
}

// Whether `file` declares a function called `name` in its own source: whether it has a checklist.
pub fn hasChecklist(checklists: []const coverage.Checklist, file: []const u8, name: []const u8) bool {
    const bare = selection_mod.bareName(name);
    for (checklists) |one| {
        if (std.mem.eql(u8, one.file, file) and std.mem.eql(u8, one.function, bare)) {
            return true;
        }
    }
    return false;
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

// The view of a crash (`crash_view.zig`): where it happened, the code, the callers and a hint. It
// replays the call once more, in a program of its own that writes the stack trace, which the calls
// of a run never do because it is slow. Null when the replay did not crash or its trace has no
// frame to show.
fn crashViewOf(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, args: args_mod.Args, style: style_mod.Style, failure: worker.Failure, command: []const u8) !?[]const u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    const replayed = std.process.run(allocator, io, .{
        .argv = &.{ exe_path, "--replay", failure.token, "--trace", "--sources-root", args.sources_root, "--repository", args.repository },
        // Far more than any trace a crash writes, which is a few lines for each frame.
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return null;
    // Faultline writes what it prints on its error stream, and the trace goes with it.
    const trace = try crash_view.parse(allocator, try std.mem.concat(allocator, u8, &.{ replayed.stdout, replayed.stderr }));
    if (trace.stack.len == 0) {
        return null;
    }
    var text: std.Io.Writer.Allocating = .init(allocator);
    try crash_view.write(&text.writer, allocator, io, trace, .{
        .subject = subjectName(Subject, failure),
        .subject_file = subjectFile(Subject, failure),
        .token = failure.token,
        .parameters = try parametersOf(Subject, allocator, io, args, failure, trace.arguments),
        .command = command,
        .sources_root = args.sources_root,
        .repository = args.repository,
        .style = style,
    });
    return text.written();
}

// The file of what a failure is about, relative to the project root.
fn subjectFile(comptime Subject: type, failure: worker.Failure) []const u8 {
    if (failure.is_scenario) {
        if (comptime Subject.scenario_entries.len == 0) {
            return "";
        }
        return Subject.scenario_entries[failure.index].file;
    }
    if (comptime Subject.function_entries.len == 0) {
        return "";
    }
    return Subject.function_entries[failure.index].file;
}

// What a failed call was made with, one per parameter: its name from the function's declaration,
// and either the value factory that filled it, with where it is, or the value the call wrote. Empty for a scenario or a token that cannot be read.
fn parametersOf(
    comptime Subject: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.Args,
    failure: worker.Failure,
    values: []const []const u8,
) ![]const crash_view.Parameter {
    if (failure.is_scenario or comptime Subject.function_entries.len == 0) {
        return &.{};
    }
    var plan = plan_mod.parse(allocator, failure.token) catch return &.{};
    defer plan.deinit();
    const entry = Subject.function_entries[failure.index];
    const source = readSource(allocator, io, args.sources_root, entry.file) catch "";
    const names = crash_view.parameterNames(allocator, source, entry.name) catch &.{};

    var parameters: std.ArrayList(crash_view.Parameter) = .empty;
    for (plan.choices, 0..) |choice, position| {
        var parameter: crash_view.Parameter = .{
            .name = if (position < names.len) names[position] else try std.fmt.allocPrint(allocator, "parameter {d}", .{position + 1}),
            .value = if (position < values.len) values[position] else "",
        };
        if (choice.source == .factory) {
            if (entry.factory_of(position, choice.index)) |factory| {
                const file = if (factory.namespace < entry.factory_files.len) entry.factory_files[factory.namespace] else "";
                const sim_source = readSource(allocator, io, args.sources_root, file) catch "";
                parameter.factory = .{
                    .name = factory.name,
                    .file = file,
                    .line = (try crash_view.factoryLine(allocator, sim_source, factory.name)) orelse 0,
                };
            }
        }
        try parameters.append(allocator, parameter);
    }
    return parameters.items;
}

// Says how many files' results came from the cache. Silent when none did.
fn printLoaded(cache: run_cache.State) void {
    const counts = cache.loadedCounts();
    if (counts.sources + counts.simulations == 0) {
        return;
    }
    output_mod.print("  Loaded the results of {d} source file{s} and {d} sim file{s} from the cache. Neither they nor anything they depend on changed since the run that proved them, so they were not executed again.\n", .{
        counts.sources,
        plural(counts.sources),
        counts.simulations,
        plural(counts.simulations),
    });
}

// Whether `left` is listed before `right`: functions before scenarios, each in table order.
// Failures of the same function or scenario keep the order they were found in, because the sort is
// stable.
fn isFailureBefore(_: void, left: worker.Failure, right: worker.Failure) bool {
    if (left.is_scenario != right.is_scenario) {
        return !left.is_scenario;
    }
    return left.index < right.index;
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
    cache: run_cache.State,
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
            if (cache.isLoaded(one.file)) {
                output_mod.print("\n  {s} (from the cache)\n", .{one.file});
            } else {
                output_mod.print("\n  {s}\n", .{one.file});
            }
            previous_file = one.file;
        }
        const ticked = one.tickedCount();
        const total = one.provableCount();
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
        // A function Faultline cannot call whose code paths its callers already exercised needs
        // nothing more.
        if (!hasUntickedPath(checklists, entry.file, entry.name)) {
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
        try writeFullReport(Subject, allocator, io, report_path, checklists, failures, items.items);
    }

    // Failures come first, because a function that crashed is more urgent than a code path that
    // was not reached.
    if (failures.len != 0) {
        output_mod.print("\n", .{});
        const shown = @min(failures.len, failure_limit);
        for (failures[0..shown], 0..) |failure, position| {
            if (failure.kind == .crash) {
                if (try crashViewOf(Subject, allocator, io, args, style, failure, "zig build flt")) |view| {
                    output_mod.print("{s}{s}\n", .{ if (position == 0) "" else "\n", view });
                    report_mod.printReplay(failure.token);
                    continue;
                }
            }
            report_mod.printFailure(failure, subjectName(Subject, failure));
        }
        // How many more there are is said with the counts at the end of the report.
    }

    checklist_mod.print(items.items, style);
    report_mod.printFailureCounts(failures, style);
    checklist_mod.printCoverage(counts.ticked, counts.total, style);
    report_mod.printTimeTaken(@intCast(@max(elapsed_nanoseconds, 0)));
    // The one place the path is printed: at the end, where it is read after everything above
    // points to the report file.
    if (args.report) |report_path| {
        output_mod.print("\n  Every failure and every thing to do is in {s}.\n", .{report_path});
    }
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

// Writes every code path, exercised or not, every failure and every thing to do to the report
// file.
pub fn writeFullReport(
    comptime Subject: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    checklists: []const coverage.Checklist,
    failures: []const worker.Failure,
    items: []const checklist_mod.Item,
) !void {
    var text: std.Io.Writer.Allocating = .init(allocator);
    for (checklists) |one| {
        for (one.paths, one.ticked) |code_path, is_ticked| {
            const state = if (is_ticked) "exercised" else if (code_path.line_missing) "not provable" else "not exercised";
            try text.writer.print("{s} {s}:{d} {s} in {s}\n", .{ state, one.file, code_path.line, code_path.name, one.function });
        }
    }
    for (failures) |failure| {
        try text.writer.print("failed {s} {s}: {s} {s}\n", .{ subjectName(Subject, failure), @tagName(failure.kind), failure.complaint, failure.text });
        try text.writer.print("  replay with -Dreplay=\"{s}\"\n", .{failure.token});
    }
    try checklist_mod.writeAll(&text.writer, items);
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
}

test {
    _ = @import("driver.test.zig");
}
