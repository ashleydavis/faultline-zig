// A function whose answer depends on time. Faultline calls it with a clock that stands still, jumps
// forward and jumps backward past where it started, so no scenario is written for any of them.

// A clock the code under test reads, which Faultline builds from its type.
pub const Clock = struct {
    // The time the clock reports, in milliseconds.
    now_ms: i64 = 0,

    // Reads the clock.
    pub fn now(self: *Clock) i64 {
        return self.now_ms;
    }
};

// Says whether enough time has gone by. A clock that never moves, one that jumps forward and one
// that jumps backward each take a different branch. The subtraction saturates, because Faultline
// calls it with the largest and smallest times and a plain subtraction overflows for them.
pub fn elapsed(clock: *Clock, since_ms: i64, wanted_ms: i64) bool {
    const gone = clock.now() -| since_ms;
    if (gone < 0) {
        return false;
    } else {
        if (gone >= wanted_ms) {
            return true;
        } else {
            return false;
        }
    }
}
