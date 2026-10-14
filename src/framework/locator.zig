// Finds value factories in a sim file's namespace by the type they return. Faultline's real run
// reaches a sim file as a namespace type (`@import("name.sim.zig")`), so the lookup is done at
// comptime by reflection over that type. Two kinds of factory are found:
//
// - a public function that returns a value of the requested type (or an error union of it) and
// - a public method of a public struct, where the method takes `self: *Struct` as its first
//   parameter and returns a value. The struct holds state between calls: one receiver is created
//   per locator and every call of one of its methods uses it, so a method can return the next value
//   in a sequence. A struct is used this way only when every field has a default value, because
//   that is how Faultline makes the receiver.
//
// Every match is a separate choice, in the order the sim file declares them, so a working factory
// and one factory per fault are all tried. The interface is `canMake`, `count` and `make`.
//
// A factory's other parameters are built by whatever the caller passes to `make` as the builder,
// which is any value with a `fill(comptime Parameter: type, slot: *Parameter)` method that builds
// the parameter into the slot.

const std = @import("std");

// How many declarations of a sim file may be examined before the comptime evaluation limit is
// raised. A sim file holds a handful of factories, scenarios and expectation functions, so this is
// generous.
const comptime_branch_quota: u32 = 200_000;

// How many values a struct factory offers: the first, second and third value of its sequence. Every
// call of the function under test runs in a process of its own, so a receiver never lives long
// enough to be used twice in one call. Offering the first values of the sequence as separate
// choices is what makes a factory with state hand over different values. Three because that is
// enough to leave the state a receiver starts with, and every choice costs a call.
pub const series_length: usize = 3;

// A factory found in the namespace.
const Match = struct {
    // Which struct's receiver the factory is a method of, as an index into the locator's list of
    // state structs. Null for a function that stands alone.
    owner: ?usize,

    // The name of the function: a declaration of the namespace, or of the owner.
    name: [:0]const u8,
};

// Whether `Function` is a function a factory for `T` may be: not generic, not variadic, returns
// `T` or an error union of `T`, takes only parameters with a type and none that is a type and
// when it is a method, takes `*Owner` first. Functions returning nothing are scenarios and
// expectation functions and are never factories.
fn isFactoryFor(comptime Function: type, comptime T: type, comptime Owner: ?type) bool {
    const info = @typeInfo(Function);
    if (info != .@"fn") {
        return false;
    }
    const signature = info.@"fn";
    if (signature.is_generic or signature.is_var_args) {
        return false;
    }
    const returned = signature.return_type orelse return false;
    const made = if (@typeInfo(returned) == .error_union) @typeInfo(returned).error_union.payload else returned;
    if (made != T or T == void or T == type or T == noreturn) {
        return false;
    }
    if (Owner) |owner| {
        if (signature.params.len == 0 or signature.params[0].type != *owner) {
            return false;
        }
    }
    for (signature.params) |param| {
        const parameter = param.type orelse return false;
        if (parameter == type) {
            return false;
        }
    }
    return true;
}

// Whether a struct can be a state holder: every field has a default, so a receiver is made with
// `.{}`.
fn isDefaultConstructible(comptime S: type) bool {
    const info = @typeInfo(S);
    if (info != .@"struct" or info.@"struct".layout != .auto) {
        return false;
    }
    for (info.@"struct".fields) |field| {
        if (!field.is_comptime and field.defaultValue() == null) {
            return false;
        }
    }
    return true;
}

// Whether any public function of the struct could be a factory for some type: it takes `*S` first
// and returns a value.
fn hasFactoryMethod(comptime S: type) bool {
    for (@typeInfo(S).@"struct".decls) |decl| {
        const member = @field(S, decl.name);
        const Member = @TypeOf(member);
        if (@typeInfo(Member) != .@"fn") {
            continue;
        }
        const signature = @typeInfo(Member).@"fn";
        if (signature.is_generic or signature.is_var_args or signature.params.len == 0) {
            continue;
        }
        const returned = signature.return_type orelse continue;
        const made = if (@typeInfo(returned) == .error_union) @typeInfo(returned).error_union.payload else returned;
        if (signature.params[0].type == *S and made != void and made != noreturn and made != type) {
            return true;
        }
    }
    return false;
}

