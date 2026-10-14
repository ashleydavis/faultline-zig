// A generic function: what `T` stands for is not in its signature, so Faultline cannot call it.

// The first item of a list, or null when the list is empty.
pub fn first(comptime T: type, items: []const T) ?T {
    if (items.len == 0) {
        return null;
    }
    return items[0];
}
