// Tests for the simulated clock: the fixed start, sleeping and every failure in the Clock table.

const std = @import("std");
const testing = std.testing;
const clock = @import("effect_clock.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;

fn nowNanoseconds(world: *World) i96 {
    return std.Io.Clock.real.now(world.io).nanoseconds;
}

test "the clock starts at a fixed time and does not move by itself" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    try testing.expectEqual(clock.start_nanoseconds, nowNanoseconds(&world));
    try testing.expectEqual(clock.start_nanoseconds, nowNanoseconds(&world));
    try testing.expectEqual(clock.start_nanoseconds, std.Io.Clock.awake.now(world.io).nanoseconds);
}

test "the clock resolution is one nanosecond" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const resolution = try std.Io.Clock.real.resolution(world.io);
    try testing.expectEqual(@as(i96, 1), resolution.nanoseconds);
}

test "a sleep returns at once and moves the clock by the duration" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const before = nowNanoseconds(&world);
    try std.Io.sleep(world.io, .fromSeconds(5), .real);
    try testing.expectEqual(before + 5 * std.time.ns_per_s, nowNanoseconds(&world));
}

test "a sleep until a deadline moves the clock to the deadline and never back" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const deadline = clock.start_nanoseconds + 100;
    try world.io.vtable.sleep(world.io.userdata, .{ .deadline = .{ .raw = .{ .nanoseconds = deadline }, .clock = .real } });
    try testing.expectEqual(deadline, nowNanoseconds(&world));
    try world.io.vtable.sleep(world.io.userdata, .{ .deadline = .{ .raw = .{ .nanoseconds = deadline - 50 }, .clock = .real } });
    try testing.expectEqual(deadline, nowNanoseconds(&world));
    try world.io.vtable.sleep(world.io.userdata, .none);
    try testing.expectEqual(deadline, nowNanoseconds(&world));
}

test "a reading is earlier than the previous one when time goes backwards" {
    const plan = [_]injector_mod.Injection{failAt(.clock, 1, "time_goes_backwards")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const first = nowNanoseconds(&world);
    const second = nowNanoseconds(&world);
    const third = nowNanoseconds(&world);
    try testing.expect(second < first);
    try testing.expectEqual(first, third);
}

test "every reading is the same when time stands still" {
    const plan = [_]injector_mod.Injection{failAt(.clock, 1, "time_stands_still")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const first = nowNanoseconds(&world);
    try std.Io.sleep(world.io, .fromSeconds(1), .real);
    try testing.expectEqual(first, nowNanoseconds(&world));
    try std.Io.sleep(world.io, .fromSeconds(1), .real);
    try testing.expectEqual(first, nowNanoseconds(&world));
    try testing.expectEqual(first, nowNanoseconds(&world));
}

test "a reading is far past the previous one when time jumps far forward" {
    const plan = [_]injector_mod.Injection{failAt(.clock, 1, "time_jumps_far_forward")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const first = nowNanoseconds(&world);
    const second = nowNanoseconds(&world);
    const third = nowNanoseconds(&world);
    try testing.expect(second - first >= 365 * std.time.ns_per_day);
    try testing.expectEqual(second, third);
}

test "the clock cannot be read returns error.Unexpected" {
    const plan = [_]injector_mod.Injection{failAt(.clock, 0, "clock_cannot_be_read")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    try testing.expectError(error.Unexpected, std.Io.Clock.real.resolution(world.io));
}

test "a cancelled sleep returns error.Canceled and does not move the clock" {
    const plan = [_]injector_mod.Injection{failAt(.cancellation, 0, "operation_cancelled")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    try testing.expectError(error.Canceled, std.Io.sleep(world.io, .fromSeconds(5), .real));
    try testing.expectEqual(clock.start_nanoseconds, nowNanoseconds(&world));
}

test "every reading and every sleep asks the injector once" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    _ = nowNanoseconds(&world);
    _ = try std.Io.Clock.real.resolution(world.io);
    try std.Io.sleep(world.io, .fromSeconds(1), .real);
    try testing.expectEqual(@as(usize, 3), world.injector.recorded.items.len);
    try testing.expectEqual(@as(u32, 2), world.injector.counts[@intFromEnum(@import("point.zig").Effect.clock)]);
    try testing.expectEqual(@as(u32, 1), world.injector.counts[@intFromEnum(@import("point.zig").Effect.cancellation)]);
}

test "reset puts the clock back at its start" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    try std.Io.sleep(world.io, .fromSeconds(9), .real);
    clock.reset();
    try testing.expectEqual(clock.start_nanoseconds, nowNanoseconds(&world));
}
