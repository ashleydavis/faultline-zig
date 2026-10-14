// A function with an input it never returns for.

// Steps up by two until the count reaches one. An even start never gets there, because it only
// ever lands on even numbers, and the count wraps round and starts again.
pub fn stepsToOne(start: u8) u8 {
    var count: u8 = start;
    var steps: u8 = 0;
    while (count != 1) {
        count +%= 2;
        steps +%= 1;
    }
    return steps;
}
