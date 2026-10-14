// A lookup through a table Faultline cannot build, with no value factory beside it, so Faultline
// never calls `find` itself. Only `caller.zig` calls it.

// A table addressed as one function to call and a context beside it. A function pointer has no
// value its type decides, so Faultline cannot instantiate this type.
pub const Table = struct {
    // The state the table reads from, passed back to `read` on every call.
    ctx: *anyopaque,

    // Looks a key up and returns its value, or null when the key is absent.
    read: *const fn (ctx: *anyopaque, key: []const u8) ?[]const u8,
};

// The value of a key in the table, or an empty string when the key is absent.
pub fn find(table: Table, key: []const u8) []const u8 {
    if (table.read(table.ctx, key)) |found| {
        return found;
    }
    return "";
}
