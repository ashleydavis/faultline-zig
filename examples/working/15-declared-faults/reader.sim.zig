// The value factories for `Source`: one for a working source and one for each way a source breaks.
//
// Faultline calls `firstByte` with every one of them, so the code that handles each fault runs.

const reader_mod = @import("reader.zig");

// Stands in for the state of a source. These sources have none, so the context is never read.
var no_state: u8 = 0;

// A read that works.
fn readWorking(ctx: *anyopaque) anyerror!u8 {
    _ = ctx;
    return 42;
}

// A read of a source with nothing in it.
fn readEmpty(ctx: *anyopaque) anyerror!u8 {
    _ = ctx;
    return error.Empty;
}

// A read of a source that is broken.
fn readBroken(ctx: *anyopaque) anyerror!u8 {
    _ = ctx;
    return error.Broken;
}

// The working source.
pub fn workingSource() reader_mod.Source {
    return .{ .ctx = &no_state, .read = readWorking };
}

// A source with nothing in it.
pub fn emptySource() reader_mod.Source {
    return .{ .ctx = &no_state, .read = readEmpty };
}

// A source that is broken.
pub fn brokenSource() reader_mod.Source {
    return .{ .ctx = &no_state, .read = readBroken };
}
