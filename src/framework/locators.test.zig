const std = @import("std");
const locators = @import("locators.zig");
const locator = @import("locator.zig");

const Item = struct { value: u32 };
const Other = struct { name: []const u8 };

const First = struct {
    pub fn workingItem() Item {
        return .{ .value = 1 };
    }

    pub fn brokenItem() Item {
        return .{ .value = 2 };
    }
};

const Second = struct {
    pub fn lastItem() Item {
        return .{ .value = 3 };
    }

    pub fn otherThing() Other {
        return .{ .name = "x" };
    }

    pub const Counter = struct {
        count: u32 = 0,

        pub fn next(self: *Counter) Item {
            self.count += 1;
            return .{ .value = 100 + self.count };
        }
    };
};

const Both = locators.Combined(&.{ First, Second });

const NoBuilder = struct {
    pub fn fill(_: NoBuilder, comptime Parameter: type, _: *Parameter) !void {}
};

test "a type is buildable when any namespace has a factory for it" {
    try std.testing.expect(Both.canMake(Item));
    try std.testing.expect(Both.canMake(Other));
    try std.testing.expect(!Both.canMake(u8));
}

test "the count adds the factories of every namespace" {
    try std.testing.expectEqual(3 + locator.series_length, Both.count(Item));
    try std.testing.expectEqual(@as(usize, 1), Both.count(Other));
}

test "make counts through the namespaces in order" {
    var both = Both.init();

    try std.testing.expectEqual(@as(u32, 1), (try both.make(Item, 0, NoBuilder{})).value);
    try std.testing.expectEqual(@as(u32, 2), (try both.make(Item, 1, NoBuilder{})).value);
    try std.testing.expectEqual(@as(u32, 3), (try both.make(Item, 2, NoBuilder{})).value);
    try std.testing.expectEqual(@as(u32, 101), (try both.make(Item, 3, NoBuilder{})).value);
}

test "a struct factory returns a different value each time until the locator is reset" {
    var both = Both.init();

    try std.testing.expectEqual(@as(u32, 101), (try both.make(Item, 3, NoBuilder{})).value);
    try std.testing.expectEqual(@as(u32, 102), (try both.make(Item, 3, NoBuilder{})).value);

    both.reset();
    try std.testing.expectEqual(@as(u32, 101), (try both.make(Item, 3, NoBuilder{})).value);
}

test "an index past the last factory is an error" {
    var both = Both.init();

    try std.testing.expectError(error.NoSuchValueFactory, both.make(Item, 3 + locator.series_length, NoBuilder{}));
}

test "no namespaces means nothing can be made" {
    const Nothing = locators.Combined(&.{});

    try std.testing.expect(!Nothing.canMake(Item));
    try std.testing.expectEqual(@as(usize, 0), Nothing.count(Item));
}

// Two sim files that each word an error, for the error set factories of a combined locator.
const FirstErrors = struct {
    pub fn missingFile() anyerror {
        return error.FileNotFound;
    }
};
const SecondErrors = struct {
    pub fn deniedAccess() anyerror {
        return error.AccessDenied;
    }
};

test "makeInto counts through the namespaces in order for an error set" {
    var both = locators.Combined(&.{ FirstErrors, SecondErrors }).init();
    var made: anyerror = undefined;

    try both.makeInto(anyerror, 0, NoBuilder{}, &made);
    try std.testing.expectEqual(@as(anyerror, error.FileNotFound), made);
    try both.makeInto(anyerror, 1, NoBuilder{}, &made);
    try std.testing.expectEqual(@as(anyerror, error.AccessDenied), made);
    try std.testing.expectError(error.NoSuchValueFactory, both.makeInto(anyerror, 2, NoBuilder{}, &made));
}
