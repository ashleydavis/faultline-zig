// Where a run's own report goes.
//
// One place, so it can be pointed somewhere other than the terminal. It goes to stderr for a real
// run, and nowhere in a test build: the framework's own tests exercise failing runs on purpose to
// prove the reporting works, and each one prints a page of report. Left alone, `zig build test`
// buries its result under several of those and reads like a catastrophe when every test passed.
//
// A test that wants to read what was printed sets `writer` to one of its own and clears it after.

const std = @import("std");

// Whether this is a test binary. A run's report is for whoever ran it, and in a test build nobody
// asked for it.
const in_test = @import("builtin").is_test;

// Set to capture what a run prints. Null leaves it going wherever it goes by default.
pub var writer: ?*std.Io.Writer = null;

// Whether a progress line is sitting on the terminal with no newline on the end of it. The next
// thing written wipes it, so the run's own report is never printed onto the end of a line that was
// only ever meant to be watched.
var progress_showing = false;

// The one place a run's report is written. Every line the framework prints goes through here.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    wipeProgress();
    write(fmt, args);
}

// Writes a line the next print wipes, for saying how far a run has got. Written without a newline
// and wiped rather than scrolled, so a run that takes minutes says where it is on one line instead
// of burying its report under a hundred of them.
pub fn printProgress(comptime fmt: []const u8, args: anytype) void {
    wipeProgress();
    write(fmt, args);
    progress_showing = true;
}

// Takes the cursor back to the start of the line and clears it. Sent only when there is a progress
// line to wipe, so nothing that prints a report ever emits an escape sequence.
fn wipeProgress() void {
    if (!progress_showing) {
        return;
    }
    progress_showing = false;
    write("\r\x1b[2K", .{});
}

// Forgets a progress line without wiping it, for a caller that has just pointed the output
// somewhere else: what was written is on the old stream and stays there, and the new one starts on
// a line of its own.
pub fn forgetProgress() void {
    progress_showing = false;
}

fn write(comptime fmt: []const u8, args: anytype) void {
    if (writer) |captured| {
        // A report that will not fit is not worth failing a run over: what is being reported is
        // already the problem.
        captured.print(fmt, args) catch {};
        return;
    }
    if (in_test) {
        return;
    }
    std.debug.print(fmt, args);
}

test {
    // The tests live in their own file so a change to them is never mistaken for a change to the
    // code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("output.test.zig");
}
