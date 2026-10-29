const std = @import("std");
const project = @import("project.zig");
const results_cache = @import("results_cache.zig");
const run_cache = @import("run_cache.zig");
const worker = @import("worker.zig");

const Alpha = struct {
    pub fn one(x: u32) u32 {
        return x;
    }
};

const Beta = struct {
    pub fn two(x: u32) u32 {
        return x;
    }

    pub fn three(x: u32) u32 {
        return x;
    }
};

const files = struct {
    pub const sources = .{ .{ .path = "alpha.zig", .namespace = Alpha }, .{ .path = "beta.zig", .namespace = Beta } };
    pub const simulations = .{};
};

const Subject = project.Project(files);

// A failure of `kind` found by the call `token` of the function at `index`, counted from the
// file's first function.
fn failureOf(kind: worker.FailureKind, index: usize, token: []const u8) worker.Failure {
    return .{ .is_scenario = false, .index = index, .kind = kind, .token = token };
}

test "a stored result made with the file's key gives its crashes and its replays as answers, in the run's tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failures = [_]worker.Failure{ failureOf(.crash, 0, "beta.zig:two;seed=1"), failureOf(.hang, 1, "beta.zig:three;seed=1") };
    const units = [_]results_cache.Unit{.{
        .file = "beta.zig",
        .key = 7,
        .entry = .{
            .file = "beta.zig",
            .key = 7,
            .failures = &failures,
            .replays = &.{ .{ .token = "beta.zig:three;seed=2", .failure = failureOf(.crash, 1, "beta.zig:three;seed=2") }, .{ .token = "beta.zig:two;seed=3", .failure = null } },
        },
    }};

    const answers = try run_cache.answersOf(Subject, arena.allocator(), &units);

    try std.testing.expectEqual(@as(usize, 3), answers.len);
    try std.testing.expectEqualStrings("beta.zig:two;seed=1", answers[0].token);
    try std.testing.expectEqual(@as(usize, 1), answers[0].failure.?.index);
    try std.testing.expectEqualStrings("beta.zig:three;seed=2", answers[1].token);
    try std.testing.expectEqual(@as(usize, 2), answers[1].failure.?.index);
    try std.testing.expectEqualStrings("beta.zig:two;seed=3", answers[2].token);
    try std.testing.expectEqual(@as(?worker.Failure, null), answers[2].failure);
}

test "a stored result made with another key, a file with no key and a file with no result give no answers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failures = [_]worker.Failure{failureOf(.crash, 0, "alpha.zig:one;seed=1")};
    const units = [_]results_cache.Unit{
        .{ .file = "alpha.zig", .key = 8, .entry = .{ .file = "alpha.zig", .key = 7, .failures = &failures } },
        .{ .file = "alpha.zig", .key = null, .entry = .{ .file = "alpha.zig", .key = 7, .failures = &failures } },
        .{ .file = "beta.zig", .key = 7, .entry = null },
    };

    const answers = try run_cache.answersOf(Subject, arena.allocator(), &units);

    try std.testing.expectEqual(@as(usize, 0), answers.len);
}

test "answerOf finds a kept crash's answer by its token and gives null for a token with none" {
    const answers = [_]results_cache.Replay{ .{ .token = "a", .failure = null }, .{ .token = "b", .failure = failureOf(.crash, 0, "b") } };
    const state: run_cache.State = .{ .answers = &answers };

    try std.testing.expectEqualStrings("b", state.answerOf("b").?.token);
    try std.testing.expect(state.answerOf("b").?.failure != null);
    try std.testing.expectEqual(@as(?worker.Failure, null), state.answerOf("a").?.failure);
    try std.testing.expectEqual(@as(?results_cache.Replay, null), state.answerOf("c"));
}

test "addReplay keeps each file's answers apart, in the order they were added" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record: run_cache.Record = .{};

    try record.addReplay(arena.allocator(), "alpha.zig", .{ .token = "a1", .failure = null });
    try record.addReplay(arena.allocator(), "beta.zig", .{ .token = "b1", .failure = null });
    try record.addReplay(arena.allocator(), "alpha.zig", .{ .token = "a2", .failure = null });

    const alpha = record.replays.get("alpha.zig").?.items;
    try std.testing.expectEqual(@as(usize, 2), alpha.len);
    try std.testing.expectEqualStrings("a1", alpha[0].token);
    try std.testing.expectEqualStrings("a2", alpha[1].token);
    try std.testing.expectEqualStrings("b1", record.replays.get("beta.zig").?.items[0].token);
}

test "a stored result made with the file's key gives its traces, and one made with another key gives none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const traces = [_]results_cache.Trace{.{ .token = "alpha.zig:one;seed=1", .text = "trace" }};
    const units = [_]results_cache.Unit{
        .{ .file = "alpha.zig", .key = 7, .entry = .{ .file = "alpha.zig", .key = 7, .traces = &traces } },
        .{ .file = "beta.zig", .key = 8, .entry = .{ .file = "beta.zig", .key = 7, .traces = &.{.{ .token = "beta.zig:two;seed=1", .text = "old" }} } },
        .{ .file = "beta.zig", .key = null, .entry = .{ .file = "beta.zig", .key = 7, .traces = &traces } },
        .{ .file = "beta.zig", .key = 7, .entry = null },
    };

    const found = try run_cache.tracesOf(arena.allocator(), &units);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("trace", found[0].text);
    const state: run_cache.State = .{ .traces = found };
    try std.testing.expectEqualStrings("trace", state.traceOf("alpha.zig:one;seed=1").?);
    try std.testing.expectEqual(@as(?[]const u8, null), state.traceOf("beta.zig:two;seed=1"));
}

test "addTrace keeps each file's traces apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record: run_cache.Record = .{};

    try record.addTrace(arena.allocator(), "alpha.zig", .{ .token = "a1", .text = "one" });
    try record.addTrace(arena.allocator(), "beta.zig", .{ .token = "b1", .text = "two" });

    try std.testing.expectEqualStrings("one", record.traces.get("alpha.zig").?.items[0].text);
    try std.testing.expectEqualStrings("two", record.traces.get("beta.zig").?.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), record.traces.get("alpha.zig").?.items.len);
}
