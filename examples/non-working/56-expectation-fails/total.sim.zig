// A scenario with an expectation that is false, which makes the run fail.

const sim = @import("sim");
const total = @import("total.zig");

// Adds five twice and expects ten to be twice that, which it is not.
pub fn addingFiveTwiceIsTwenty(context: *sim.ScenarioContext) anyerror!void {
    var running: total.Total = .{};
    running.add(5);
    running.add(5);

    try context.expect(@src(), running.amount == 20, "the total to be twenty after adding five twice");
}
