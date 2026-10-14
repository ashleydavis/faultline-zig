// Tests for cancellation: error.Canceled from the cancellable calls that are intercepted.

const std = @import("std");
const testing = std.testing;
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;

test "checkCancel with no failure returns normally" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    try world.io.checkCancel();
    try testing.expectEqual(@as(usize, 1), world.injector.recorded.items.len);
}

test "checkCancel returns error.Canceled when the operation is cancelled" {
    const plan = [_]injector_mod.Injection{failAt(.cancellation, 1, "operation_cancelled")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    try world.io.checkCancel();
    try testing.expectError(error.Canceled, world.io.checkCancel());
    try world.io.checkCancel();
}

test "a futex wait returns error.Canceled when the operation is cancelled" {
    const plan = [_]injector_mod.Injection{failAt(.cancellation, 0, "operation_cancelled")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const word: u32 = 1;
    try testing.expectError(error.Canceled, world.io.vtable.futexWait(world.io.userdata, &word, 1, .none));
}

test "a futex wait whose value already changed returns at once" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const word: u32 = 2;
    try world.io.vtable.futexWait(world.io.userdata, &word, 1, .none);
}
