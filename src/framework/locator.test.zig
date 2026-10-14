const std = @import("std");
const locator = @import("locator.zig");

const Loader = struct {
    source: []const u8,
    fails: bool,
};

// A namespace laid out like a sim file: factories by return type, a struct with state, scenario and
// expectation style functions that must not be mistaken for factories and things that are not
// functions at all.
const SimFile = struct {
    pub const retry_limit = 3;

    pub fn workingLoader() Loader {
        return .{ .source = "ok", .fails = false };
    }

    pub fn missingFileLoader() Loader {
        return .{ .source = "", .fails = true };
    }

    pub fn failingLoader() error{Broken}!Loader {
        return error.Broken;
    }

    pub fn greeting(prefix: []const u8) []const u8 {
        return prefix;
    }

    pub fn scenarioShaped(context: *u8) anyerror!void {
        _ = context;
    }

    pub fn nothing() void {}

    pub fn generic(comptime T: type) T {
        return undefined;
    }

    fn hidden() Loader {
        return .{ .source = "hidden", .fails = false };
    }

    pub const Counter = struct {
        next_value: u32 = 10,
        calls: u32 = 0,

        pub fn number(self: *Counter) u32 {
            self.calls += 1;
            self.next_value += 1;
            return self.next_value;
        }

        pub fn loader(self: *Counter) Loader {
            self.calls += 1;
            return .{ .source = "counted", .fails = self.calls > 2 };
        }

        pub fn calledTimes(self: *const Counter) u32 {
            return self.calls;
        }

        pub fn reportDone(self: *Counter) void {
            self.calls += 100;
        }
    };

    // Has a field with no default, so Faultline cannot make its receiver.
    pub const NeedsArguments = struct {
        required: u32,

        pub fn value(self: *NeedsArguments) u64 {
            return self.required;
        }
    };
};

const Located = locator.Locator(SimFile);

// A builder for factory parameters: hands out a fixed string and zero.
const FixedBuilder = struct {
    pub fn fill(self: FixedBuilder, comptime P: type, slot: *P) anyerror!void {
        _ = self;
        if (P == []const u8) {
            slot.* = "built";
        } else {
            slot.* = 0;
        }
    }
};

test "a public function is found by the type it returns" {
    try std.testing.expect(comptime Located.canMake(Loader));
    try std.testing.expect(comptime Located.canMake(u32));
    try std.testing.expect(comptime Located.canMake([]const u8));
}

test "every matching factory is counted, standalone and struct methods together, in declaration order" {
    try std.testing.expectEqual(3 + locator.series_length, comptime Located.count(Loader));
    try std.testing.expectEqual(locator.series_length, comptime Located.count(u32));
}

test "a type no factory returns cannot be made" {
    try std.testing.expect(!(comptime Located.canMake(f64)));
    try std.testing.expectEqual(@as(usize, 0), comptime Located.count(f64));
    try std.testing.expect(!(comptime Located.canMake(u64)));
}

test "functions returning nothing, generic functions and private ones are never factories" {
    try std.testing.expect(!(comptime Located.canMake(void)));
    try std.testing.expect(!(comptime Located.canMake(type)));
    var state = Located.init();
    var seen_hidden = false;
    inline for (0..4) |index| {
        if (state.make(Loader, index, FixedBuilder{})) |made| {
            if (std.mem.eql(u8, made.source, "hidden")) {
                seen_hidden = true;
            }
        } else |_| {}
    }
    try std.testing.expect(!seen_hidden);
}

test "factories of one type are made in declaration order" {
    var state = Located.init();
    const first = try state.make(Loader, 0, FixedBuilder{});
    try std.testing.expectEqualStrings("ok", first.source);
    try std.testing.expect(!first.fails);
    const second = try state.make(Loader, 1, FixedBuilder{});
    try std.testing.expect(second.fails);
    // The third factory returns an error, which is passed on.
    try std.testing.expectError(error.Broken, state.make(Loader, 2, FixedBuilder{}));
    // The fourth is a method of the Counter struct.
    const fourth = try state.make(Loader, 3, FixedBuilder{});
    try std.testing.expectEqualStrings("counted", fourth.source);
}

