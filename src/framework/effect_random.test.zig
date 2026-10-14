// Tests for random numbers: the seeded ordinary generator and the secure one that can fail.

const std = @import("std");
const testing = std.testing;
const random = @import("effect_random.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;

test "ordinary random fills the buffer with the same bytes for the same seed" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    random.seed(42);
    world.io.random(&first);
    random.seed(42);
    world.io.random(&second);
    try testing.expectEqualSlices(u8, &first, &second);
}

test "ordinary random differs for different seeds" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    random.seed(1);
    world.io.random(&first);
    random.seed(2);
    world.io.random(&second);
    try testing.expect(!std.mem.eql(u8, &first, &second));
}

test "ordinary random is not asked of the injector because it cannot fail" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var bytes: [4]u8 = undefined;
    world.io.random(&bytes);
    try testing.expectEqual(@as(usize, 0), world.injector.recorded.items.len);
}

test "secure random with no failure fills the buffer and repeats for the same seed" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    random.seed(7);
    try world.io.randomSecure(&first);
    random.seed(7);
    try world.io.randomSecure(&second);
    try testing.expectEqualSlices(u8, &first, &second);
}

test "secure random bytes differ from ordinary random bytes for the same seed" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var plain: [16]u8 = undefined;
    var secure: [16]u8 = undefined;
    random.seed(7);
    world.io.random(&plain);
    random.seed(7);
    try world.io.randomSecure(&secure);
    try testing.expect(!std.mem.eql(u8, &plain, &secure));
}

test "secure random returns error.EntropyUnavailable when no entropy is available" {
    const plan = [_]injector_mod.Injection{failAt(.random, 1, "no_entropy_available")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var bytes: [8]u8 = undefined;
    try world.io.randomSecure(&bytes);
    try testing.expectError(error.EntropyUnavailable, world.io.randomSecure(&bytes));
    try world.io.randomSecure(&bytes);
}

test "reset starts the generators at the default seed" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var first: [8]u8 = undefined;
    var second: [8]u8 = undefined;
    random.reset();
    world.io.random(&first);
    random.seed(99);
    random.reset();
    world.io.random(&second);
    try testing.expectEqualSlices(u8, &first, &second);
}
