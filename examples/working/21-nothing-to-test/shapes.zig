// A file that declares no function. It holds types and a value, so there is nothing in it to call.

// A point that other files pass around. A type with no behaviour.
pub const Point = struct {
    // How far right of the origin the point is.
    x: i32,
    // How far above the origin the point is.
    y: i32,
};

// The point every other point is measured from.
pub const origin: Point = .{ .x = 0, .y = 0 };
