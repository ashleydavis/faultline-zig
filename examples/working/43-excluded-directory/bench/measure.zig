// A benchmark. It exercises the code rather than being code Faultline is asked about, and it has a
// branch no call of Faultline's would reach. `build.zig` names this directory in `.exclude`.

const sorting = @import("../sorting.zig");

// Counts how many of the rounds find the numbers in order.
pub fn timeIt(rounds: usize) usize {
    var reached: usize = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        if (sorting.inOrder(&.{ 1, 2, 3 })) {
            reached += 1;
        }
    }
    return reached;
}
