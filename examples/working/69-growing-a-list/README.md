# A list the function grows

`appendQuoted` takes an `std.ArrayList(u8)` and the allocator to grow it with. Faultline builds the list empty and appends its elements with the allocator it gives the call, so the function can grow it as it would grow a caller's list.
