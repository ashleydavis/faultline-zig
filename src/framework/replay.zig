// Repeats the calls a replay token names, in the same world, and says whether they went the same
// way.
//
// A token names one function (or one scenario), the seed, the value chosen for each parameter and
// the failures injected. Replaying makes exactly that call in a child process, so the answer does
// not depend on anything that happened before, and reports whether it failed.

const std = @import("std");
const isolate = @import("isolate.zig");
const plan_mod = @import("plan.zig");
const project = @import("project.zig");
const wire = @import("wire.zig");
const worker = @import("worker.zig");
const call_mod = @import("call.zig");

// What came of a replay.
pub const Verdict = union(enum) {
    // The call went through with no failure.
    passed,

    // The call failed in the way the failure says.
    failed: worker.Failure,

    // The token names a function or a scenario the project does not have.
    not_found,

    // The token is not one Faultline wrote.
    bad_token: plan_mod.ParseError,

    // The token names a call whose values cannot be built from the project as it is now.
    not_replayable,
};

// What a replay needs besides the token.
pub const Options = struct {
    // The directory the project's sources were copied to, for the conditions of a function.
    sources_root: []const u8,

    // How long the call may take.
    limits: isolate.Limits = isolate.default_limits,

    // Whether a failure keeps everything the call wrote on its error stream, and not only the
    // first line.
    keeps_whole_complaint: bool = false,
};

// Replays `token_text`. `Subject` is a `project.Project(...)`. Strings in a failure live in `room`.
pub fn run(
    comptime Subject: type,
    allocator: std.mem.Allocator,
    room: std.mem.Allocator,
    real_io: std.Io,
    options: Options,
    token_text: []const u8,
) !Verdict {
    var plan = plan_mod.parse(allocator, token_text) catch |err| return .{ .bad_token = err };
    defer plan.deinit();

    for (Subject.function_entries, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.file, plan.file) or !std.mem.eql(u8, entry.name, plan.function)) {
            continue;
        }
        if (!entry.can_call) {
            return .not_replayable;
        }
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const conditions = if (usesConditions(plan.choices))
            worker.readConditions(scratch.allocator(), real_io, options.sources_root, entry) catch &.{}
        else
            &.{};
        var attempt = try entry.attempt(allocator, .{
            .seed = plan.seed,
            .spec = plan.choices,
            .plan = plan.injections,
            .conditions = conditions,
            .real_io = real_io,
        }, options.limits);
        defer attempt.deinit(allocator);
        return try verdictOf(allocator, room, false, index, token_text, attempt, options.keeps_whole_complaint);
    }

    for (Subject.scenario_entries, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.file, plan.file) or !std.mem.eql(u8, entry.name, plan.function)) {
            continue;
        }
        var attempt = try entry.attempt(allocator, real_io, plan.seed, plan.injections, options.limits);
        defer attempt.deinit(allocator);
        return try verdictOf(allocator, room, true, index, token_text, attempt, options.keeps_whole_complaint);
    }
    return .not_found;
}

fn usesConditions(choices: []const plan_mod.Choice) bool {
    for (choices) |choice| {
        if (choice.source == .condition) {
            return true;
        }
    }
    return false;
}

fn verdictOf(
    allocator: std.mem.Allocator,
    room: std.mem.Allocator,
    is_scenario: bool,
    index: usize,
    token_text: []const u8,
    attempt: isolate.Attempt,
    keeps_whole_complaint: bool,
) !Verdict {
    var report = try wire.read(allocator, attempt.output);
    defer report.deinit();
    const token = try room.dupe(u8, token_text);
    if (try worker.failureOf(room, is_scenario, index, token, attempt, report)) |found| {
        var failure = found;
        if (keeps_whole_complaint) {
            failure.complaint = try room.dupe(u8, attempt.complaint);
        }
        return .{ .failed = failure };
    }
    return .passed;
}

test {
    _ = @import("replay.test.zig");
}
