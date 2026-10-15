// The sentences a run prints about what went wrong in a call: a crash, a call that never returned
// and an expectation that was false, each with the command that repeats the call.

const std = @import("std");
const output_mod = @import("output.zig");
const style_mod = @import("style.zig");
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
    printReplay(failure.token);
}

// Prints how long the run took, as the line the report ends with before the path to the report
// file.
pub fn printTimeTaken(nanos: u64) void {
    var buffer: [64]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    writeTimeTaken(&line, nanos) catch {};
    output_mod.print("{s}", .{line.buffered()});
}

// Writes the line `printTimeTaken` prints, with milliseconds under a minute.
pub fn writeTimeTaken(writer: *std.Io.Writer, nanos: u64) std.Io.Writer.Error!void {
    var buffer: [48]u8 = undefined;
    try writer.print("  Took {s}.\n", .{worker.runTimeText(&buffer, nanos)});
}

// Prints how many calls failed, kind by kind, and in how many functions and scenarios, as the
// summary the report ends with beside the coverage line.
pub fn printFailureCounts(failures: []const worker.Failure, style: style_mod.Style) void {
    var buffer: [512]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    writeFailureCounts(&line, failures) catch {};
    const colour = if (failures.len == 0) style.green() else style.red();
    output_mod.print("\n{s}{s}{s}{s}", .{ colour, style.bold(), line.buffered(), style.reset() });
}

// Writes the lines `printFailureCounts` prints: one per kind of failure found, or one saying none
// was found.
pub fn writeFailureCounts(writer: *std.Io.Writer, failures: []const worker.Failure) std.Io.Writer.Error!void {
    if (failures.len == 0) {
        return writer.writeAll("  No call crashed, hung or found an expectation false.\n");
    }
    const kinds = [_]struct { kind: worker.FailureKind, one: []const u8, many: []const u8 }{
        .{ .kind = .crash, .one = "call crashed", .many = "calls crashed" },
        .{ .kind = .hang, .one = "call did not return in time", .many = "calls did not return in time" },
        .{ .kind = .expectation, .one = "expectation was false", .many = "expectations were false" },
    };
    for (kinds) |kind| {
        var count: usize = 0;
        var functions: usize = 0;
        var scenarios: usize = 0;
        for (failures, 0..) |failure, position| {
            if (failure.kind != kind.kind) {
                continue;
            }
            count += 1;
            if (!isSeenBefore(failures[0..position], failure)) {
                if (failure.is_scenario) {
                    scenarios += 1;
                } else {
                    functions += 1;
                }
            }
        }
        if (count == 0) {
            continue;
        }
        try writer.print("  {d} {s}, in ", .{ count, if (count == 1) kind.one else kind.many });
        if (functions != 0) {
            try writer.print("{d} function{s}", .{ functions, if (functions == 1) "" else "s" });
        }
        if (functions != 0 and scenarios != 0) {
            try writer.writeAll(" and ");
        }
        if (scenarios != 0) {
            try writer.print("{d} scenario{s}", .{ scenarios, if (scenarios == 1) "" else "s" });
        }
        try writer.writeAll(".\n");
    }
}

// Whether a failure of the same kind in the same function or scenario is among `earlier`.
fn isSeenBefore(earlier: []const worker.Failure, failure: worker.Failure) bool {
    for (earlier) |other| {
        if (other.kind == failure.kind and other.is_scenario == failure.is_scenario and other.index == failure.index) {
            return true;
        }
    }
    return false;
}

// Prints the command that repeats the call a replay token names.
pub fn printReplay(token: []const u8) void {
    output_mod.print("Reproduce it with: zig build flt -Dreplay=\"{s}\"\n", .{token});
}

test {
    _ = @import("report.test.zig");
}
