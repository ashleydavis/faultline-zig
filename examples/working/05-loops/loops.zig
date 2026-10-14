// Loops: a `while`, a `for` over a slice and a `for` over a table this file declares.

// A `while` whose body may or may not run.
pub fn countDown(from: u8) usize {
    var left = from;
    var steps: usize = 0;
    while (left > 0) {
        left -= 1;
        steps += 1;
    }
    return steps;
}

// A `for` over a slice, with a branch inside the body.
pub fn longest(words: []const []const u8) usize {
    var best: usize = 0;
    for (words) |word| {
        if (word.len > best) {
            best = word.len;
        }
    }
    return best;
}

// A table this file declares from a literal, which the loop below walks.
const known_sizes = [_]usize{ 1, 2, 4 };

// A `for` over a table the file declares.
pub fn largestKnown() usize {
    var best: usize = 0;
    for (known_sizes) |size| {
        best = @max(best, size);
    }
    return best;
}
