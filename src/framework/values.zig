// The test root for value selection: building values from types, boundary and seeded values,
// value factories found by return type, candidates read from conditions and the list of call
// specifications. Each file pulled in here pulls in its own tests.

test {
    _ = @import("boundary.zig");
    _ = @import("candidates.zig");
    _ = @import("call_specs.zig");
    _ = @import("locator.zig");
    _ = @import("auto.zig");
}
