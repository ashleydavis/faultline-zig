// Connects the results cache (`results_cache.zig`) to a run: works out the key of every file, reads
// the results kept of earlier runs, decides which files run again, puts the result of each file
// that does not into the run as if the run had found it, gives the answers kept crashes already
// have, records what each file that runs finds and how each kept crash was answered, and keeps
// that when the run ends.

const std = @import("std");
const builtin = @import("builtin");
const args_mod = @import("args.zig");
const coverage = @import("coverage.zig");
const covered_lines = @import("covered_lines.zig");
const driver = @import("driver.zig");
const module_table = @import("../cmd/module_table.zig");
const project_mod = @import("project.zig");
const results_cache = @import("results_cache.zig");
const worker = @import("worker.zig");

// Whether a run uses the results cache: one was named, it was not turned off and the run is of the
// whole project. A run narrowed to one file or one function makes fewer calls than a whole run, so
// its results are not those of a whole run and are neither used nor kept.
pub fn isUsed(args: args_mod.Args) bool {
    return args.results_cache != null and !args.no_cache and args.only_file == null and args.only_function == null;
}

// Which files of a run have results from the cache and which run.
pub const State = struct {
    // Every file a result can be kept for, sim files after source files.
    units: []const results_cache.Unit = &.{},

    // Parallel to `units`: whether the file runs in this run.
    to_run: []const bool = &.{},

    // The answers kept crashes already have: the crashes of every file whose stored result has the
    // key the file has now, whether or not that result is used, and the kept crashes that result
    // answered. Each failure's index is into the run's tables.
    answers: []const results_cache.Replay = &.{},

    // The traces of the crashes of every file whose stored result has the key the file has now,
    // which the crash view is made from.
    traces: []const results_cache.Trace = &.{},

    // The trace kept for the crash `token`, or null when it has to be replayed for one.
    pub fn traceOf(self: State, token: []const u8) ?[]const u8 {
        for (self.traces) |trace| {
            if (std.mem.eql(u8, trace.token, token)) {
                return trace.text;
            }
        }
        return null;
    }

    // The answer `token` already has, or null when it has to be replayed.
    pub fn answerOf(self: State, token: []const u8) ?results_cache.Replay {
        for (self.answers) |answer| {
            if (std.mem.eql(u8, answer.token, token)) {
                return answer;
            }
        }
        return null;
    }

    // Whether the result of `file` came from the cache.
    pub fn isLoaded(self: State, file: []const u8) bool {
        for (self.units, self.to_run) |unit, runs| {
            if (std.mem.eql(u8, unit.file, file)) {
                return !runs;
            }
        }
        return false;
    }

    // How many source files and how many sim files have results from the cache.
    pub fn loadedCounts(self: State) struct { sources: usize, simulations: usize } {
        var sources: usize = 0;
        var simulations: usize = 0;
        for (self.units, self.to_run) |unit, runs| {
            if (runs) {
                continue;
            }
            if (std.mem.endsWith(u8, unit.file, ".sim.zig")) {
                simulations += 1;
            } else {
                sources += 1;
            }
        }
        return .{ .sources = sources, .simulations = simulations };
    }
};

// Works out the key of every source file and sim file, reads what the cache in `directory` holds
// for each and decides which run.
pub fn prepare(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, args: args_mod.Args, directory: []const u8, checklists: []const coverage.Checklist) !State {
    const modules_path = try std.fs.path.join(allocator, &.{ args.sources_root, module_table.file_name });
    const modules_text = std.Io.Dir.cwd().readFileAlloc(io, modules_path, allocator, .unlimited) catch "";
    const inputs: results_cache.KeyInputs = .{
        .sources_root = args.sources_root,
        .repository = args.repository,
        .modules = try module_table.parse(allocator, modules_text),
        .salt = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ args.cache_salt, builtin.zig_version_string }),
    };

    var globals: std.ArrayList([]const u8) = .empty;
    for (Subject.simulation_files) |simulation| {
        if (std.mem.eql(u8, std.fs.path.basename(simulation.path), project_mod.global_sim_name)) {
            try globals.append(allocator, simulation.path);
        }
    }

    var units: std.ArrayList(results_cache.Unit) = .empty;
    for (Subject.source_files) |file| {
        var roots: std.ArrayList([]const u8) = .empty;
        try roots.append(allocator, file);
        for (Subject.simulation_files) |simulation| {
            if (std.mem.eql(u8, simulation.source, file)) {
                try roots.append(allocator, simulation.path);
            }
        }
        try roots.appendSlice(allocator, globals.items);
        const entry = try readStored(allocator, io, directory, file);
        try units.append(allocator, .{
            .file = file,
            .key = try results_cache.keyOf(allocator, io, inputs, roots.items),
            .entry = if (entry) |stored| (if (fitsSource(Subject, stored, checklists)) stored else null) else null,
        });
    }
    for (Subject.simulation_files) |simulation| {
        var roots: std.ArrayList([]const u8) = .empty;
        try roots.append(allocator, simulation.path);
        try roots.appendSlice(allocator, globals.items);
        const entry = try readStored(allocator, io, directory, simulation.path);
        try units.append(allocator, .{
            .file = simulation.path,
            .key = try results_cache.keyOf(allocator, io, inputs, roots.items),
            .entry = if (entry) |stored| (if (fitsSimulation(Subject, stored)) stored else null) else null,
        });
    }
    return .{
        .units = units.items,
        .to_run = try results_cache.unitsToRun(allocator, units.items),
        .answers = try answersOf(Subject, allocator, units.items),
        .traces = try tracesOf(allocator, units.items),
    };
}