// The public structs of a namespace that hold state for factory methods, in declaration order.
fn stateStructs(comptime Namespace: type) []const type {
    @setEvalBranchQuota(comptime_branch_quota);
    const found = comptime blk: {
        const decls = @typeInfo(Namespace).@"struct".decls;
        var list: [decls.len]type = undefined;
        var length: usize = 0;
        for (decls) |decl| {
            const member = @field(Namespace, decl.name);
            if (@TypeOf(member) != type or @typeInfo(member) != .@"struct") {
                continue;
            }
            if (isDefaultConstructible(member) and hasFactoryMethod(member)) {
                list[length] = member;
                length += 1;
            }
        }
        const out: [length]type = list[0..length].*;
        break :blk out;
    };
    return &found;
}

// A locator over the namespace type of one sim file. It holds one receiver for each state struct
// in the namespace, so `init` starts a series of calls and `reset` starts the next one.
pub fn Locator(comptime Namespace: type) type {
    return struct {
        const Self = @This();

        // The structs whose methods are factories and whose receivers this locator holds.
        const state_types = stateStructs(Namespace);

        // One receiver for each of those structs, in the same order.
        const Receivers = @Tuple(state_types);

        // The receivers. Created once and used by every call of a method on the same struct, which
        // is what lets a struct factory return a different value each time.
        receivers: Receivers,

        // Starts a series of calls: every receiver is a fresh default one.
        pub fn init() Self {
            var receivers: Receivers = undefined;
            inline for (state_types, 0..) |S, index| {
                receivers[index] = S{};
            }
            return .{ .receivers = receivers };
        }

        // Starts the next series of calls: every receiver goes back to a fresh default one.
        pub fn reset(self: *Self) void {
            self.* = init();
        }

        // Every factory for `T` in the namespace, in the order the namespace declares them: the
        // standalone functions and the struct methods interleaved as they appear.
        fn matchesFor(comptime T: type) []const Match {
            @setEvalBranchQuota(comptime_branch_quota);
            const found = comptime blk: {
                var list: [max_matches]Match = undefined;
                var length: usize = 0;
                for (@typeInfo(Namespace).@"struct".decls) |decl| {
                    const member = @field(Namespace, decl.name);
                    const Member = @TypeOf(member);
                    if (@typeInfo(Member) == .@"fn") {
                        if (isFactoryFor(Member, T, null)) {
                            list[length] = .{ .owner = null, .name = decl.name };
                            length += 1;
                        }
                    } else if (Member == type and @typeInfo(member) == .@"struct") {
                        const owner_index = ownerIndex(member) orelse continue;
                        for (@typeInfo(member).@"struct".decls) |method| {
                            if (isFactoryFor(@TypeOf(@field(member, method.name)), T, member)) {
                                list[length] = .{ .owner = owner_index, .name = method.name };
                                length += 1;
                            }
                        }
                    }
                }
                const out: [length]Match = list[0..length].*;
                break :blk out;
            };
            return &found;
        }

        // The most factories for one type a sim file may hold. A hard limit on a comptime array.
        const max_matches = 1024;

        // The position of a struct among the state structs, or null when it is not one.
        fn ownerIndex(comptime S: type) ?usize {
            inline for (state_types, 0..) |candidate, index| {
                if (candidate == S) {
                    return index;
                }
            }
            return null;
        }

        // Whether the namespace holds at least one factory for `T`.
        pub fn canMake(comptime T: type) bool {
            return (comptime matchesFor(T)).len > 0;
        }

        // The name of the factory at `index` for `T`, as the sim file declares it, or null for an
        // index past the last one. Every place in a struct factory's series has the method's name.
        pub fn nameOf(comptime T: type, index: usize) ?[]const u8 {
            var seen: usize = 0;
            inline for (comptime matchesFor(T)) |match| {
                if (index >= seen and index < seen + comptime repeatsOf(match)) {
                    return match.name;
                }
                seen += comptime repeatsOf(match);
            }
            return null;
        }

        // How many factories for `T` the namespace holds.
        pub fn count(comptime T: type) usize {
            var total: usize = 0;
            inline for (comptime matchesFor(T)) |match| {
                total += repeatsOf(match);
            }
            return total;
        }

        // How many choices a factory gives: one for a function that stands alone and a series for a
        // method of a struct that keeps state.
        fn repeatsOf(comptime match: Match) usize {
            return if (match.owner != null) series_length else 1;
        }

        // Calls the factory at `index` (counting from zero, in declaration order) and returns its
        // value. The factory's own parameters come from `builder.build(Parameter)`. A struct
        // method is called on this locator's receiver for that struct. An error the factory
        // returns is passed on. An index past the last factory is an error.
        pub fn make(self: *Self, comptime T: type, index: usize, builder: anytype) anyerror!T {
            var seen: usize = 0;
            inline for (comptime matchesFor(T)) |match| {
                if (index >= seen and index < seen + comptime repeatsOf(match)) {
                    const times = index - seen + 1;
                    const function = if (match.owner) |owner| @field(state_types[owner], match.name) else @field(Namespace, match.name);
                    var args: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
                    inline for (&args, 0..) |*slot, position| {
                        if (comptime match.owner != null and position == 0) {
                            slot.* = &self.receivers[match.owner.?];
                        } else {
                            try builder.fill(@TypeOf(slot.*), slot);
                        }
                    }
                    // A struct factory is called once more for each place later in its series, on
                    // the same receiver, and the last value is the one handed over.
                    var round: usize = 0;
                    while (round + 1 < times) : (round += 1) {
                        const earlier = @call(.auto, function, args);
                        if (comptime @typeInfo(@TypeOf(earlier)) == .error_union) {
                            _ = earlier catch {};
                        }
                    }
                    const result = @call(.auto, function, args);
                    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
                        return try result;
                    }
                    return result;
                }
                seen += comptime repeatsOf(match);
            }
            return error.NoSuchValueFactory;
        }

        // Calls the factory at `index` as `make` does and writes its value into `slot`. The only
        // way to call a factory for an error set, which cannot be the payload of the error union
        // `make` returns, so a factory for an error set returns the error as its value.
        pub fn makeInto(self: *Self, comptime T: type, index: usize, builder: anytype, slot: *T) anyerror!void {
            if (comptime @typeInfo(T) != .error_set) {
                slot.* = try self.make(T, index, builder);
                return;
            }
            var seen: usize = 0;
            inline for (comptime matchesFor(T)) |match| {
                if (index >= seen and index < seen + comptime repeatsOf(match)) {
                    const times = index - seen + 1;
                    const function = if (match.owner) |owner| @field(state_types[owner], match.name) else @field(Namespace, match.name);
                    var args: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
                    inline for (&args, 0..) |*argument, position| {
                        if (comptime match.owner != null and position == 0) {
                            argument.* = &self.receivers[match.owner.?];
                        } else {
                            try builder.fill(@TypeOf(argument.*), argument);
                        }
                    }
                    // As in `make`: a struct factory is called once more for each place later in
                    // its series, and the last value is the one handed over.
                    var round: usize = 0;
                    while (round + 1 < times) : (round += 1) {
                        slot.* = @call(.auto, function, args);
                    }
                    slot.* = @call(.auto, function, args);
                    return;
                }
                seen += comptime repeatsOf(match);
            }
            return error.NoSuchValueFactory;
        }
    };
}

test {
    _ = @import("locator.test.zig");
}
