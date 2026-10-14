// `and`, `or` and `try` are not code paths, so a function made of them is fully exercised by being
// called.

// What `halfOrNothing` calls, so the `try` below has something that can fail.
fn checkedHalf(value: u8) !u8 {
    if (value % 2 != 0) {
        return error.Odd;
    }
    return value / 2;
}

// `and` is not a code path: the function is exercised when it is called.
pub fn inRange(value: u8, low: u8, high: u8) bool {
    return value >= low and value <= high;
}

// `or` is the same.
pub fn atEdge(value: u8, low: u8, high: u8) bool {
    return value == low or value == high;
}

// `try` is not a code path either. The `if` inside `checkedHalf` is, and Faultline reaches both of
// its sides.
pub fn halfOrNothing(value: u8) !u8 {
    const half = try checkedHalf(value);
    return half;
}
