const std = @import("std");
const sim = @import("sim");
const worker = @import("worker.zig");
const project = @import("project.zig");
const plan_mod = @import("plan.zig");
const output = @import("output.zig");

const Item = struct { value: u32 };

const Subjects = struct {
    pub fn classify(x: i32) []const u8 {
        if (x > 1000) {
            return "huge";
        }
        return "small";
    }

    pub fn crashesOnTwo(item: Item) void {
        if (item.value == 2) {
            @panic("the item was two");
        }
    }

    pub fn allocates(allocator: std.mem.Allocator) !void {
        const memory = try allocator.alloc(u8, 4);
        allocator.free(memory);
    }

    pub fn takesAFunction(callback: *const fn () void) void {
        callback();
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

    pub fn passingScenario(context: *sim.ScenarioContext) anyerror!void {
        try context.expect(@src(), true, "the scenario to hold");
    }
};

const Falsehood = struct {
    pub fn runs() void {}
};

const FalsehoodSim = struct {
    pub fn neverTrue(context: *sim.ExpectationContext) anyerror!void {
        try context.expect(@src(), false, "the impossible");
    }
};

const files = struct {
    pub const sources = .{
        .{ .path = "subjects.zig", .namespace = Subjects },
        .{ .path = "falsehood.zig", .namespace = Falsehood },
    };
    pub const simulations = .{
        .{ .path = "subjects.sim.zig", .source = "subjects.zig", .namespace = SubjectsSim },
        .{ .path = "falsehood.sim.zig", .source = "falsehood.zig", .namespace = FalsehoodSim },
    };
};

const Subject = project.Project(files);

fn indexOf(name: []const u8) usize {
    for (Subject.function_entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) {
            return index;
        }
    }
    unreachable;
}

fn options() worker.Options {
    return .{ .seed = 3, .sources_root = "." };
}

test "work written as text reads back" {
    const items = [_]worker.WorkItem{
        .{ .function = .{ .index = 4, .phase = .normal } },
        .{ .function = .{ .index = 9, .phase = .conditions } },
        .{ .scenario = 2 },
    };
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try worker.writeWork(&buffer.writer, &items);

    const read = try worker.readWork(std.testing.allocator, buffer.written());
    defer std.testing.allocator.free(read);

    try std.testing.expectEqual(@as(usize, 3), read.len);
    try std.testing.expectEqual(@as(usize, 4), read[0].function.index);
    try std.testing.expectEqual(worker.Phase.conditions, read[1].function.phase);
    try std.testing.expectEqual(@as(usize, 2), read[2].scenario);
}

test "a line of work that does not parse is passed over" {
    const read = try worker.readWork(std.testing.allocator, "nonsense\nF\tx\tnormal\nF\t1\tsometimes\nS\t7\n");
    defer std.testing.allocator.free(read);

    try std.testing.expectEqual(@as(usize, 1), read.len);
    try std.testing.expectEqual(@as(usize, 7), read[0].scenario);
}

test "results written as text read back with their text intact" {
    var tallies = [_]worker.Tally{.{ .index = 1, .calls = 12, .specifications = 3, .is_cut_short = true }};
    var failures = [_]worker.Failure{.{
        .is_scenario = false,
        .index = 5,
        .kind = .expectation,
        .token = "a.zig:f;seed=1",
        .expectation_function = "check",
        .file = "a.sim.zig",
        .line = 22,
        .text = "text with a\ttab and a\nnewline",
    }};
    const results: worker.Results = .{ .tallies = &tallies, .failures = &failures, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try worker.writeResults(&buffer.writer, results);

    var read = try worker.readResults(std.testing.allocator, buffer.written());
    defer read.deinit();

    try std.testing.expectEqual(@as(usize, 12), read.tallies[0].calls);
    try std.testing.expect(read.tallies[0].is_cut_short);
    try std.testing.expectEqualStrings("text with a\ttab and a\nnewline", read.failures[0].text);
    try std.testing.expectEqual(@as(u32, 22), read.failures[0].line);
    try std.testing.expectEqual(worker.FailureKind.expectation, read.failures[0].kind);
}

test "a function that calls the allocator is called once for each failure it can have" {
    const items = [_]worker.WorkItem{.{ .function = .{ .index = indexOf("allocates"), .phase = .normal } }};

    var results = try worker.run(Subject, std.testing.allocator, std.testing.io, options(), &items);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.tallies.len);
    try std.testing.expect(results.tallies[0].calls > 1);
    try std.testing.expectEqual(@as(usize, 0), results.failures.len);
}

test "a function that crashes for one value from a factory is reported with a token that replays it" {
    const items = [_]worker.WorkItem{.{ .function = .{ .index = indexOf("crashesOnTwo"), .phase = .normal } }};

    var results = try worker.run(Subject, std.testing.allocator, std.testing.io, options(), &items);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.failures.len);
    const failure = results.failures[0];
    try std.testing.expectEqual(worker.FailureKind.crash, failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, failure.complaint, "the item was two") != null);
    var plan = try plan_mod.parse(std.testing.allocator, failure.token);
    defer plan.deinit();
    try std.testing.expectEqualStrings("subjects.zig", plan.file);
    try std.testing.expectEqualStrings("crashesOnTwo", plan.function);
}

test "the same crash found by several calls is reported once" {
    const items = [_]worker.WorkItem{
        .{ .function = .{ .index = indexOf("crashesOnTwo"), .phase = .normal } },
        .{ .function = .{ .index = indexOf("crashesOnTwo"), .phase = .normal } },
    };

    var results = try worker.run(Subject, std.testing.allocator, std.testing.io, options(), &items);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.failures.len);
}

