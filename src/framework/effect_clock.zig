// The simulated clock. It starts at a fixed time, only moves when the code under test sleeps and
// can be made to go backwards, stand still, jump far forward or fail to be read. Sleeping returns
// at once, so a function that waits costs no time.
//
// The clock is one timeline for every `std.Io.Clock`: the real, awake, boot and CPU clocks all
// read the same value, which is enough because the code under test cannot tell them apart without
// comparing two clocks.
//
// A call to `now` cannot return an error in `std.Io`, so "clock cannot be read" is returned by
// reading the clock's resolution (`error.Unexpected`), which is the call that can fail. A sleep
// that is cancelled returns `error.Canceled` and belongs to the cancellation group.

const std = @import("std");
const state = @import("effect_state.zig");

// The first reading, in nanoseconds since the Unix epoch: a fixed moment in 2023 that is far from
// zero so subtracting a few seconds never goes below the start of time.
pub const start_nanoseconds: i96 = 1_700_000_000 * std.time.ns_per_s;

// How far back "time goes backwards" moves a reading: one second, which is enough for a check
// such as "end is not before start" to notice and small enough to look like a clock adjustment.
const backward_step_nanoseconds: i96 = std.time.ns_per_s;

// How far "time jumps far forward" moves the clock: about ten years, so a timeout, a certificate
// expiry or a cache lifetime measured in days is passed.
const forward_jump_nanoseconds: i96 = 10 * 365 * 24 * 3600 * std.time.ns_per_s;

// The clock's resolution: one nanosecond, the finest a clock can claim.
const resolution_nanoseconds: i96 = 1;

// The time now, which only sleeping and a jump forward change.
var current_nanoseconds: i96 = start_nanoseconds;

// The reading the last call to `now` returned, which backwards and standing still are relative to.
var previous_nanoseconds: i96 = start_nanoseconds;

// Whether time stands still: once true, every reading is the previous one and sleeping does not
// move the clock.
var is_standing_still: bool = false;

const now_kinds = state.kindsFor(.clock, &.{ "time_goes_backwards", "time_stands_still", "time_jumps_far_forward" });
const resolution_kinds = state.kindsFor(.clock, &.{"clock_cannot_be_read"});
const sleep_kinds = state.kindsFor(.cancellation, &.{"operation_cancelled"});

// Puts the clock back at its fixed start.
pub fn reset() void {
    current_nanoseconds = start_nanoseconds;
    previous_nanoseconds = start_nanoseconds;
    is_standing_still = false;
}

// Writes the clock entries of the `Io` vtable into `room`.
pub fn override(room: *std.Io.VTable) void {
    room.now = now;
    room.clockResolution = clockResolution;
    room.sleep = sleep;
}

fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    var reading = current_nanoseconds;
    if (is_standing_still) {
        reading = previous_nanoseconds;
    }
    if (state.ask(.clock, &now_kinds)) |kind| {
        if (state.isKind(.clock, "time_goes_backwards", kind)) {
            return .{ .nanoseconds = previous_nanoseconds - backward_step_nanoseconds };
        }
        if (state.isKind(.clock, "time_stands_still", kind)) {
            is_standing_still = true;
            return .{ .nanoseconds = previous_nanoseconds };
        }
        current_nanoseconds = previous_nanoseconds + forward_jump_nanoseconds;
        reading = current_nanoseconds;
    }
    previous_nanoseconds = reading;
    return .{ .nanoseconds = reading };
}

fn clockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    if (state.ask(.clock, &resolution_kinds) != null) {
        return error.Unexpected;
    }
    return .{ .nanoseconds = resolution_nanoseconds };
}

fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    if (state.ask(.cancellation, &sleep_kinds) != null) {
        return error.Canceled;
    }
    if (is_standing_still) {
        return;
    }
    switch (timeout) {
        .none => {},
        .duration => |duration| {
            if (duration.raw.nanoseconds > 0) {
                current_nanoseconds += duration.raw.nanoseconds;
            }
        },
        .deadline => |deadline| {
            if (deadline.raw.nanoseconds > current_nanoseconds) {
                current_nanoseconds = deadline.raw.nanoseconds;
            }
        },
    }
}

test {
    _ = @import("effect_clock.test.zig");
}
