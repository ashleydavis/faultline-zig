// A second file whose function takes a `Store`. The value factories for `Store` sit in
// store.sim.zig, which Faultline uses only for store.zig, so this file needs its own.

const store_mod = @import("store.zig");

// Reads the first of two keys the store holds, or the second when the first is absent.
pub fn firstOf(store: store_mod.Store) []const u8 {
    if (store.read(store.ctx, "first")) |found| {
        return found;
    }
    return store_mod.valueFor(store, "second");
}