test "a function nothing can build a parameter for is skipped" {
    const items = [_]worker.WorkItem{.{ .function = .{ .index = indexOf("takesAFunction"), .phase = .normal } }};

    var results = try worker.run(Subject, std.testing.allocator, std.testing.io, options(), &items);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 0), results.tallies.len);
}

test "an expectation function that is false makes every call of a function in its file fail" {
    const items = [_]worker.WorkItem{.{ .function = .{ .index = indexOf("runs"), .phase = .normal } }};

    var results = try worker.run(Subject, std.testing.allocator, std.testing.io, options(), &items);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.failures.len);
    try std.testing.expectEqual(worker.FailureKind.expectation, results.failures[0].kind);
    try std.testing.expectEqualStrings("neverTrue", results.failures[0].expectation_function);
    try std.testing.expectEqualStrings("the impossible", results.failures[0].text);
}

test "a scenario that does not hold is a failure and one that does is not" {
    var failing_index: usize = 0;
    var passing_index: usize = 0;
    for (Subject.scenario_entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, "failingScenario")) {
            failing_index = index;
        }
        if (std.mem.eql(u8, entry.name, "passingScenario")) {
            passing_index = index;
        }
    }
    const items = [_]worker.WorkItem{ .{ .scenario = failing_index }, .{ .scenario = passing_index } };

    var results = try worker.run(Subject, std.testing.allocator, std.testing.io, options(), &items);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.failures.len);
    try std.testing.expect(results.failures[0].is_scenario);
    try std.testing.expectEqualStrings("the scenario to hold", results.failures[0].text);
}

test "the conditions phase reads the function's source and adds specifications that use its values" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "subjects.zig",
        .data = "pub fn classify(x: i32) []const u8 {\n    if (x > 1000) {\n        return \"huge\";\n    }\n    return \"small\";\n}\n",
    });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try directory.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..length];

    const normal = [_]worker.WorkItem{.{ .function = .{ .index = indexOf("classify"), .phase = .normal } }};
    const conditions = [_]worker.WorkItem{.{ .function = .{ .index = indexOf("classify"), .phase = .conditions } }};
    var with_conditions_options = options();
    with_conditions_options.sources_root = root;

    var first = try worker.run(Subject, std.testing.allocator, std.testing.io, options(), &normal);
    defer first.deinit();
    var second = try worker.run(Subject, std.testing.allocator, std.testing.io, with_conditions_options, &conditions);
    defer second.deinit();

    try std.testing.expect(first.tallies[0].specifications > 0);
    try std.testing.expect(second.tallies[0].specifications > 0);
}

test "the thread number the standard library puts before a panic message is left out of a complaint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = try worker.firstLine(arena.allocator(), "thread 4242 panic: attempt to use null value\nmore\n");

    try std.testing.expectEqualStrings("panic: attempt to use null value", line);
}

test "a complaint with no thread number is kept as it is and blank lines are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = try worker.firstLine(arena.allocator(), "\n  \nreached unreachable code\n");
    const thread_word = try worker.firstLine(arena.allocator(), "thread is not followed by a number\n");

    try std.testing.expectEqualStrings("reached unreachable code", line);
    try std.testing.expectEqualStrings("thread is not followed by a number", thread_word);
}

test "elapsed time reads as seconds under a minute and minutes and seconds above it" {
    var buffer: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0s", worker.elapsedText(&buffer, 400 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("59s", worker.elapsedText(&buffer, 59 * std.time.ns_per_s));
    try std.testing.expectEqualStrings("1m 0s", worker.elapsedText(&buffer, 60 * std.time.ns_per_s));
    try std.testing.expectEqualStrings("2m 14s", worker.elapsedText(&buffer, 134 * std.time.ns_per_s));
}

test "elapsed time that does not fit the buffer reads as a while" {
    var buffer: [1]u8 = undefined;

    try std.testing.expectEqualStrings("a while", worker.elapsedText(&buffer, 5 * std.time.ns_per_s));
}

test "a progress line is due once half a second has passed since the last one" {
    try std.testing.expect(!worker.isProgressDue(499 * std.time.ns_per_ms, 0));
    try std.testing.expect(worker.isProgressDue(500 * std.time.ns_per_ms, 0));
    try std.testing.expect(worker.isProgressDue(2 * std.time.ns_per_s, std.time.ns_per_s));
}

test "a call is counted and says where the run has got to when somebody is watching" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    output.writer = &buffer.writer;
    defer output.writer = null;
    worker.progress_is_watched = true;
    defer worker.progress_is_watched = false;
    worker.resetProgress();

    worker.reportProgress("src/greeting.zig", "greet");

    try std.testing.expectEqualStrings("  Exercised 1 call in 0s, now in src/greeting.zig greet.", buffer.written());
    worker.resetProgress();
}

test "a call is counted and nothing is written when nobody is watching" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    output.writer = &buffer.writer;
    defer output.writer = null;
    worker.progress_is_watched = false;
    worker.resetProgress();

    worker.reportProgress("src/greeting.zig", "greet");

    try std.testing.expectEqualStrings("", buffer.written());
    worker.resetProgress();
}

test "a second call inside half a second writes no second line" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    output.writer = &buffer.writer;
    defer output.writer = null;
    worker.progress_is_watched = true;
    defer worker.progress_is_watched = false;
    worker.resetProgress();

    worker.reportProgress("src/greeting.zig", "greet");
    const after_first = buffer.written().len;
    worker.reportProgress("src/greeting.zig", "greet");

    try std.testing.expectEqual(after_first, buffer.written().len);
    worker.resetProgress();
}