// The traces in the stored results of `units` made with the key each file has now.
pub fn tracesOf(allocator: std.mem.Allocator, units: []const results_cache.Unit) ![]const results_cache.Trace {
    var traces: std.ArrayList(results_cache.Trace) = .empty;
    for (units) |unit| {
        const entry = unit.entry orelse continue;
        const key = unit.key orelse continue;
        if (entry.key != key) {
            continue;
        }
        try traces.appendSlice(allocator, entry.traces);
    }
    return traces.toOwnedSlice(allocator);
}

// The answers kept crashes have in the stored results of `units` made with the key each file has
// now: every crash a result holds, which is the answer of the call its token names, and every kept
// crash it answered. A result made with another key holds answers the file's code may no longer
// give, so it gives none.
pub fn answersOf(comptime Subject: type, allocator: std.mem.Allocator, units: []const results_cache.Unit) ![]const results_cache.Replay {
    var answers: std.ArrayList(results_cache.Replay) = .empty;
    for (units) |unit| {
        const entry = unit.entry orelse continue;
        const key = unit.key orelse continue;
        if (entry.key != key) {
            continue;
        }
        for (entry.failures) |failure| {
            if (failure.kind != .crash) {
                continue;
            }
            try answers.append(allocator, .{ .token = failure.token, .failure = inTables(Subject, entry.file, failure) });
        }
        for (entry.replays) |replay| {
            try answers.append(allocator, .{
                .token = replay.token,
                .failure = if (replay.failure) |failure| inTables(Subject, entry.file, failure) else null,
            });
        }
    }
    return answers.toOwnedSlice(allocator);
}

// `failure` of `file`, kept with its index counted from the file's first function or scenario,
// with its index into the run's tables.
fn inTables(comptime Subject: type, file: []const u8, failure: worker.Failure) worker.Failure {
    var placed = failure;
    placed.index += if (failure.is_scenario) firstScenario(Subject, file) else firstFunction(Subject, file);
    return placed;
}

// The result kept for `file`, or null when there is none or it cannot be read.
fn readStored(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, file: []const u8) !?results_cache.Entry {
    const path = try results_cache.entryPath(allocator, directory, file);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return null;
    return results_cache.readEntry(allocator, text);
}

// Whether a source file's stored result fits the file's functions and checklists in this run. A key
// that matches means it does, so this only guards against a result that does not, which is never
// used.
fn fitsSource(comptime Subject: type, entry: results_cache.Entry, checklists: []const coverage.Checklist) bool {
    const count = functionCount(Subject, entry.file);
    for (entry.tallies) |tally| {
        if (tally.index >= count) {
            return false;
        }
    }
    for (entry.failures) |failure| {
        if (failure.is_scenario or failure.index >= count) {
            return false;
        }
    }
    var position: usize = 0;
    for (checklists) |one| {
        if (!std.mem.eql(u8, one.file, entry.file)) {
            continue;
        }
        if (position >= entry.marks.len) {
            return false;
        }
        const marks = entry.marks[position];
        if (!std.mem.eql(u8, marks.function, one.function) or marks.marks.len != one.paths.len) {
            return false;
        }
        position += 1;
    }
    return position == entry.marks.len;
}

// Whether a sim file's stored result fits the file's scenarios in this run.
fn fitsSimulation(comptime Subject: type, entry: results_cache.Entry) bool {
    if (entry.tallies.len != 0 or entry.marks.len != 0) {
        return false;
    }
    const count = scenarioCount(Subject, entry.file);
    for (entry.failures) |failure| {
        if (!failure.is_scenario or failure.index >= count) {
            return false;
        }
    }
    return true;
}

