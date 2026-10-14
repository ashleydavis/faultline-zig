// The sentences a run prints about what went wrong in a call: a crash, a call that never returned
// and an expectation that was false, each with the command that repeats the call.

const std = @import("std");
const output_mod = @import("output.zig");
const worker = @import("worker.zig");

// Prints one failure. `subject` is what failed: the name of the function or the scenario.
pub fn printFailure(failure: worker.Failure, subject: []const u8) void {
    switch (failure.kind) {
        .crash => {
            if (failure.complaint.len != 0) {
                output_mod.print("The call to {s} crashed: {s}\n", .{ subject, failure.complaint });
            } else {
                output_mod.print("The call to {s} crashed.\n", .{subject});
            }
        },
        .hang => output_mod.print("The call to {s} did not return in time.\n", .{subject}),
        .expectation => {
            if (failure.is_scenario) {
                output_mod.print("The scenario {s} expected {s}, at {s}:{d}.\n", .{ subject, failure.text, failure.file, failure.line });
            } else {
                output_mod.print(
                    "The expectation function {s} expected {s}, at {s}:{d}, after the call to {s}.\n",
                    .{ failure.expectation_function, failure.text, failure.file, failure.line, subject },
                );
            }
        },
    }
    output_mod.print("Reproduce it with: zig build flt -Dreplay=\"{s}\"\n", .{failure.token});
}

test {
    _ = @import("report.test.zig");
}
