// The part of a run that happens inside the process kcov watches.
//
// A worker is given a list of work: functions to call and scenarios to run. For each function it
// lists the specifications for the parameters, and for each specification it explores the failures
// to inject (see `explore.zig`), making the calls one after another in a child process that is
// started again whenever a call crashes, hangs or exits. It writes down how
// many calls each function got and every failure it found, with the replay token for each, and the
// driver reads that after the worker exits.

const std = @import("std");
const linux = std.os.linux;
const call_mod = @import("call.zig");
const call_specs = @import("call_specs.zig");
const condition = @import("condition.zig");
const conditions_reader = @import("../cmd/conditions.zig");
const explore = @import("explore.zig");
const injector = @import("injector.zig");
const isolate = @import("isolate.zig");
const output_mod = @import("output.zig");
const plan_mod = @import("plan.zig");
const project = @import("project.zig");
const wire = @import("wire.zig");

// Which choices of values a function's calls are made with.
pub const Phase = enum {
    // The boundary values, the seeded values and the value factories, in every combination.
    normal,

    // Only the specifications that carry a value read from a condition in the function.
    conditions,
};

// One thing a worker is asked to do.
pub const WorkItem = union(enum) {
    // Call the function at this index of the project's function table.
    // `first` and `count` pick which of the function's specifications, in the order they are listed,
    // this item makes calls with, so a run can make them a round at a time.
    function: struct { index: usize, phase: Phase, first: usize = 0, count: usize = std.math.maxInt(usize) },

    // Run the scenario at this index of the project's scenario table.
    scenario: usize,
};

// How a call went wrong.
pub const FailureKind = enum {
    // The call ended with a signal or a non-zero exit: a panic, a crash or an abort.
    crash,

    // The call used its processor time or its wall time without returning.
    hang,

    // An expectation was false.
    expectation,
};

// One failure a worker found.
pub const Failure = struct {
    // Whether the failure was in a scenario and not a function.
    is_scenario: bool,

    // The index in the function table or the scenario table.
    index: usize,

    // How it went wrong.
    kind: FailureKind,

    // The replay token for the call that failed.
    token: []const u8,

    // For a crash, the signal that ended the child, or zero.
    signal: u32 = 0,

    // For a crash, the first line of what the child said on its error stream.
    complaint: []const u8 = "",

    // For an expectation, the function or scenario it was written in, and where.
    expectation_function: []const u8 = "",
    file: []const u8 = "",
    line: u32 = 0,
    text: []const u8 = "",
};

// How many calls a function got.
pub const Tally = struct {
    // The index in the function table.
    index: usize,

    // How many calls were made across every specification.
    calls: usize,

    // How many specifications were listed.
    specifications: usize,

    // Whether the limit on calls for some specification was reached.
    is_cut_short: bool,
};

// What a worker found.
pub const Results = struct {
    tallies: []Tally,
    failures: []Failure,

    // The memory behind the strings above.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Results) void {
        self.arena.deinit();
    }
};

// What a worker needs besides the work.
pub const Options = struct {
    // The seed the run's random numbers start from.
    seed: u64,

    // The directory the project's sources were copied to, for reading the conditions of functions.
    sources_root: []const u8,

    // How long a call may take.
    limits: isolate.Limits = isolate.default_limits,
};

// Whether anybody is watching: set once by the driver from whether stderr is a terminal. The line
// that says how far a run has got is for a person who cannot otherwise tell a slow run from a hung
// one, and in a log or a pipe it is only noise around the report.
pub var progress_is_watched: bool = false;

// How often the run says how far it has got. Measured in time and not in calls, because the line is
// rewritten in place: it has to keep up with a run that is moving and stay quiet on one that is not,
// and a function with slow calls would otherwise leave it silent for the whole of that function.
// Half a second is quick enough to look alive and slow enough not to flicker.
pub const progress_every_ns: u64 = 500 * std.time.ns_per_ms;

