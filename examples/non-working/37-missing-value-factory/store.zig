// A type of the project's own that holds a function pointer, so Faultline cannot build one from its
// type. A value factory in store.sim.zig builds it.

// A store addressed as one function to call and a context beside it. Faultline cannot instantiate
// this type: a function pointer has no value that its type decides.
pub const Store = struct {
    // The state the store reads from, passed back to `read` on every call.
    ctx: *anyopaque,

    // Looks a key up and returns its value, or null when the key is absent.
    read: *const fn (ctx: *anyopaque, key: []const u8) ?[]const u8,
};

// Reads a key out of the store it was given. Without a value factory for `Store` Faultline never
// calls this.
pub fn valueFor(store: Store, key: []const u8) []const u8 {
    if (store.read(store.ctx, key)) |found| {
        return found;
    } else {
        return "";
    }
}
