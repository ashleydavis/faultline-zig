// A code path that no single call reaches, which a scenario in lock.sim.zig exercises.

// A lock that refuses a second holder.
pub const Lock = struct {
    // True while someone holds the lock.
    held: bool = false,

    // Takes the lock. Taking it while it is held fails, and that needs two calls in order, which no
    // single call can produce.
    pub fn take(self: *Lock) bool {
        if (self.held) {
            return false;
        }
        self.held = true;
        return true;
    }

    // Lets go of the lock.
    pub fn release(self: *Lock) void {
        self.held = false;
    }
};