// When the first call finished and when the last progress line was written, on the monotonic clock.
// Read only to decide when to print and what the elapsed time is. Nothing a call does depends on it.
var progress_started_ns: u64 = 0;
var progress_last_ns: u64 = 0;

// How many calls have finished in this worker.
var progress_calls: usize = 0;

// The monotonic clock in nanoseconds.
fn nowNs() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

// How long the run has been going, as the fragment the progress line reads it back as: "9s" for
// under a minute and "2m 14s" above it. The buffer is the caller's, so this allocates nothing on a
// path that runs twice a second.
pub fn elapsedText(buffer: []u8, nanos: u64) []const u8 {
    const seconds = nanos / std.time.ns_per_s;
    if (seconds < 60) {
        return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch "a while";
    }
    return std.fmt.bufPrint(buffer, "{d}m {d}s", .{ seconds / 60, seconds % 60 }) catch "a while";
}

// Whether enough time has passed since the last progress line for another one.
pub fn isProgressDue(now_ns: u64, last_ns: u64) bool {
    return now_ns - last_ns >= progress_every_ns;
}

// Counts one finished call and, when somebody is watching and the last line is old enough, writes
// the line that says where the run has got to. `file` and `function` are what the call was of.
pub fn reportProgress(file: []const u8, function: []const u8) void {
    progress_calls += 1;
    if (!progress_is_watched) {
        return;
    }
    const now = nowNs();
    if (progress_started_ns == 0) {
        progress_started_ns = now;
    }
    if (!isProgressDue(now, progress_last_ns)) {
        return;
    }
    progress_last_ns = now;
    var buffer: [32]u8 = undefined;
    output_mod.printProgress("  Exercised {d} call{s} in {s}, now in {s} {s}.", .{
        progress_calls,
        if (progress_calls == 1) "" else "s",
        elapsedText(&buffer, now - progress_started_ns),
        file,
        function,
    });
}

// Starts the count again, for a worker that is run more than once in one process.
pub fn resetProgress() void {
    progress_started_ns = 0;
    progress_last_ns = 0;
    progress_calls = 0;
}

// The longest part of a child's complaint that is kept: the first line says what happened.
const complaint_bytes = 300;

// Does the work. `Subject` is a `project.Project(...)`.
pub fn run(comptime Subject: type, allocator: std.mem.Allocator, real_io: std.Io, options: Options, items: []const WorkItem) !Results {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const room = arena.allocator();

    var tallies: std.ArrayList(Tally) = .empty;
    var failures: std.ArrayList(Failure) = .empty;

    resetProgress();
    // Takes the progress line off the terminal when the work is done, so what the driver prints
    // next does not land on the end of it.
    defer output_mod.print("", .{});

    var resident: Residence = .{
        .runner = .{
            .entries = Subject.function_entries,
            .real_io = real_io,
            .sources_root = options.sources_root,
        },
    };
    defer resident.child.stop();

    for (items) |item| {
        switch (item) {
            .function => |function| {
                // A project with no functions has an empty table, which cannot be indexed.
                if (comptime Subject.function_entries.len == 0) {
                    continue;
                }
                const entry = Subject.function_entries[function.index];
                if (!entry.can_call) {
                    continue;
                }
                try runFunction(allocator, room, real_io, options, &resident, entry, function.index, function.phase, function.first, function.count, &tallies, &failures);
            },
            .scenario => |index| {
                if (comptime Subject.scenario_entries.len == 0) {
                    continue;
                }
                try runScenario(allocator, room, real_io, options, Subject.scenario_entries[index], index, &failures);
            },
        }
    }

    return .{
        .tallies = try tallies.toOwnedSlice(room),
        .failures = try failures.toOwnedSlice(room),
        .arena = arena,
    };
}

