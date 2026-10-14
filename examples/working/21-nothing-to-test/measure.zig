// The one file in this example that has a function, so the run has something to call.

const shapes = @import("shapes.zig");

// Whether the point is on the right of the origin or straight above or below it.
pub fn isRightOfOrigin(point: shapes.Point) bool {
    if (point.x >= shapes.origin.x) {
        return true;
    }
    return false;
}
