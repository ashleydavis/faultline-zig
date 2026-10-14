// A private function and a function declared inside another. Each is called and reported on its own.

// A private function, reached only through the public one below it. It gets a line in the report
// exactly as a public one does.
fn trimmedLength(text: []const u8) usize {
    if (text.len == 0) {
        return 0;
    } else {
        return text.len;
    }
}

// A function declared inside another, which gets a line of its own rather than counting towards
// the outer one.
pub fn describe(text: []const u8) usize {
    const length = trimmedLength(text);

    const Inner = struct {
        fn doubled(value: usize) usize {
            if (value > 10) {
                return 20;
            } else {
                return value * 2;
            }
        }
    };

    return Inner.doubled(length);
}
