const std = @import("std");
const linux = std.os.linux;
const isolate = @import("isolate.zig");

const quick: isolate.Limits = .{ .processor_seconds = 5, .wall_ms = 10_000 };

const Says = struct {
    text: []const u8,

    pub fn run(self: Says, out: *std.Io.Writer) void {
        out.writeAll(self.text) catch {};
    }
};

const Panics = struct {
    pub fn run(_: Panics, out: *std.Io.Writer) void {
        out.writeAll("before") catch {};
        @panic("the call went wrong");
    }
};

const Segfaults = struct {
    pub fn run(_: Segfaults, _: *std.Io.Writer) void {
        const nowhere: *volatile u8 = @ptrFromInt(8);
        nowhere.* = 1;
    }
};

const Loops = struct {
    pub fn run(_: Loops, _: *std.Io.Writer) void {
        var counter: usize = 0;
        while (true) {
            counter +%= 1;
            std.mem.doNotOptimizeAway(counter);
        }
    }
};

const Sleeps = struct {
    pub fn run(_: Sleeps, _: *std.Io.Writer) void {
        var for_a_long_time: linux.timespec = .{ .sec = 30, .nsec = 0 };
        _ = linux.nanosleep(&for_a_long_time, null);
    }
};

const Complains = struct {
    pub fn run(_: Complains, out: *std.Io.Writer) void {
        _ = linux.write(2, "a complaint\n", 12);
        out.writeAll("fine") catch {};
    }
};

const Exits = struct {
    status: i32,

    pub fn run(self: Exits, _: *std.Io.Writer) void {
        linux.exit_group(self.status);
    }
};

const SaysALot = struct {
    pub fn run(_: SaysALot, out: *std.Io.Writer) void {
        var index: usize = 0;
        while (index < 200_000) : (index += 1) {
            out.print("line {d}\n", .{index}) catch return;
        }
    }
};

test "a child that returns has its output handed back and exited cleanly" {
    var result = try isolate.attempt(std.testing.allocator, Says{ .text = "hello" }, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.isClean());
    try std.testing.expectEqualStrings("hello", result.output);
}

test "a child that writes a lot has all of it handed back" {
    var result = try isolate.attempt(std.testing.allocator, SaysALot{}, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.isClean());
    try std.testing.expect(std.mem.endsWith(u8, result.output, "line 199999\n"));
}

test "a child that panics ends with a signal and its message is kept" {
    var result = try isolate.attempt(std.testing.allocator, Panics{}, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.isClean());
    try std.testing.expect(result.ending == .signaled);
    try std.testing.expect(std.mem.indexOf(u8, result.complaint, "the call went wrong") != null);
}

test "a child that crashes with a segmentation fault ends with a signal" {
    var result = try isolate.attempt(std.testing.allocator, Segfaults{}, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ending == .signaled);
}

test "a child stuck in a loop is stopped by the processor limit" {
    const one_second: isolate.Limits = .{ .processor_seconds = 1, .wall_ms = 20_000 };
    var result = try isolate.attempt(std.testing.allocator, Loops{}, one_second);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ending == .signaled);
    try std.testing.expectEqual(isolate.processor_limit_signal, result.ending.signaled);
}

test "a child that stops using the processor is killed at the wall limit" {
    const brief: isolate.Limits = .{ .processor_seconds = 5, .wall_ms = 200 };
    var result = try isolate.attempt(std.testing.allocator, Sleeps{}, brief);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ending == .timed_out);
}

test "what a child writes on its error stream is kept apart from its output" {
    var result = try isolate.attempt(std.testing.allocator, Complains{}, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("fine", result.output);
    try std.testing.expectEqualStrings("a complaint\n", result.complaint);
}

test "a child that exits with a status is not clean and the status is reported" {
    var result = try isolate.attempt(std.testing.allocator, Exits{ .status = 3 }, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.isClean());
    try std.testing.expectEqual(@as(u8, 3), result.ending.exited);
}

test "a crash in one child does not change the next child" {
    var first = try isolate.attempt(std.testing.allocator, Segfaults{}, quick);
    first.deinit(std.testing.allocator);

    var second = try isolate.attempt(std.testing.allocator, Says{ .text = "still here" }, quick);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(second.isClean());
    try std.testing.expectEqualStrings("still here", second.output);
}

test "a child that crashes is ended by a status the system does not report as a crash" {
    var result = try isolate.attempt(std.testing.allocator, Segfaults{}, quick);
    defer result.deinit(std.testing.allocator);

    // The child caught the signal and left, so no core dump was started, and the parent still
    // reads it as the signal.
    try std.testing.expectEqual(@intFromEnum(linux.SIG.SEGV), result.ending.signaled);
}

test "a panic is reported as an abort signal" {
    var result = try isolate.attempt(std.testing.allocator, Panics{}, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@intFromEnum(linux.SIG.ABRT), result.ending.signaled);
}

const PanicsThroughTheHandler = struct {
    pub fn run(_: PanicsThroughTheHandler, out: *std.Io.Writer) void {
        _ = out;
        isolate.panicInChild("the call went wrong", null);
    }
};

test "the panic handler in a child writes the message alone and ends as an abort" {
    var result = try isolate.attempt(std.testing.allocator, PanicsThroughTheHandler{}, quick);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@intFromEnum(linux.SIG.ABRT), result.ending.signaled);
    try std.testing.expectEqualStrings("panic: the call went wrong\n", result.complaint);
}

