// The one file that calls `lookup.find`, with the tables its sim file builds.

const lookup = @import("lookup.zig");

// The value of `name` in the table, read through `lookup.find`.
pub fn nameIn(table: lookup.Table) []const u8 {
    return lookup.find(table, "name");
}
