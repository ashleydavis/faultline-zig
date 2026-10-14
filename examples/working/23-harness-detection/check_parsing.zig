// A helper that imports the framework, which makes it harness code: it exercises the project and
// is not measured by it. Faultline skips it however many functions and branches it has. Nothing
// lists which files are harness code, so nothing goes stale when one is added.

const sim = @import("sim");
const parsing = @import("parsing.zig");

// Checks the digit count of a fixed text. It has branches that no call exercises, and none of them
// is on the report.
pub fn checkDigits(context: *sim.ScenarioContext, text: []const u8) anyerror!void {
    if (text.len == 0) {
        return;
    }
    try context.expect(@src(), parsing.digitsIn(text) <= text.len, "no more digits than characters");
}
