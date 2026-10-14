const std = @import("std");
const functions = @import("functions.zig");

const Fixture = struct {
    pub fn alpha(value: u32) u32 {
        return value;
    }

    fn hidden() void {}

    pub const Counter = struct {
        count: u32 = 0,

        pub fn bump(self: *Counter) void {
            self.count += 1;
        }

        pub fn peek(self: Counter) u32 {
            return self.count;
        }

        pub fn make() Counter {
            return .{};
        }

        pub fn look(self: *const Counter) u32 {
            return self.count;
        }
    };

    pub const limit: u32 = 3;

    pub fn beta() void {}
};

test "top level public functions are found in declaration order" {
    const found = comptime functions.listIn(Fixture);

    try std.testing.expectEqualStrings("alpha", found[0].name);
    try std.testing.expect(found[0].owner == null);
}

test "private functions and constants are not found" {
    const found = comptime functions.listIn(Fixture);

    inline for (found) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.name, "hidden"));
        try std.testing.expect(!std.mem.eql(u8, entry.name, "limit"));
    }
}

test "methods that take the struct or a pointer to it are found with their owner" {
    const found = comptime functions.listIn(Fixture);

    var methods: usize = 0;
    inline for (found) |entry| {
        if (entry.owner) |owner| {
            try std.testing.expectEqualStrings("Counter", owner);
            methods += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), methods);
}

test "a function with no receiver inside a struct is not found" {
    const found = comptime functions.listIn(Fixture);

    inline for (found) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.name, "make"));
    }
}

test "qualifiedName joins a method to its owner" {
    var buffer: [64]u8 = undefined;
    const method: functions.Found = .{ .name = "bump", .owner = "Counter" };
    const plain: functions.Found = .{ .name = "alpha", .owner = null };

    try std.testing.expectEqualStrings("Counter.bump", method.qualifiedName(&buffer));
    try std.testing.expectEqualStrings("alpha", plain.qualifiedName(&buffer));
}

test "functionOf gives the function that was found" {
    const found = comptime functions.listIn(Fixture);

    const alpha = functions.functionOf(Fixture, found[0]);

    try std.testing.expectEqual(@as(u32, 7), alpha(7));
}

test "a namespace that is not a struct has no functions" {
    const found = comptime functions.listIn(u32);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}
