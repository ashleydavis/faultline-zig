// `if` over an optional and over an error union, both with their capture written out, and an
// `orelse`.

// What `sizeOf` below calls, so its `if` has a real error union to take apart.
fn measure(refuse: bool) !usize {
    if (refuse) {
        return error.Refused;
    } else {
        return 7;
    }
}

// `if (x) |value|` with the missing side written as an `else`.
pub fn lengthOr(text: ?[]const u8, fallback: usize) usize {
    if (text) |value| {
        return value.len;
    } else {
        return fallback;
    }
}

// `orelse` is a branch written as an expression: the fallback ran, or the value came back and it
// did not.
pub fn lengthOrDefault(text: ?[]const u8) usize {
    const found = text orelse blk: {
        break :blk "";
    };
    return found.len;
}

// `if (x) |value| else |e|` over an error union, with both sides written.
pub fn sizeOf(refuse: bool) usize {
    if (measure(refuse)) |value| {
        return value;
    } else |_| {
        return 0;
    }
}
