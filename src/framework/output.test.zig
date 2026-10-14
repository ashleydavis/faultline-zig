// Tests for where a run's report goes, and for the progress line that is wiped before it.

const std = @import("std");
const output = @import("output.zig");

// Captures everything printed while it is set, so a test can read what a caller wrote.
const Capture = struct {
    buffer: [256]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn start(self: *Capture) void {
        self.writer = .fixed(&self.buffer);
        output.writer = &self.writer;
        output.forgetProgress();
    }

    fn stop(self: *Capture) []const u8 {
        output.writer = null;
        return self.writer.buffered();
    }
};

test "an ordinary print is written as it is given" {
    var capture: Capture = .{};
    capture.start();
    output.print("Exercised {d} calls.\n", .{7});
    try std.testing.expectEqualStrings("Exercised 7 calls.\n", capture.stop());
}

test "a print after a progress line wipes it, so the report never lands on the end of it" {
    var capture: Capture = .{};
    capture.start();
    output.printProgress("  Exercised 7 calls.", .{});
    output.print("Passed.\n", .{});
    try std.testing.expectEqualStrings("  Exercised 7 calls.\r\x1b[2KPassed.\n", capture.stop());
}

test "one progress line wipes the one before it, so they never pile up" {
    var capture: Capture = .{};
    capture.start();
    output.printProgress("  Exercised 7 calls.", .{});
    output.printProgress("  Exercised 9 calls.", .{});
    try std.testing.expectEqualStrings("  Exercised 7 calls.\r\x1b[2K  Exercised 9 calls.", capture.stop());
}

test "nothing is wiped when no progress line was written, so a plain run emits no escape codes" {
    var capture: Capture = .{};
    capture.start();
    output.print("One.\n", .{});
    output.print("Two.\n", .{});
    try std.testing.expectEqualStrings("One.\nTwo.\n", capture.stop());
}
