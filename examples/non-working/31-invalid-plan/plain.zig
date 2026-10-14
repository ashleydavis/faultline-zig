// Ordinary code. This example is about the replay token and not about the code.

// Twice the value, widened so it cannot overflow.
pub fn twice(value: u8) u16 {
    return @as(u16, value) * 2;
}
