// Threads. A thread can fail to start in four ways: too many threads, out of resources, out of
// memory and the locked memory limit.
//
// Through `std.Io` a task is started with `concurrent` or `groupConcurrent`, whose only error is
// `error.ConcurrencyUnavailable`. Each of those calls asks the injector once and, when any of the
// four failures is planned, returns that error, because it is the one error the call has. Starting
// a task with `async` or `groupAsync` cannot fail (the implementation runs it in place when it has
// no thread), so those are not asked about and are left to the `Io` underneath.
//
// `std.Thread.spawn` is not reached through `Io`, so it cannot be intercepted. `spawn` in this file
// is the same call for code written against the simulated world: it returns the four errors by
// name and otherwise runs the function to the end in place, so a run is the same every time.

const std = @import("std");
const state = @import("effect_state.zig");

const thread_kinds = state.kindsFor(.thread, &.{ "too_many_threads", "out_of_resources", "out_of_memory", "locked_memory_limit_reached" });

// Nothing is held between calls.
pub fn reset() void {}

// Writes the concurrency entries of the `Io` vtable into `room`.
pub fn override(room: *std.Io.VTable) void {
    room.concurrent = concurrent;
    room.groupConcurrent = groupConcurrent;
}

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) std.Io.ConcurrentError!*std.Io.AnyFuture {
    if (state.ask(.thread, &thread_kinds) != null) {
        return error.ConcurrencyUnavailable;
    }
    return state.underneath.vtable.concurrent(userdata, result_len, result_alignment, context, context_alignment, start);
}

fn groupConcurrent(
    userdata: ?*anyopaque,
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) std.Io.ConcurrentError!void {
    if (state.ask(.thread, &thread_kinds) != null) {
        return error.ConcurrencyUnavailable;
    }
    return state.underneath.vtable.groupConcurrent(userdata, group, context, context_alignment, start);
}

// What `spawn` returns for a thread that has already run to the end.
pub const FinishedThread = struct {
    // Waits for the thread, which has finished already.
    pub fn join(_: FinishedThread) void {}

    // Lets the thread go, which has finished already.
    pub fn detach(_: FinishedThread) void {}
};

// The simulated `std.Thread.spawn`: asks the injector once and returns the error of the failure it
// names, or runs `function` with `args` on the calling thread and returns a finished thread.
pub fn spawn(comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Thread.SpawnError!FinishedThread {
    if (state.ask(.thread, &thread_kinds)) |kind| {
        if (state.isKind(.thread, "too_many_threads", kind)) {
            return error.ThreadQuotaExceeded;
        }
        if (state.isKind(.thread, "out_of_resources", kind)) {
            return error.SystemResources;
        }
        if (state.isKind(.thread, "out_of_memory", kind)) {
            return error.OutOfMemory;
        }
        return error.LockedMemoryLimitExceeded;
    }
    _ = @call(.auto, function, args);
    return .{};
}

test {
    _ = @import("effect_thread.test.zig");
}
