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
