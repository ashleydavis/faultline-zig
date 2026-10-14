// Which value each parameter of a function is given in each call, as data. A `Choice` names one
// value that can be built for a parameter, so a replay token can carry the values a call used. A
// call specification is one `Choice` per parameter. This file turns the choices available for each
// parameter into the finite list of specifications the run loop calls the function with. It knows
// nothing about types: it works on lists of choices only.

const std = @import("std");

// Where a value comes from.
pub const Source = enum {
    // The fixed list of boundary values for the type.
    boundary,

    // A value from the run's random number generator.
    seeded,

    // A value read from a condition in the function's source.
    condition,

    // A value factory found in the sim file.
    factory,
};

// One value that can be chosen for a parameter. What the index means depends on the source: a
// position in the boundary list, which seeded value of the few, a position in the list of
// candidates read from the conditions, or which factory in the order the sim file declares them.
pub const Choice = struct {
    // Where the value comes from.
    source: Source,

    // Which of the values from that source.
    index: u32,
};

// What a call is made with: one choice per parameter, in parameter order.
pub const Spec = []const Choice;

// The list of call specifications for a function whose parameters have the choices in `lists`
// (one list per parameter, the first choice of each being its baseline): every combination of every
// parameter's choices, each once. The list is, in this order: the baseline; then every other choice
// of each parameter in turn with the others at their baseline; then every combination that changes
// two or more parameters, in the order an odometer counts them with the last parameter turning
// fastest. The same lists always give the same specifications. When any parameter has no choice at
// all the function cannot be called and the list is empty. A function with no parameters has one
// specification with no choices.
pub fn generateSpecs(allocator: std.mem.Allocator, lists: []const []const Choice) error{OutOfMemory}![]const Spec {
    for (lists) |list| {
        if (list.len == 0) {
            return &.{};
        }
    }

    var specs: std.ArrayList(Spec) = .empty;

    const baseline = try allocator.alloc(Choice, lists.len);
    for (lists, 0..) |list, position| {
        baseline[position] = list[0];
    }
    try specs.append(allocator, baseline);

    for (lists, 0..) |list, position| {
        for (list[1..]) |choice| {
            const changed = try allocator.dupe(Choice, baseline);
            changed[position] = choice;
            try specs.append(allocator, changed);
        }
    }

    // The odometer: which choice of each parameter the next combination takes.
    const at = try allocator.alloc(usize, lists.len);
    defer allocator.free(at);
    @memset(at, 0);
    while (advance(at, lists)) {
        var changed: usize = 0;
        for (at) |index| {
            if (index != 0) {
                changed += 1;
            }
        }
        if (changed < 2) {
            continue;
        }
        const combination = try allocator.alloc(Choice, lists.len);
        for (lists, at, 0..) |list, index, position| {
            combination[position] = list[index];
        }
        try specs.append(allocator, combination);
    }
    return specs.items;
}

// Moves the odometer `at` on by one, the last parameter turning fastest. Returns false once every
// combination has been counted.
fn advance(at: []usize, lists: []const []const Choice) bool {
    var position = at.len;
    while (position > 0) {
        position -= 1;
        at[position] += 1;
        if (at[position] < lists[position].len) {
            return true;
        }
        at[position] = 0;
    }
    return false;
}

// Whether two specifications name the same choices.
pub fn isSameSpec(first: Spec, second: Spec) bool {
    if (first.len != second.len) {
        return false;
    }
    for (first, second) |one, other| {
        if (one.source != other.source or one.index != other.index) {
            return false;
        }
    }
    return true;
}

test {
    _ = @import("call_specs.test.zig");
}
