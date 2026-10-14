const std = @import("std");
const explore = @import("explore.zig");
const injector = @import("injector.zig");
const point = @import("point.zig");

const two_kinds = [_]u8{ 0, 1 };

// A function that is simulated: it reaches the places in `baseline` and, after a failure at a place
// named in `adds`, reaches one more.
const Fake = struct {
    baseline: []const injector.Place,
    extra_after: ?point.Point = null,
    extra_place: ?injector.Place = null,
    crash_on: ?point.Point = null,
    plans_seen: std.ArrayList([]const injector.Injection) = .empty,
    buffer: [8]injector.Place = undefined,

    fn deinit(self: *Fake) void {
        for (self.plans_seen.items) |plan| {
            std.testing.allocator.free(plan);
        }
        self.plans_seen.deinit(std.testing.allocator);
    }

    pub fn call(self: *Fake, plan: []const injector.Injection) anyerror!explore.Observed {
        var count: usize = 0;
        for (self.baseline) |place| {
            self.buffer[count] = place;
            count += 1;
        }
        for (plan) |injection| {
            if (self.crash_on) |crash| {
                if (injection.point.eql(crash)) {
                    return .{ .is_dead_end = true, .places = &.{} };
                }
            }
            if (self.extra_after) |after| {
                if (injection.point.eql(after) and self.extra_place != null) {
                    self.buffer[count] = self.extra_place.?;
                    count += 1;
                }
            }
        }
        return .{ .is_dead_end = false, .places = self.buffer[0..count] };
    }

    pub fn seen(self: *Fake, plan: []const injector.Injection, _: explore.Observed) void {
        // The plan lives only as long as the exploration, so the test keeps a copy.
        const copy = std.testing.allocator.dupe(injector.Injection, plan) catch unreachable;
        self.plans_seen.append(std.testing.allocator, copy) catch unreachable;
    }
};

test "a function that reaches nothing is called once with nothing injected" {
    var fake: Fake = .{ .baseline = &.{} };
    defer fake.deinit();

    const outcome = try explore.explore(std.testing.allocator, &fake, 4);

    try std.testing.expectEqual(@as(usize, 1), outcome.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.plans_seen.items[0].len);
    try std.testing.expect(!outcome.is_cut_short);
}

test "every failure at every place is tried once with one failure injected" {
    const places = [_]injector.Place{
        .{ .point = .{ .effect = .read, .occurrence = 0 }, .kinds = &two_kinds },
        .{ .point = .{ .effect = .write, .occurrence = 0 }, .kinds = &two_kinds },
    };
    var fake: Fake = .{ .baseline = &places };
    defer fake.deinit();

    const outcome = try explore.explore(std.testing.allocator, &fake, 4);

    // One call with nothing injected and two failures at each of two places.
    try std.testing.expectEqual(@as(usize, 5), outcome.calls);
    for (fake.plans_seen.items[1..]) |plan| {
        try std.testing.expectEqual(@as(usize, 1), plan.len);
    }
}

test "a place that only exists after a failure is tried with that failure kept in the plan" {
    const baseline = [_]injector.Place{.{ .point = .{ .effect = .read, .occurrence = 0 }, .kinds = &two_kinds }};
    const extra = injector.Place{ .point = .{ .effect = .write, .occurrence = 0 }, .kinds = &two_kinds };
    var fake: Fake = .{
        .baseline = &baseline,
        .extra_after = .{ .effect = .read, .occurrence = 0 },
        .extra_place = extra,
    };
    defer fake.deinit();

    _ = try explore.explore(std.testing.allocator, &fake, 4);

    var found_two_failures = false;
    for (fake.plans_seen.items) |plan| {
        if (plan.len == 2) {
            found_two_failures = true;
            try std.testing.expect(plan[0].point.eql(.{ .effect = .read, .occurrence = 0 }));
            try std.testing.expect(plan[1].point.eql(.{ .effect = .write, .occurrence = 0 }));
        }
    }
    try std.testing.expect(found_two_failures);
}

test "a call that crashes is not explored below" {
    const baseline = [_]injector.Place{.{ .point = .{ .effect = .read, .occurrence = 0 }, .kinds = &two_kinds }};
    const extra = injector.Place{ .point = .{ .effect = .write, .occurrence = 0 }, .kinds = &two_kinds };
    var fake: Fake = .{
        .baseline = &baseline,
        .extra_after = .{ .effect = .read, .occurrence = 0 },
        .extra_place = extra,
        .crash_on = .{ .effect = .read, .occurrence = 0 },
    };
    defer fake.deinit();

    _ = try explore.explore(std.testing.allocator, &fake, 4);

    for (fake.plans_seen.items) |plan| {
        try std.testing.expect(plan.len <= 1);
    }
}

test "a failure already tried at a place is not tried again when a later call reaches the place" {
    const places = [_]injector.Place{.{ .point = .{ .effect = .read, .occurrence = 0 }, .kinds = &two_kinds }};
    var fake: Fake = .{ .baseline = &places };
    defer fake.deinit();

    const outcome = try explore.explore(std.testing.allocator, &fake, 4);

    try std.testing.expectEqual(@as(usize, 3), outcome.calls);
}

test "with one failure allowed a place that only exists after a failure is not tried" {
    const baseline = [_]injector.Place{.{ .point = .{ .effect = .read, .occurrence = 0 }, .kinds = &two_kinds }};
    const extra = injector.Place{ .point = .{ .effect = .write, .occurrence = 0 }, .kinds = &two_kinds };
    var fake: Fake = .{
        .baseline = &baseline,
        .extra_after = .{ .effect = .read, .occurrence = 0 },
        .extra_place = extra,
    };
    defer fake.deinit();

    _ = try explore.explore(std.testing.allocator, &fake, explore.max_injections_per_call);

    for (fake.plans_seen.items) |plan| {
        try std.testing.expect(plan.len <= 1);
    }
}
