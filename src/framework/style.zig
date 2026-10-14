const std = @import("std");

// The colour codes and the marks a report is written with.
//
// Colour is on when the stream is a terminal and nothing has asked for it to be off: `NO_COLOR`
// (any value, the convention every other tool follows) or `--no-color` on the command line. Off,
// every helper returns an empty string and the marks become words, so the same print statements
// produce plain text a captured run can be read from.
pub const Style = struct {
    enabled: bool,

    pub fn init(enabled: bool) Style {
        return .{ .enabled = enabled };
    }

    pub fn green(self: Style) []const u8 {
        return if (self.enabled) "\x1b[32m" else "";
    }

    pub fn red(self: Style) []const u8 {
        return if (self.enabled) "\x1b[31m" else "";
    }

    pub fn yellow(self: Style) []const u8 {
        return if (self.enabled) "\x1b[33m" else "";
    }

    pub fn bold(self: Style) []const u8 {
        return if (self.enabled) "\x1b[1m" else "";
    }

    pub fn dim(self: Style) []const u8 {
        return if (self.enabled) "\x1b[2m" else "";
    }

    pub fn reset(self: Style) []const u8 {
        return if (self.enabled) "\x1b[0m" else "";
    }

    // The mark in front of one result line: what a reader scans down the left edge for.
    pub fn pass(self: Style) []const u8 {
        return if (self.enabled) "\x1b[32m✓\x1b[0m" else "ok  ";
    }

    pub fn fail(self: Style) []const u8 {
        return if (self.enabled) "\x1b[31m✗\x1b[0m" else "FAIL";
    }

    // The mark on a function that ran but did not reach everything it has. Not `fail`, because the
    // run has not failed at that line: it has found work, which the checklist at the end names.
    pub fn miss(self: Style) []const u8 {
        return if (self.enabled) "\x1b[31m✗\x1b[0m" else "MISS";
    }

    pub fn skip(self: Style) []const u8 {
        return if (self.enabled) "\x1b[33m–\x1b[0m" else "skip";
    }
};

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change to the
    // code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("style.test.zig");
}