// Puts the result of every file that does not run into the run: its tallies into the standings, its
// failures into the failures and its code paths into the checklists.
pub fn load(comptime Subject: type, allocator: std.mem.Allocator, state: State, checklists: []coverage.Checklist, standings: []driver.Standing, failures: *std.ArrayList(worker.Failure)) !void {
    for (state.units, state.to_run) |unit, runs| {
        if (runs) {
            continue;
        }
        const entry = unit.entry orelse continue;
        const function_base = firstFunction(Subject, entry.file);
        const scenario_base = firstScenario(Subject, entry.file);
        const tallies = try allocator.dupe(worker.Tally, entry.tallies);
        for (tallies) |*tally| {
            tally.index += function_base;
        }
        const found = try allocator.dupe(worker.Failure, entry.failures);
        for (found) |*failure| {
            failure.index += if (failure.is_scenario) scenario_base else function_base;
        }
        try driver.addFindings(allocator, tallies, found, standings, failures);

        var position: usize = 0;
        for (checklists) |*one| {
            if (!std.mem.eql(u8, one.file, entry.file)) {
                continue;
            }
            for (entry.marks[position].marks, one.ticked, one.paths) |mark, *ticked, *path| {
                ticked.* = ticked.* or mark == 't';
                path.line_missing = mark == 'm';
            }
            position += 1;
        }
    }
}

// What the files run in this run found, kept so each one's result can be stored when the run ends.
pub const Record = struct {
    // Per file a worker ran: the tallies and failures its workers found, across every pass.
    findings: std.StringArrayHashMapUnmanaged(Findings) = .empty,

    // Per source file: the files whose workers ran any of its lines.
    contributors: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty,

    // Per file: how each of its kept crashes was answered in this run, replayed or already known,
    // with indexes into the run's tables.
    replays: std.StringArrayHashMapUnmanaged(std.ArrayList(results_cache.Replay)) = .empty,

    // Per file: the trace of the crash this run shows first, when it is one of the file's.
    traces: std.StringArrayHashMapUnmanaged(std.ArrayList(results_cache.Trace)) = .empty,

    // Adds the trace of a crash of `file`.
    pub fn addTrace(self: *Record, allocator: std.mem.Allocator, file: []const u8, trace: results_cache.Trace) !void {
        const slot = try self.traces.getOrPut(allocator, file);
        if (!slot.found_existing) {
            slot.value_ptr.* = .empty;
        }
        try slot.value_ptr.append(allocator, trace);
    }

    // Adds how the kept crash of `file` with `replay.token` was answered.
    pub fn addReplay(self: *Record, allocator: std.mem.Allocator, file: []const u8, replay: results_cache.Replay) !void {
        const slot = try self.replays.getOrPut(allocator, file);
        if (!slot.found_existing) {
            slot.value_ptr.* = .empty;
        }
        try slot.value_ptr.append(allocator, replay);
    }

    // Adds what the worker of `shard_file` found and which lines it ran.
    pub fn add(
        self: *Record,
        allocator: std.mem.Allocator,
        shard_file: []const u8,
        results: worker.Results,
        covered: *const covered_lines.CoveredLines,
        sources_root: []const u8,
        checklists: []const coverage.Checklist,
    ) !void {
        const slot = try self.findings.getOrPut(allocator, shard_file);
        if (!slot.found_existing) {
            slot.value_ptr.* = .{};
        }
        try slot.value_ptr.tallies.appendSlice(allocator, results.tallies);
        try slot.value_ptr.failures.appendSlice(allocator, results.failures);

        var previous: []const u8 = "";
        for (checklists) |one| {
            if (std.mem.eql(u8, one.file, previous)) {
                continue;
            }
            previous = one.file;
            const lines = covered.linesFor(sources_root, one.file) orelse continue;
            if (lines.hit.count() == 0) {
                continue;
            }
            const set = try self.contributors.getOrPut(allocator, one.file);
            if (!set.found_existing) {
                set.value_ptr.* = .empty;
            }
            try set.value_ptr.put(allocator, shard_file, {});
        }
    }
};

// The tallies and failures of one file, with indexes into the run's tables.
pub const Findings = struct {
    tallies: std.ArrayList(worker.Tally) = .empty,
    failures: std.ArrayList(worker.Failure) = .empty,
};

