// A scenario that states what it expects of the code it called, the way a unit test does.
//
// The sentence after each condition is what the report prints when the condition is false. Every
// expectation here holds, so the report prints none of them.

const sim = @import("sim");
const total_mod = @import("total.zig");

// Adds an amount and then nothing, and expects the total after each.
pub fn runAddingUpScenario(context: *sim.ScenarioContext) anyerror!void {
    var total = total_mod.Total{};

    total.add(2);
    try context.expect(@src(), total.amount == 2, "the total to hold the amount it was given");

    total.add(0);
    try context.expect(@src(), total.amount == 2, "an amount of nothing to leave the total alone");
}
