// Tests for the shared state of the simulated effects.

const std = @import("std");
const state = @import("effect_state.zig");
const injector_mod = @import("injector.zig");

test "ask answers null and records nothing when no injector is installed" {
    state.injector = null;
    try std.testing.expectEqual(@as(?u8, null), state.ask(.clock, &.{1}));
}

test "ask records the place and returns the planned failure" {
    const plan = [_]injector_mod.Injection{.{ .point = .{ .effect = .clock, .occurrence = 1 }, .kind = 1 }};
    var inj = injector_mod.Injector.init(std.testing.allocator, &plan);
    defer inj.deinit();
    state.injector = &inj;
    defer state.injector = null;

    try std.testing.expectEqual(@as(?u8, null), state.ask(.clock, &.{ 1, 2 }));
    try std.testing.expectEqual(@as(?u8, 1), state.ask(.clock, &.{ 1, 2 }));
    try std.testing.expectEqual(@as(usize, 2), inj.recorded.items.len);
}

test "kindIndex finds a row by its id" {
    try std.testing.expectEqual(@as(u8, 0), comptime state.kindIndex(.clock, "clock_cannot_be_read"));
    try std.testing.expectEqual(@as(u8, 3), comptime state.kindIndex(.clock, "time_jumps_far_forward"));
}

test "isKind compares an index with a row" {
    try std.testing.expect(state.isKind(.clock, "time_goes_backwards", 1));
    try std.testing.expect(!state.isKind(.clock, "time_goes_backwards", 2));
}

test "kindsFor lists the indexes of the rows in the order given" {
    const kinds = comptime state.kindsFor(.network, &.{ "connection_refused", "network_down" });
    try std.testing.expectEqualSlices(u8, &.{ 1, 12 }, &kinds);
}

test "attach remembers the layers and the injector" {
    var inj = injector_mod.Injector.init(std.testing.allocator, &.{});
    defer inj.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    state.attach(threaded.io(), threaded.io(), &inj);
    defer state.injector = null;
    try std.testing.expect(state.injector.? == &inj);
    try std.testing.expectEqual(threaded.io().userdata, state.underneath.userdata);
}
