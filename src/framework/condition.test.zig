const std = @import("std");
const condition = @import("condition.zig");

test "a condition has no operator and no literal until one is given" {
    const found: condition.Condition = .{ .line = 3, .kind = .optional_check };

    try std.testing.expectEqual(@as(?condition.Operator, null), found.operator);
    try std.testing.expect(found.literal == null);
    try std.testing.expectEqualStrings("", found.subject);
}

test "a comparison carries its operator and the constant it compares against" {
    const found: condition.Condition = .{
        .line = 9,
        .kind = .comparison,
        .operator = .greater,
        .literal = .{ .int = 1000 },
        .subject = "value",
    };

    try std.testing.expectEqual(condition.Operator.greater, found.operator.?);
    try std.testing.expectEqual(@as(i128, 1000), found.literal.?.int);
}
