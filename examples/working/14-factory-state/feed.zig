// A type Faultline cannot build because it holds a function pointer. A value factory on a struct in
// feed.sim.zig builds it, and the struct's state makes each feed different.

// A source of numbers, addressed as one function to call and a context beside it.
pub const Feed = struct {
    // The state the feed reads from, passed back to `next` on every call.
    ctx: *anyopaque,

    // Returns the next number, or null when the feed has run dry.
    next: *const fn (ctx: *anyopaque) ?u8,
};

// Adds up what the feed hands over until it runs dry.
pub fn total(feed: Feed) usize {
    var sum: usize = 0;
    while (feed.next(feed.ctx)) |value| {
        sum += value;
    }
    return sum;
}
