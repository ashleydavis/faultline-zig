// Environment variables. In Zig 0.16 the environment is not reached through `std.Io`: a program
// receives a `std.process.Environ` in its start-up arguments and reads variables from it (or from
// a `std.process.Environ.Map` it made from it), so there is no entry in the `Io` vtable to
// intercept. Code under test can only be given this simulated environment, by a parameter of its
// own or a value factory and a `std.process.Environ` it is handed is read for real.
//
// The simulated environment is a map that starts empty. Reading a variable asks the injector once
// and can fail two ways: the variable is reported as not set even when it is and the variable is
// reported as set to an empty value even when it is not set or has a value.

const std = @import("std");
const state = @import("effect_state.zig");

const environment_kinds = state.kindsFor(.environment, &.{ "variable_not_set", "variable_set_to_an_empty_value" });

// What reading a variable can return.
pub const GetError = error{EnvironmentVariableMissing};

// An environment that holds only what has been put into it.
pub const Environment = struct {
    // The variables, in the standard library's own map type.
    map: std.process.Environ.Map,

    // Builds an empty environment.
    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{ .map = std.process.Environ.Map.init(allocator) };
    }

    // Frees the variables.
    pub fn deinit(self: *Environment) void {
        self.map.deinit();
    }

    // Sets a variable.
    pub fn put(self: *Environment, key: []const u8, value: []const u8) std.mem.Allocator.Error!void {
        try self.map.put(key, value);
    }

    // Reads a variable, asking the injector once. The returned slice belongs to the environment.
    pub fn get(self: *const Environment, key: []const u8) GetError![]const u8 {
        if (state.ask(.environment, &environment_kinds)) |kind| {
            if (state.isKind(.environment, "variable_not_set", kind)) {
                return error.EnvironmentVariableMissing;
            }
            return "";
        }
        return self.map.get(key) orelse error.EnvironmentVariableMissing;
    }

    // Reads a variable and copies it, the way `std.process.Environ.getAlloc` does.
    pub fn getAlloc(self: *const Environment, allocator: std.mem.Allocator, key: []const u8) (GetError || std.mem.Allocator.Error)![]u8 {
        return allocator.dupe(u8, try self.get(key));
    }
};

test {
    _ = @import("effect_environment.test.zig");
}
