// The value factory for `Feed`, written on a struct so that it keeps state between calls.
//
// Each feed the factory returns holds one more number than the one before, so the first feed is
// empty and a later one is not.

const feed_mod = @import("feed.zig");

// The most numbers any feed holds, so the count wraps round instead of growing without end.
const most_numbers: usize = 3;

// Builds feeds and remembers how many it has built.
pub const Feeds = struct {
    // How many feeds this value has built so far.
    built: usize = 0,

    // How many numbers the latest feed has left to hand over.
    left: usize = 0,

    // Returns the next number of the latest feed, or null once it has none left.
    fn next(ctx: *anyopaque) ?u8 {
        const self: *Feeds = @ptrCast(@alignCast(ctx));
        if (self.left == 0) {
            return null;
        }
        self.left -= 1;
        return 7;
    }

    // Builds the next feed. It holds one more number than the one before, up to the most and then
    // starting again from none. Faultline finds it by its return type.
    pub fn feed(self: *Feeds) feed_mod.Feed {
        self.left = self.built % (most_numbers + 1);
        self.built += 1;
        return .{ .ctx = self, .next = next };
    }
};
