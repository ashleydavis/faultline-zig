// A scenario that calls the generic function with a type of its own choosing.

const sim = @import("sim");
const lists = @import("lists.zig");

// Calls `first` with bytes, once with an empty list and once with a list that has items.
pub fn firstOfBytes(context: *sim.ScenarioContext) anyerror!void {
    const empty: []const u8 = &.{};
    const some: []const u8 = &.{ 7, 8 };

    try context.expect(@src(), lists.first(u8, empty) == null, "the first of an empty list to be null");
    try context.expect(@src(), lists.first(u8, some).? == 7, "the first of a list to be its first item");
}