fn runFunction(
    allocator: std.mem.Allocator,
    room: std.mem.Allocator,
    real_io: std.Io,
    options: Options,
    resident: *Residence,
    entry: project.FunctionEntry,
    index: usize,
    phase: Phase,
    first: usize,
    count: usize,
    tallies: *std.ArrayList(Tally),
    failures: *std.ArrayList(Failure),
) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const conditions = if (phase == .conditions)
        readConditions(scratch.allocator(), real_io, options.sources_root, entry) catch &.{}
    else
        &.{};

    const specs = try entry.list_specs(scratch.allocator(), real_io, options.seed, conditions);
    var tally: Tally = .{ .index = index, .calls = 0, .specifications = 0, .is_cut_short = false };
    // How many of the specifications this phase takes have been seen, counting the one in hand.
    var position: usize = 0;
    for (specs) |spec| {
        if (phase == .conditions and !hasConditionChoice(spec)) {
            continue;
        }
        position += 1;
        if (position - 1 < first) {
            continue;
        }
        if (position - 1 - first >= count) {
            break;
        }
        tally.specifications += 1;
        var executor: Executor = .{
            .allocator = allocator,
            .room = room,
            .real_io = real_io,
            .options = options,
            .entry = entry,
            .index = index,
            .spec = spec,
            .conditions = conditions,
            .failures = failures,
            .resident = resident,
        };
        defer executor.deinit();
        const outcome = try explore.explore(allocator, &executor, explore.max_injections_per_call);
        tally.calls += outcome.calls;
        tally.is_cut_short = tally.is_cut_short or outcome.is_cut_short;
    }
    try tallies.append(room, tally);
}

// Whether a specification uses a value read from a condition.
fn hasConditionChoice(spec: call_specs.Spec) bool {
    for (spec) |choice| {
        if (choice.source == .condition) {
            return true;
        }
    }
    return false;
}

// Reads the conditions of a function from the copy of its source file.
pub fn readConditions(allocator: std.mem.Allocator, io: std.Io, sources_root: []const u8, entry: project.FunctionEntry) ![]const condition.Condition {
    var directory = try std.Io.Dir.cwd().openDir(io, sources_root, .{});
    defer directory.close(io);
    const source = try directory.readFileAllocOptions(io, entry.file, allocator, .unlimited, .of(u8), 0);
    const bare = if (std.mem.lastIndexOfScalar(u8, entry.name, '.')) |dot| entry.name[dot + 1 ..] else entry.name;
    return try conditions_reader.conditionsIn(allocator, source, bare);
}

// How many calls one child makes before it is replaced. Memory the code under test never frees
// stays taken in the child, so a child is replaced before that can add up. Starting a child costs
// about what one call does, so this many calls make that cost too small to see.
const max_calls_per_child = 1000;

// The child the calls of a worker are made in, started again after a call ends it.
const Residence = struct {
    // What the child runs for each call.
    runner: ResidentRunner,

    // The child, when one is running.
    child: isolate.Resident = .{},

    // Makes the call `token` names, of the function at `index` in the function table, in the child.
    fn attempt(self: *Residence, allocator: std.mem.Allocator, index: usize, token: []const u8, limits: isolate.Limits) !isolate.Attempt {
        if (self.child.isRunning() and self.child.calls >= max_calls_per_child) {
            self.child.stop();
        }
        if (!self.child.isRunning()) {
            self.child = try isolate.Resident.start(self.runner);
        }
        const request = try allocator.alloc(u8, 4 + token.len);
        defer allocator.free(request);
        std.mem.writeInt(u32, request[0..4], @intCast(index), .little);
        @memcpy(request[4..], token);
        return self.child.attempt(allocator, request, limits);
    }
};

