// A function that words each error it is given. Faultline hands an `anyerror` parameter one error
// of its own, which reaches only the `else` arm, so the value factories beside this file give the
// others.

const std = @import("std");

// What a person reads for an error, with its name after the words.
pub fn describe(buffer: []u8, err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => std.fmt.bufPrint(buffer, "no such file ({s})", .{@errorName(err)}) catch "",
        error.AccessDenied => std.fmt.bufPrint(buffer, "permission denied ({s})", .{@errorName(err)}) catch "",
        else => @errorName(err),
    };
}
