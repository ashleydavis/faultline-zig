// Decides which failures to inject, for one specification of one function, from what each call
// turns out to reach.
//
// It starts with a call that injects nothing. Every call reports the places where something could
// fail and which failures can happen there. For each place and each failure that can happen there,
// one more call injects exactly that failure. A call with a failure injected reports places of its
// own, and a place that no earlier call reached (one that exists only because of the earlier
// failure) is tried the same way, with the earlier failure kept in the plan.
//
// Each (effect, occurrence, failure) is tried once, so a function is called once for each such
// triple plus the call that injects nothing.

const std = @import("std");
const point = @import("point.zig");
const injector = @import("injector.zig");

// The most failures one call carries. One, as the contract says: a call that has two failures
// injected reaches states the real world cannot, and the standard library's own code then fails on
// them (found while building the examples: three failures in one call made `std.Io.File.Reader`
// unwrap a missing error). The code below still follows a place that exists only after a failure,
// so a larger limit is a change of one number, and the tests use one.
pub const max_injections_per_call: usize = 1;

// The most calls made for one specification. A function that reads a file in a loop reaches a new
// place for every chunk, and without a limit it would be called for each of them. The limit is far
// above what a function with a few effects needs, and a function that reaches it has the rest of
// its places left untried, which the run says.
pub const max_calls_per_specification: usize = 4096;

// What one call showed. `places` borrows from whatever produced it and stays valid until the next
// call.
pub const Observed = struct {
    // Whether the call ended in a way that stops exploring below it: it crashed or never returned.
    is_dead_end: bool,

    // The places the call reached, in order.
    places: []const injector.Place,
};

// How an exploration ended.
pub const Outcome = struct {
    // How many calls were made, the first with no failure injected.
    calls: usize,

    // Whether the limit on calls was reached with places still untried.
    is_cut_short: bool,
};

// Explores one specification. `executor` has `call(self, plan: []const injector.Injection) anyerror!Observed`,
// which makes the call and returns what it showed, and `seen(self, plan, observed) void`, told of
// every call made so the caller can collect results. `allocator` holds the plans. `max_injections`
// is the most failures one call carries.
pub fn explore(allocator: std.mem.Allocator, executor: anytype, max_injections: usize) !Outcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const room = arena.allocator();

    var queue: std.ArrayList([]const injector.Injection) = .empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, &.{});

    var tried: std.AutoHashMapUnmanaged(Key, void) = .empty;
    defer tried.deinit(allocator);

    var calls: usize = 0;
    var is_cut_short = false;
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        if (calls >= max_calls_per_specification) {
            is_cut_short = true;
            break;
        }
        const plan = queue.items[next];
        const observed = try executor.call(plan);
        calls += 1;
        executor.seen(plan, observed);
        if (observed.is_dead_end) {
            continue;
        }
        for (observed.places) |place| {
            if (isInPlan(plan, place.point)) {
                continue;
            }
            for (place.kinds) |kind| {
                const key: Key = .{ .effect = place.point.effect, .occurrence = place.point.occurrence, .kind = kind };
                const entry = try tried.getOrPut(allocator, key);
                if (entry.found_existing) {
                    continue;
                }
                if (plan.len + 1 > max_injections) {
                    continue;
                }
                const longer = try room.alloc(injector.Injection, plan.len + 1);
                @memcpy(longer[0..plan.len], plan);
                longer[plan.len] = .{ .point = place.point, .kind = kind };
                try queue.append(allocator, longer);
            }
        }
    }
    return .{ .calls = calls, .is_cut_short = is_cut_short };
}

// One failure at one place, which is what is tried once.
const Key = struct {
    effect: point.Effect,
    occurrence: u32,
    kind: u8,
};

fn isInPlan(plan: []const injector.Injection, place: point.Point) bool {
    for (plan) |injection| {
        if (injection.point.eql(place)) {
            return true;
        }
    }
    return false;
}

test {
    _ = @import("explore.test.zig");
}