// What a child that makes many calls runs for each one. A request is the index of the function in
// the function table followed by the replay token of the call, so the call made is the one a replay
// of that token makes.
const ResidentRunner = struct {
    // The project's function table.
    entries: []const project.FunctionEntry,

    // The real `Io` the simulated world is layered over.
    real_io: std.Io,

    // The directory the project's sources were copied to, for reading the conditions of functions.
    sources_root: []const u8,

    // The conditions of the function called last, kept because calls of one function come one
    // after another and reading them means parsing its source file.
    conditions_index: ?usize = null,
    conditions: []const condition.Condition = &.{},
    conditions_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),

    pub fn run(self: *ResidentRunner, request: []const u8, out: *std.Io.Writer) void {
        if (request.len < 4) {
            return;
        }
        const index = std.mem.readInt(u32, request[0..4], .little);
        if (index >= self.entries.len) {
            return;
        }
        const entry = self.entries[index];
        var plan = plan_mod.parse(std.heap.page_allocator, request[4..]) catch return;
        defer plan.deinit();
        var conditions: []const condition.Condition = &.{};
        if (hasConditionChoice(plan.choices)) {
            if (self.conditions_index != index) {
                _ = self.conditions_arena.reset(.free_all);
                self.conditions = readConditions(self.conditions_arena.allocator(), self.real_io, self.sources_root, entry) catch &.{};
                self.conditions_index = index;
            }
            conditions = self.conditions;
        }
        entry.run_here(.{
            .seed = plan.seed,
            .spec = plan.choices,
            .plan = plan.injections,
            .conditions = conditions,
            .real_io = self.real_io,
        }, out);
    }
};

// Makes the calls `explore` asks for and keeps what they show.
const Executor = struct {
    allocator: std.mem.Allocator,
    room: std.mem.Allocator,
    real_io: std.Io,
    options: Options,
    entry: project.FunctionEntry,
    index: usize,
    spec: call_specs.Spec,
    conditions: []const condition.Condition,
    failures: *std.ArrayList(Failure),

    // The child the calls are made in.
    resident: *Residence,

    // What the last call reported, kept until the next call so the places it names stay valid.
    last: ?wire.Report = null,

    fn deinit(self: *Executor) void {
        if (self.last) |*report| {
            report.deinit();
        }
    }

    pub fn call(self: *Executor, plan: []const injector.Injection) anyerror!explore.Observed {
        if (self.last) |*report| {
            report.deinit();
            self.last = null;
        }
        const token = try self.tokenFor(plan);
        var attempt = try self.resident.attempt(self.allocator, self.index, token, self.options.limits);
        defer attempt.deinit(self.allocator);
        reportProgress(self.entry.file, self.entry.name);

        var report = try wire.read(self.allocator, attempt.output);
        errdefer report.deinit();

        try keepFailure(self.room, self.failures, false, self.index, token, attempt, report);

        const is_dead_end = !attempt.isClean() or report.result == null;
        self.last = report;
        return .{ .is_dead_end = is_dead_end, .places = report.places };
    }

    pub fn seen(_: *Executor, _: []const injector.Injection, _: explore.Observed) void {}

    fn tokenFor(self: *Executor, plan: []const injector.Injection) ![]const u8 {
        const token_plan: plan_mod.Plan = .{
            .file = self.entry.file,
            .function = self.entry.name,
            .seed = self.options.seed,
            .choices = self.spec,
            .injections = plan,
        };
        return std.fmt.allocPrint(self.room, "{f}", .{token_plan});
    }
};

fn runScenario(
    allocator: std.mem.Allocator,
    room: std.mem.Allocator,
    real_io: std.Io,
    options: Options,
    entry: project.ScenarioEntry,
    index: usize,
    failures: *std.ArrayList(Failure),
) !void {
    var attempt = try entry.attempt(allocator, real_io, options.seed, options.limits);
    defer attempt.deinit(allocator);
    reportProgress(entry.file, entry.name);
    var report = try wire.read(allocator, attempt.output);
    defer report.deinit();

    const token_plan: plan_mod.Plan = .{
        .file = entry.file,
        .function = entry.name,
        .seed = options.seed,
        .choices = &.{},
        .injections = &.{},
    };
    const token = try std.fmt.allocPrint(room, "{f}", .{token_plan});
    try keepFailure(room, failures, true, index, token, attempt, report);
}

