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

// How many choices of each parameter take part in combinations with another parameter's choices.
// Four, because the choices after the first are ordered with the fixed ones first (the factories, or
// one, minus one, the minimum and the maximum) and those are the ones that make a second
// parameter's branch go the other way. The rest of the choices are still tried, alone.
pub const combination_choices_per_parameter: usize = 4;

// The most combination specifications one function gets. Every specification costs a call and
// then another call for every place a failure can be injected, so the combinations are limited to
// a number that costs a small fraction of what the single changes cost for a function with a few
// parameters and never more for one with many.
pub const max_combination_specs: usize = 64;

// The finite list of call specifications for a function whose parameters have the choices in
// `lists` (one list per parameter, the first choice of each being its baseline). The list is, in
// this order: the baseline; then every other choice of each parameter in turn with the others at
// their baseline; then combinations of choices across two parameters, taken in rounds so each pair
// of parameters is reached before any pair is repeated, until `max_combination_specs` is reached.
// The same lists always give the same specifications. When any parameter has no choice at all the
// function cannot be called and the list is empty. A function with no parameters has one
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

    var combinations: usize = 0;
    for (1..combination_choices_per_parameter + 1) |first_rank| {
        for (1..combination_choices_per_parameter + 1) |second_rank| {
            for (lists, 0..) |first_list, first| {
                if (first_rank >= first_list.len) {
                    continue;
                }
                for (lists[first + 1 ..], first + 1..) |second_list, second| {
                    if (second_rank >= second_list.len) {
                        continue;
                    }
                    if (combinations == max_combination_specs) {
                        return specs.items;
                    }
                    const both = try allocator.dupe(Choice, baseline);
                    both[first] = first_list[first_rank];
                    both[second] = second_list[second_rank];
                    try specs.append(allocator, both);
                    combinations += 1;
                }
            }
        }
    }
    return specs.items;
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
