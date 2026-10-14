// Tests for the simulated environment: variables that are set, not set and set to an empty value.

const std = @import("std");
const testing = std.testing;
const world_effects = @import("world_effects.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;
const Environment = world_effects.Environment;

test "a variable that is set is read" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/somewhere");
    try testing.expectEqualStrings("/somewhere", try environment.get("HOME"));
}

test "a variable that was never set returns error.EnvironmentVariableMissing" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try testing.expectError(error.EnvironmentVariableMissing, environment.get("HOME"));
}

test "a variable that is set returns error.EnvironmentVariableMissing when it is injected as not set" {
    const plan = [_]injector_mod.Injection{failAt(.environment, 0, "variable_not_set")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/somewhere");
    try testing.expectError(error.EnvironmentVariableMissing, environment.get("HOME"));
    try testing.expectEqualStrings("/somewhere", try environment.get("HOME"));
}

test "a variable that is set returns an empty string when it is injected as set to an empty value" {
    const plan = [_]injector_mod.Injection{failAt(.environment, 0, "variable_set_to_an_empty_value")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/somewhere");
    try testing.expectEqualStrings("", try environment.get("HOME"));
}

test "a variable that was never set returns an empty string when it is injected as set to an empty value" {
    const plan = [_]injector_mod.Injection{failAt(.environment, 0, "variable_set_to_an_empty_value")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try testing.expectEqualStrings("", try environment.get("NOT_SET"));
}

test "getAlloc copies the value and returns the same failures" {
    const plan = [_]injector_mod.Injection{failAt(.environment, 1, "variable_not_set")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/somewhere");
    const copy = try environment.getAlloc(testing.allocator, "HOME");
    defer testing.allocator.free(copy);
    try testing.expectEqualStrings("/somewhere", copy);
    try testing.expectError(error.EnvironmentVariableMissing, environment.getAlloc(testing.allocator, "HOME"));
}

test "every read asks the injector once" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var environment = Environment.init(testing.allocator);
    defer environment.deinit();
    try environment.put("A", "1");
    _ = try environment.get("A");
    _ = environment.get("B") catch {};
    try testing.expectEqual(@as(usize, 2), world.injector.recorded.items.len);
}
