// What the reader of a function's source reports about one condition in it, and what the value
// chooser consumes. Kept in a file of its own so the two sides agree on one type.
//
// A condition is anything in a function that decides which way the code goes on a value: a
// comparison against a constant, a string comparison, a switch prong, an optional or error check.
// Faultline does not follow a value through the function. It reads the constant a condition tests
// against and tries values on each side of it.

// The constant side of a condition, when there is one.
pub const Literal = union(enum) {
    // An integer, including a character literal and a comparison against `std.math` constants that
    // fold to a number.
    int: i128,

    // A floating point number.
    float: f64,

    // A string, with escapes already resolved. Owned by whatever read the source.
    string: []const u8,

    // `true` or `false`.
    boolean: bool,

    // An enum tag written as `.name` or `Type.name`, held as the name.
    enum_tag: []const u8,

    // `null`.
    null_value,
};

// What sort of condition it is.
pub const Kind = enum {
    // `a < b`, `a == 3` and the other comparison operators.
    comparison,

    // `std.mem.eql(u8, a, "text")`.
    string_equals,

    // `std.mem.startsWith(u8, a, "text")`.
    string_starts_with,

    // `std.mem.endsWith(u8, a, "text")`.
    string_ends_with,

    // One prong of a `switch`.
    switch_prong,

    // `if (optional) |value|` and `x == null`.
    optional_check,

    // `x catch`, `if (x) |_| else |err|` and `x == error.Something`.
    error_check,
};

// The comparison operator of a `comparison`.
pub const Operator = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

// One condition found in a function.
pub const Condition = struct {
    // The line the condition is on, counting from one.
    line: u32,

    // What sort of condition it is.
    kind: Kind,

    // The operator, for a comparison. Null for every other kind.
    operator: ?Operator = null,

    // The constant the condition tests against, when it tests against one.
    literal: ?Literal = null,

    // The source text of the side that is not the constant, for the report of what Faultline read.
    // A slice of the source the condition was read from.
    subject: []const u8 = "",
};

test {
    _ = @import("condition.test.zig");
}
