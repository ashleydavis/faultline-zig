// A type Faultline cannot build because it holds a function pointer. reader.sim.zig has one value
// factory per fault: a working source and two broken ones.

// Something to read a byte from, addressed as one function to call and a context beside it.
pub const Source = struct {
    // The state the source reads from, passed back to `read` on every call.
    ctx: *anyopaque,

    // Returns the byte, or an error when the read goes wrong.
    read: *const fn (ctx: *anyopaque) anyerror!u8,
};

// Reads one byte and returns it. A source that is empty or broken gives zero.
pub fn firstByte(source: Source) u8 {
    const byte = source.read(source.ctx) catch |err| {
        switch (err) {
            error.Empty => {
                return 0;
            },
            else => {
                return 0;
            },
        }
    };
    return byte;
}
