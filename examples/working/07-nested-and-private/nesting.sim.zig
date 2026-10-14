// A scenario for the branch that needs a long text. The nested function only sees the text's length,
// so no value Faultline reads from a condition in it can reach the branch for a long length.

const sim = @import("sim");
const nesting = @import("nesting.zig");

// Describes a text longer than the nested function's limit, which caps the answer.
pub fn runLongTextScenario(context: *sim.ScenarioContext) anyerror!void {
    const described = nesting.describe("a text of more than ten characters");

    try context.expect(@src(), described == 20, "a long text to be capped at twenty");
}
