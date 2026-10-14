// Decides, for every simulated effect call, whether a failure happens now, and remembers every
// place a call could have failed so the run loop knows where to inject next.
//
// Every effect asks the injector once per call, whether or not a failure is planned. The answer is
// a failure only when the plan names that place. Asking is also what records the place, so a call
// with a failure injected records the places it reaches just as a call without one does.

const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");

// One failure the plan asks for: at this place, the kind with this index in the effect's table.
pub const Injection = struct {
    // Where the failure happens.
    point: point.Point,

    // The index of the failure in `failures.kindsOf(point.effect)`.
    kind: u8,
};

// One place a call reached, with the failures that can happen there. The run loop turns each of
// these into one call per failure.
pub const Place = struct {
    // Where the call was.
    point: point.Point,

    // The indexes, in the effect's table, of the failures that can happen to this particular call.
    // Not every failure in a group can happen to every call: a read cannot find a file missing.
    kinds: []const u8,
};

pub const Injector = struct {
    // Where recorded places are kept.
    allocator: std.mem.Allocator,

    // The failures to inject, each at its place. Empty means nothing fails.
    plan: []const Injection,

    // How many calls of each effect have been seen so far in this call of the function.
    counts: [point.effect_count]u32 = [_]u32{0} ** point.effect_count,

    // Every place reached so far, in the order reached.
    recorded: std.ArrayList(Place) = .empty,

    // Builds an injector that fails exactly the places `plan` names. The plan has to outlive the
    // injector: it is not copied.
    pub fn init(allocator: std.mem.Allocator, plan: []const Injection) Injector {
        return .{ .allocator = allocator, .plan = plan };
    }

    pub fn deinit(self: *Injector) void {
        self.recorded.deinit(self.allocator);
    }

    // Forgets the calls counted and the places recorded, ready for the next call of the function.
    pub fn reset(self: *Injector) void {
        self.counts = [_]u32{0} ** point.effect_count;
        self.recorded.clearRetainingCapacity();
    }

    // Called once by every simulated effect call. Records the place and returns the index of the
    // failure to inject there, or null when the call goes ahead. `kinds` is what can happen to this
    // call, and a planned failure that is not in it is ignored.
    pub fn check(self: *Injector, effect: point.Effect, kinds: []const u8) ?u8 {
        const index = @intFromEnum(effect);
        const here: point.Point = .{ .effect = effect, .occurrence = self.counts[index] };
        self.counts[index] += 1;

        // A loud crash is the right answer to running out of memory while recording, because the
        // number of places is bounded by the calls the function under test makes and not by anything
        // a caller controls.
        self.recorded.append(self.allocator, .{ .point = here, .kinds = kinds }) catch {
            @panic("faultline: out of memory recording a place");
        };

        for (self.plan) |injection| {
            if (!injection.point.eql(here)) {
                continue;
            }
            for (kinds) |allowed| {
                if (allowed == injection.kind) {
                    return injection.kind;
                }
            }
        }
        return null;
    }

    // What a failure at `at` is called in a replay token and in a failure message.
    pub fn nameOf(injection: Injection) []const u8 {
        return failures.kindsOf(injection.point.effect)[injection.kind].id;
    }
};

test {
    _ = @import("injector.test.zig");
}
