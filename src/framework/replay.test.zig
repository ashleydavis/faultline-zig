const std = @import("std");
const sim = @import("sim");
const replay = @import("replay.zig");
const worker = @import("worker.zig");
const project = @import("project.zig");

const Item = struct { value: u32 };

const Subjects = struct {
    pub fn crashesOnTwo(item: Item) void {
        if (item.value == 2) {
            @panic("the item was two");
        }
    }

    pub fn fine(x: u8) u8 {
        return x;
    }
};

const SubjectsSim = struct {
    pub fn goodItem() Item {
        return .{ .value = 1 };
    }

    pub fn crashingItem() Item {
        return .{ .value = 2 };
    }

    pub fn failingScenario(context: *sim.ScenarioContext) anyerror!void {
        try context.expect(@src(), false, "the scenario to hold");
    }
};

const files = struct {
    pub const sources = .{.{ .path = "subjects.zig", .namespace = Subjects }};
    pub const simulations = .{.{ .path = "subjects.sim.zig", .source = "subjects.zig", .namespace = SubjectsSim }};
};

const Subject = project.Project(files);

fn replayToken(token: []const u8, room: std.mem.Allocator) !replay.Verdict {
    return replay.run(Subject, std.testing.allocator, room, std.testing.io, .{ .sources_root = "." }, token);
}

test "replaying the token of a crash crashes the same way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = [_]worker.WorkItem{.{ .function = .{ .index = 0, .phase = .normal } }};
    var found = try worker.run(Subject, std.testing.allocator, std.testing.io, .{ .seed = 4, .sources_root = "." }, &items);
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), found.failures.len);

    const verdict = try replayToken(found.failures[0].token, arena.allocator());

    try std.testing.expectEqual(worker.FailureKind.crash, verdict.failed.kind);
    try std.testing.expect(std.mem.indexOf(u8, verdict.failed.complaint, "the item was two") != null);
}

test "replaying a call that does not fail passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const verdict = try replayToken("subjects.zig:fine;seed=1;values=b0", arena.allocator());

    try std.testing.expect(verdict == .passed);
}

test "replaying a scenario that does not hold fails with its expectation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const verdict = try replayToken("subjects.sim.zig:failingScenario;seed=1", arena.allocator());

    try std.testing.expectEqualStrings("the scenario to hold", verdict.failed.text);
    try std.testing.expect(verdict.failed.is_scenario);
}

test "a token for a function the project does not have is not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const verdict = try replayToken("subjects.zig:missing;seed=1", arena.allocator());

    try std.testing.expect(verdict == .not_found);
}

test "text that is not a token is a bad token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const verdict = try replayToken("nonsense", arena.allocator());

    try std.testing.expect(verdict == .bad_token);
}
