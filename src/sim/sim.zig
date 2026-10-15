// The module a project's `.sim.zig` files import, and the only one they need.
//
// It exports the two contexts a function in a sim file receives and the control a scenario uses to
// ask for a failure. Everything else Faultline is made of stays inside Faultline.

const std = @import("std");

// Where an expectation was written and what it said, kept so Faultline can print it when the
// expectation is false.
pub const Expectation = struct {
    // The source file the expectation is in, as `@src()` reports it.
    file: []const u8,

    // The line the expectation is on.
    line: u32,

    // What the author wrote the expectation to say.
    text: []const u8,
};

// What a scenario can ask Faultline to do about failures. A scenario that asks for none gets only
// the failures Faultline injects on its own.
pub const Faults = struct {
    // How many failures have been injected into the calls made through this control so far.
    injected: usize = 0,
};

// The one parameter of a scenario: a function in a sim file that calls the code under test with
// values its author chose.
pub const ScenarioContext = struct {
    // The failures Faultline can inject, so a scenario can ask for one at a chosen place.
    faults: *Faults,

    // A `std.Io` whose filesystem and network are simulated in memory.
    io: std.Io,

    // An allocator Faultline can make fail.
    allocator: std.mem.Allocator,

    // A writer Faultline can make fail at any write, the one it gives a call that takes a writer.
    writer: *std.Io.Writer,

    // The expectation that was false, when one was. Faultline reads it after the scenario returns.
    failed: ?Expectation = null,

    // Says what the scenario expects to be true. When `condition` is false the expectation is
    // recorded and `error.ExpectationFailed` is returned, so the scenario stops at that line.
    pub fn expect(self: *ScenarioContext, source: std.builtin.SourceLocation, condition: bool, text: []const u8) error{ExpectationFailed}!void {
        if (condition) {
            return;
        }
        self.failed = .{ .file = source.file, .line = source.line, .text = text };
        return error.ExpectationFailed;
    }
};

// The one parameter of an expectation function: a function in a sim file that checks expectations
// after a call and after a scenario.
pub const ExpectationContext = struct {
    // The same simulated `std.Io` the call used, so a check can read the simulated filesystem.
    io: std.Io,

    // An allocator for the check's own use. It never fails.
    allocator: std.mem.Allocator,

    // The expectation that was false, when one was. Faultline reads it after the function returns.
    failed: ?Expectation = null,

    // Says what the function expects to be true. When `condition` is false the expectation is
    // recorded and `error.ExpectationFailed` is returned, so the function stops at that line.
    pub fn expect(self: *ExpectationContext, source: std.builtin.SourceLocation, condition: bool, text: []const u8) error{ExpectationFailed}!void {
        if (condition) {
            return;
        }
        self.failed = .{ .file = source.file, .line = source.line, .text = text };
        return error.ExpectationFailed;
    }
};

test {
    _ = @import("sim.test.zig");
}