// Adds a failure to the list when the call that made `attempt` and `report` failed, and says
// nothing about one that has already been kept.
fn keepFailure(
    room: std.mem.Allocator,
    failures: *std.ArrayList(Failure),
    is_scenario: bool,
    index: usize,
    token: []const u8,
    attempt: isolate.Attempt,
    report: wire.Report,
) !void {
    const failure = (try failureOf(room, is_scenario, index, token, attempt, report)) orelse return;
    for (failures.items) |earlier| {
        if (isSameFailure(earlier, failure)) {
            return;
        }
    }
    try failures.append(room, failure);
}

// The failure a call came to, or null when it did not fail. A call fails when its child crashed,
// ran out of time or exited with a status, or when an expectation was false. A function that
// returns an error has not failed.
pub fn failureOf(
    room: std.mem.Allocator,
    is_scenario: bool,
    index: usize,
    token: []const u8,
    attempt: isolate.Attempt,
    report: wire.Report,
) !?Failure {
    var failure: Failure = .{ .is_scenario = is_scenario, .index = index, .kind = .crash, .token = token };

    if (!attempt.isClean()) {
        switch (attempt.ending) {
            .timed_out => failure.kind = .hang,
            .signaled => |signal| {
                if (signal == isolate.processor_limit_signal) {
                    failure.kind = .hang;
                } else {
                    failure.signal = signal;
                    failure.complaint = try firstLine(room, attempt.complaint);
                }
            },
            .exited => |status| {
                failure.signal = status;
                failure.complaint = try firstLine(room, attempt.complaint);
            },
        }
        return failure;
    }
    const result = report.result orelse return null;
    switch (result) {
        .expectation_failed => |failed| {
            failure.kind = .expectation;
            failure.expectation_function = try room.dupe(u8, failed.function);
            failure.file = try room.dupe(u8, failed.file);
            failure.line = failed.line;
            failure.text = try room.dupe(u8, failed.text);
            return failure;
        },
        else => return null,
    }
}

// Whether two failures are the same defect found by two calls: the same function and the same
// way of going wrong in the same place.
fn isSameFailure(a: Failure, b: Failure) bool {
    return a.is_scenario == b.is_scenario and
        a.index == b.index and
        a.kind == b.kind and
        a.signal == b.signal and
        a.line == b.line and
        std.mem.eql(u8, a.complaint, b.complaint) and
        std.mem.eql(u8, a.expectation_function, b.expectation_function) and
        std.mem.eql(u8, a.file, b.file) and
        std.mem.eql(u8, a.text, b.text);
}

// The first line of a child's complaint, cut to a length worth printing. The "thread <number> "
// that the standard library puts in front of a panic message is left out, because the number is
// different for every child and would make the same crash look like a different one each time.
pub fn firstLine(room: std.mem.Allocator, text: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            continue;
        }
        trimmed = withoutThreadNumber(trimmed);
        return room.dupe(u8, trimmed[0..@min(trimmed.len, complaint_bytes)]);
    }
    return "";
}

// `thread 4242 panic: x` without the `thread 4242 `.
fn withoutThreadNumber(line: []const u8) []const u8 {
    const prefix = "thread ";
    if (!std.mem.startsWith(u8, line, prefix)) {
        return line;
    }
    var end = prefix.len;
    while (end < line.len and std.ascii.isDigit(line[end])) {
        end += 1;
    }
    if (end == prefix.len or end >= line.len or line[end] != ' ') {
        return line;
    }
    return line[end + 1 ..];
}

// Writes the work as text, one item to a line.
pub fn writeWork(writer: *std.Io.Writer, items: []const WorkItem) std.Io.Writer.Error!void {
    for (items) |item| {
        switch (item) {
            .function => |function| try writer.print("F\t{d}\t{s}\t{d}\t{d}\n", .{ function.index, @tagName(function.phase), function.first, function.count }),
            .scenario => |index| try writer.print("S\t{d}\n", .{index}),
        }
    }
}

