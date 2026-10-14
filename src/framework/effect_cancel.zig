// Cancellation. An interruption such as a signal reaches a function as a cancelled operation:
// `error.Canceled` from a call that can be cancelled.
//
// Of the cancellable calls in `std.Io`, these are intercepted: `checkCancel` (the call a loop makes
// to see whether it has been asked to stop) and `futexWait` (a wait on a memory address). Sleeping
// is intercepted too and is in `effect_clock.zig` because it also moves the clock. Waiting for a
// task or a group of tasks, reads and writes and the other cancellable calls are not intercepted
// here: waiting for a task that was started on the real `Io` underneath cannot be abandoned half
// way without leaving the task running and reads and writes belong to the files and sockets.

const std = @import("std");
const state = @import("effect_state.zig");

const cancel_kinds = state.kindsFor(.cancellation, &.{"operation_cancelled"});

// Writes the cancellation entries of the `Io` vtable into `room`.
pub fn override(room: *std.Io.VTable) void {
    room.checkCancel = checkCancel;
    room.futexWait = futexWait;
}

fn checkCancel(userdata: ?*anyopaque) std.Io.Cancelable!void {
    if (state.ask(.cancellation, &cancel_kinds) != null) {
        return error.Canceled;
    }
    return state.underneath.vtable.checkCancel(userdata);
}

fn futexWait(
    userdata: ?*anyopaque,
    pointer: *const u32,
    expected: u32,
    timeout: std.Io.Timeout,
) std.Io.Cancelable!void {
    if (state.ask(.cancellation, &cancel_kinds) != null) {
        return error.Canceled;
    }
    return state.underneath.vtable.futexWait(userdata, pointer, expected, timeout);
}

test {
    _ = @import("effect_cancel.test.zig");
}