test "a factory's own parameters come from the builder" {
    var state = Located.init();
    const made = try state.make([]const u8, 0, FixedBuilder{});
    try std.testing.expectEqualStrings("built", made);
}

test "a struct factory keeps its state between calls, so each call can return the next value" {
    var state = Located.init();
    try std.testing.expectEqual(@as(u32, 11), try state.make(u32, 0, FixedBuilder{}));
    try std.testing.expectEqual(@as(u32, 12), try state.make(u32, 0, FixedBuilder{}));
    try std.testing.expectEqual(@as(u32, 13), try state.make(u32, 0, FixedBuilder{}));
}

test "the methods of one struct share one receiver" {
    var state = Located.init();
    _ = try state.make(u32, 0, FixedBuilder{});
    const second = try state.make(Loader, 3, FixedBuilder{});
    // The method that made the number counted as the first call, so this is the second.
    try std.testing.expect(!second.fails);
    const third = try state.make(Loader, 3, FixedBuilder{});
    try std.testing.expect(third.fails);
}

test "reset starts a new series of calls from fresh receivers" {
    var state = Located.init();
    _ = try state.make(u32, 0, FixedBuilder{});
    _ = try state.make(u32, 0, FixedBuilder{});
    state.reset();
    try std.testing.expectEqual(@as(u32, 11), try state.make(u32, 0, FixedBuilder{}));
}

test "two locators over the same namespace keep separate state" {
    var one = Located.init();
    var two = Located.init();
    _ = try one.make(u32, 0, FixedBuilder{});
    _ = try one.make(u32, 0, FixedBuilder{});
    try std.testing.expectEqual(@as(u32, 11), try two.make(u32, 0, FixedBuilder{}));
}

test "methods that take a const receiver or return nothing are not factories" {
    // The only u32 factory is Counter.number: calledTimes takes a const receiver.
    try std.testing.expectEqual(locator.series_length, comptime Located.count(u32));
}

test "a struct whose receiver cannot be made by default is not used" {
    try std.testing.expect(!(comptime Located.canMake(u64)));
}

test "an index past the last factory is an error" {
    var state = Located.init();
    try std.testing.expectError(error.NoSuchValueFactory, state.make(Loader, 9 + locator.series_length, FixedBuilder{}));
}

test "a namespace with no factories makes nothing" {
    const Empty = locator.Locator(struct {});
    try std.testing.expect(!(comptime Empty.canMake(u32)));
    try std.testing.expectEqual(@as(usize, 0), comptime Empty.count(Loader));
    var state = Empty.init();
    state.reset();
    try std.testing.expectError(error.NoSuchValueFactory, state.make(u32, 0, FixedBuilder{}));
}

test "a file imported as a namespace is searched the same way" {
    const Real = locator.Locator(@import("locator.fixture.zig"));
    try std.testing.expectEqual(1 + locator.series_length, comptime Real.count(u16));
    var state = Real.init();
    try std.testing.expectEqual(@as(u16, 7), try state.make(u16, 0, FixedBuilder{}));
    try std.testing.expectEqual(@as(u16, 1), try state.make(u16, 1, FixedBuilder{}));
    try std.testing.expectEqual(@as(u16, 2), try state.make(u16, 1, FixedBuilder{}));
}

test "a struct factory offers the first values of its sequence as separate choices" {
    var state = Located.init();

    const first = try state.make(u32, 0, FixedBuilder{});
    state.reset();
    const second = try state.make(u32, 1, FixedBuilder{});
    state.reset();
    const third = try state.make(u32, 2, FixedBuilder{});

    try std.testing.expect(first != second);
    try std.testing.expect(second != third);
}