// Keeps in `directory` the result of every file that ran and has a key, with how its kept crashes
// were answered and the trace of its crash this run showed first. A source file one of whose
// contributors has no key keeps none, because no later run could tell whether that file changed. A
// file whose result came from the cache keeps that result, written again with what this run
// recorded of it when it recorded anything.
pub fn store(comptime Subject: type, allocator: std.mem.Allocator, io: std.Io, directory: []const u8, state: State, record: *const Record, checklists: []const coverage.Checklist) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    units: for (state.units, state.to_run) |unit, runs| {
        if (!runs) {
            const answered = record.replays.get(unit.file);
            const traced = record.traces.get(unit.file);
            if (answered == null and traced == null) {
                continue;
            }
            var loaded = unit.entry orelse continue;
            if (answered) |list| {
                loaded.replays = try keptReplays(Subject, allocator, unit.file, list.items);
            }
            if (traced) |list| {
                loaded.traces = list.items;
            }
            try writeStored(allocator, io, directory, loaded);
            continue;
        }
        const key = unit.key orelse continue;

        var contributors: std.ArrayList(results_cache.Contributor) = .empty;
        if (record.contributors.get(unit.file)) |set| {
            for (set.keys()) |file| {
                const contributor_key = keyIn(state, file) orelse continue :units;
                try contributors.append(allocator, .{ .file = file, .key = contributor_key });
            }
        }

        var marks: std.ArrayList(results_cache.Marks) = .empty;
        for (checklists) |one| {
            if (!std.mem.eql(u8, one.file, unit.file)) {
                continue;
            }
            const text = try allocator.alloc(u8, one.paths.len);
            for (text, one.ticked, one.paths) |*mark, ticked, path| {
                mark.* = if (ticked) 't' else if (path.line_missing) 'm' else '.';
            }
            try marks.append(allocator, .{ .function = one.function, .marks = text });
        }

        var tallies: []worker.Tally = &.{};
        var found: []worker.Failure = &.{};
        if (record.findings.get(unit.file)) |findings| {
            const function_base = firstFunction(Subject, unit.file);
            const scenario_base = firstScenario(Subject, unit.file);
            tallies = try allocator.dupe(worker.Tally, findings.tallies.items);
            for (tallies) |*tally| {
                tally.index -= function_base;
            }
            found = try allocator.dupe(worker.Failure, findings.failures.items);
            for (found) |*failure| {
                failure.index -= if (failure.is_scenario) scenario_base else function_base;
            }
        }

        const answered = if (record.replays.get(unit.file)) |list| list.items else &.{};
        try writeStored(allocator, io, directory, .{
            .file = unit.file,
            .key = key,
            .contributors = contributors.items,
            .marks = marks.items,
            .tallies = tallies,
            .failures = found,
            .replays = try keptReplays(Subject, allocator, unit.file, answered),
            .traces = if (record.traces.get(unit.file)) |list| list.items else &.{},
        });
    }
}

// Writes `entry` to its file under `directory`.
fn writeStored(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, entry: results_cache.Entry) !void {
    var text: std.Io.Writer.Allocating = .init(allocator);
    try results_cache.writeEntry(&text.writer, entry);
    const path = try results_cache.entryPath(allocator, directory, entry.file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
}

// `replays` of `file` as a stored result keeps them: each failure's index counted from the file's
// first function or scenario.
fn keptReplays(comptime Subject: type, allocator: std.mem.Allocator, file: []const u8, replays: []const results_cache.Replay) ![]const results_cache.Replay {
    const kept = try allocator.dupe(results_cache.Replay, replays);
    for (kept) |*replay| {
        if (replay.failure) |*failure| {
            failure.index -= if (failure.is_scenario) firstScenario(Subject, file) else firstFunction(Subject, file);
        }
    }
    return kept;
}

fn keyIn(state: State, file: []const u8) ?u64 {
    for (state.units) |unit| {
        if (std.mem.eql(u8, unit.file, file)) {
            return unit.key;
        }
    }
    return null;
}

// The index in the function table of the first function of `file`, or zero when it has none.
fn firstFunction(comptime Subject: type, file: []const u8) usize {
    for (Subject.function_entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.file, file)) {
            return index;
        }
    }
    return 0;
}

// The index in the scenario table of the first scenario of `file`, or zero when it has none.
fn firstScenario(comptime Subject: type, file: []const u8) usize {
    for (Subject.scenario_entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.file, file)) {
            return index;
        }
    }
    return 0;
}

// How many functions `file` has in the function table.
fn functionCount(comptime Subject: type, file: []const u8) usize {
    var count: usize = 0;
    for (Subject.function_entries) |entry| {
        if (std.mem.eql(u8, entry.file, file)) {
            count += 1;
        }
    }
    return count;
}

// How many scenarios `file` has in the scenario table.
fn scenarioCount(comptime Subject: type, file: []const u8) usize {
    var count: usize = 0;
    for (Subject.scenario_entries) |entry| {
        if (std.mem.eql(u8, entry.file, file)) {
            count += 1;
        }
    }
    return count;
}

test {
    _ = @import("run_cache.test.zig");
}
