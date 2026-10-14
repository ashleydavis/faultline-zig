// One scenario, for the code path that nothing else reaches.

const sim = @import("sim");
const lock_mod = @import("lock.zig");

// Takes the lock twice, so the second take meets a lock that is held.
pub fn runTakenTwiceScenario(context: *sim.ScenarioContext) anyerror!void {
    var lock = lock_mod.Lock{};
    const first = lock.take();
    const second = lock.take();

    try context.expect(@src(), first, "the first take to get the lock");
    try context.expect(@src(), !second, "the second take to be refused while the lock is held");

    lock.release();
}