// Reads work written by `writeWork`. A line that does not parse is passed over.
pub fn readWork(allocator: std.mem.Allocator, text: []const u8) ![]WorkItem {
    var items: std.ArrayList(WorkItem) = .empty;
    errdefer items.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const tag = fields.next() orelse continue;
        const index_text = fields.next() orelse continue;
        const index = std.fmt.parseInt(usize, index_text, 10) catch continue;
        if (std.mem.eql(u8, tag, "F")) {
            const phase_text = fields.next() orelse continue;
            const phase = std.meta.stringToEnum(Phase, phase_text) orelse continue;
            const first = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch continue;
            const count = std.fmt.parseInt(usize, fields.next() orelse "", 10) catch std.math.maxInt(usize);
            try items.append(allocator, .{ .function = .{ .index = index, .phase = phase, .first = first, .count = count } });
        } else if (std.mem.eql(u8, tag, "S")) {
            try items.append(allocator, .{ .scenario = index });
        }
    }
    return items.toOwnedSlice(allocator);
}

// Writes what a worker found as text.
pub fn writeResults(writer: *std.Io.Writer, results: Results) std.Io.Writer.Error!void {
    for (results.tallies) |tally| {
        try writer.print("N\t{d}\t{d}\t{d}\t{d}\n", .{ tally.index, tally.calls, tally.specifications, @intFromBool(tally.is_cut_short) });
    }
    for (results.failures) |failure| {
        try writer.print("X\t{s}\t{d}\t{s}\t{d}\t", .{
            if (failure.is_scenario) "scenario" else "function",
            failure.index,
            @tagName(failure.kind),
            failure.signal,
        });
        try wire.writeField(writer, failure.token);
        try writer.writeByte('\t');
        try wire.writeField(writer, failure.complaint);
        try writer.writeByte('\t');
        try wire.writeField(writer, failure.expectation_function);
        try writer.writeByte('\t');
        try wire.writeField(writer, failure.file);
        try writer.print("\t{d}\t", .{failure.line});
        try wire.writeField(writer, failure.text);
        try writer.writeByte('\n');
    }
}

// Reads what `writeResults` wrote. A line that does not parse is passed over.
pub fn readResults(allocator: std.mem.Allocator, text: []const u8) !Results {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const room = arena.allocator();
    var tallies: std.ArrayList(Tally) = .empty;
    var failures: std.ArrayList(Failure) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const tag = fields.next() orelse continue;
        if (std.mem.eql(u8, tag, "N")) {
            const index = parseNext(usize, &fields) orelse continue;
            const calls = parseNext(usize, &fields) orelse continue;
            const specifications = parseNext(usize, &fields) orelse continue;
            const cut = parseNext(u8, &fields) orelse continue;
            try tallies.append(room, .{ .index = index, .calls = calls, .specifications = specifications, .is_cut_short = cut != 0 });
        } else if (std.mem.eql(u8, tag, "X")) {
            const subject = fields.next() orelse continue;
            const index = parseNext(usize, &fields) orelse continue;
            const kind = std.meta.stringToEnum(FailureKind, fields.next() orelse continue) orelse continue;
            const signal = parseNext(u32, &fields) orelse continue;
            const token = try wire.unescape(room, fields.next() orelse continue);
            const complaint = try wire.unescape(room, fields.next() orelse continue);
            const function = try wire.unescape(room, fields.next() orelse continue);
            const file = try wire.unescape(room, fields.next() orelse continue);
            const line_number = parseNext(u32, &fields) orelse continue;
            const text_field = try wire.unescape(room, fields.next() orelse continue);
            try failures.append(room, .{
                .is_scenario = std.mem.eql(u8, subject, "scenario"),
                .index = index,
                .kind = kind,
                .token = token,
                .signal = signal,
                .complaint = complaint,
                .expectation_function = function,
                .file = file,
                .line = line_number,
                .text = text_field,
            });
        }
    }
    return .{
        .tallies = try tallies.toOwnedSlice(room),
        .failures = try failures.toOwnedSlice(room),
        .arena = arena,
    };
}

fn parseNext(comptime T: type, fields: *std.mem.SplitIterator(u8, .scalar)) ?T {
    const text = fields.next() orelse return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

test {
    _ = @import("worker.test.zig");
}