// A runner for a resident child that does what each request says: says it back, complains and
// then says it back, panics, loops, sleeps or exits.
const Obeys = struct {
    // How many requests this child has run, said back with each so a test can tell one child from
    // another.
    runs: usize = 0,

    pub fn run(self: *Obeys, request: []const u8, out: *std.Io.Writer) void {
        self.runs += 1;
        if (std.mem.eql(u8, request, "complain")) {
            _ = linux.write(2, "an old complaint\n", 17);
        } else if (std.mem.eql(u8, request, "panic")) {
            @panic("the call went wrong");
        } else if (std.mem.eql(u8, request, "loop")) {
            (Loops{}).run(out);
        } else if (std.mem.eql(u8, request, "sleep")) {
            (Sleeps{}).run(out);
        } else if (std.mem.eql(u8, request, "exit")) {
            linux.exit_group(3);
        }
        out.print("{d} {s}", .{ self.runs, request }) catch {};
    }
};

test "a resident child makes one call after another in the same process" {
    var resident = try isolate.Resident.start(Obeys{});
    defer resident.stop();

    var first = try resident.attempt(std.testing.allocator, "one", quick);
    defer first.deinit(std.testing.allocator);
    var second = try resident.attempt(std.testing.allocator, "two", quick);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(first.isClean());
    try std.testing.expectEqualStrings("1 one", first.output);
    try std.testing.expectEqualStrings("2 two", second.output);
    try std.testing.expectEqual(@as(usize, 2), resident.calls);
}

test "a call that crashes a resident child says what that call complained of and ends the child" {
    var resident = try isolate.Resident.start(Obeys{});
    defer resident.stop();

    var complained = try resident.attempt(std.testing.allocator, "complain", quick);
    defer complained.deinit(std.testing.allocator);
    var crashed = try resident.attempt(std.testing.allocator, "panic", quick);
    defer crashed.deinit(std.testing.allocator);

    try std.testing.expect(complained.isClean());
    try std.testing.expect(!crashed.isClean());
    try std.testing.expectEqual(@as(u32, @intFromEnum(linux.SIG.ABRT)), crashed.ending.signaled);
    try std.testing.expect(std.mem.indexOf(u8, crashed.complaint, "the call went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, crashed.complaint, "an old complaint") == null);
    try std.testing.expect(!resident.isRunning());
}

test "a call in a resident child that runs past the processor limit is read as a hang" {
    const short: isolate.Limits = .{ .processor_seconds = 1, .wall_ms = 10_000 };
    var resident = try isolate.Resident.start(Obeys{});
    defer resident.stop();

    var hung = try resident.attempt(std.testing.allocator, "loop", short);
    defer hung.deinit(std.testing.allocator);
    resident = try isolate.Resident.start(Obeys{});
    var after = try resident.attempt(std.testing.allocator, "after", short);
    defer after.deinit(std.testing.allocator);

    try std.testing.expectEqual(isolate.processor_limit_signal, hung.ending.signaled);
    try std.testing.expectEqualStrings("1 after", after.output);
}

test "a call in a resident child that takes longer than the wall limit is ended" {
    const short: isolate.Limits = .{ .processor_seconds = 5, .wall_ms = 200 };
    var resident = try isolate.Resident.start(Obeys{});
    defer resident.stop();

    var slept = try resident.attempt(std.testing.allocator, "sleep", short);
    defer slept.deinit(std.testing.allocator);

    try std.testing.expect(slept.ending == .timed_out);
    try std.testing.expect(!resident.isRunning());
}

test "a call that exits a resident child is read as an exit with its status" {
    var resident = try isolate.Resident.start(Obeys{});
    defer resident.stop();

    var exited = try resident.attempt(std.testing.allocator, "exit", quick);
    defer exited.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 3), exited.ending.exited);
    try std.testing.expect(!resident.isRunning());
}

test "a resident child that has been stopped is not running" {
    var resident = try isolate.Resident.start(Obeys{});
    resident.stop();

    try std.testing.expect(!resident.isRunning());
}
