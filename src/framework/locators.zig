// Finds value factories across a list of sim file namespaces, asking each in turn. Faultline gives
// the functions of a source file a list holding the sim file beside it and every `global.sim.zig`,
// so a factory is used only for the file it sits beside unless it is in a `global.sim.zig`.

const std = @import("std");
const locator = @import("locator.zig");

// A locator that asks each namespace's own locator in turn, in the order the namespaces are given.
// It has the same interface as `locator.Locator`: `init`, `reset`, `canMake`, `count`, `make` and
// `makeInto`.
pub fn Combined(comptime namespaces: []const type) type {
    return struct {
        const Self = @This();

        // The type of each namespace's locator.
        const Parts = blk: {
            var types: [namespaces.len]type = undefined;
            for (namespaces, 0..) |namespace, index| {
                types[index] = locator.Locator(namespace);
            }
            break :blk @Tuple(&types);
        };

        // One locator per namespace, each holding its own receivers.
        parts: Parts,

        // Starts a series of calls: every receiver of every part is fresh.
        pub fn init() Self {
            var parts: Parts = undefined;
            inline for (namespaces, 0..) |namespace, index| {
                parts[index] = locator.Locator(namespace).init();
            }
            return .{ .parts = parts };
        }

        // Starts the next series of calls.
        pub fn reset(self: *Self) void {
            self.* = init();
        }

        // Whether any namespace holds a factory for `T`.
        pub fn canMake(comptime T: type) bool {
            inline for (namespaces) |namespace| {
                if (locator.Locator(namespace).canMake(T)) {
                    return true;
                }
            }
            return false;
        }

        // How many factories for `T` there are across every namespace.
        pub fn count(comptime T: type) usize {
            var total: usize = 0;
            inline for (namespaces) |namespace| {
                total += locator.Locator(namespace).count(T);
            }
            return total;
        }

        // Calls the factory at `index`, counting through the namespaces in order.
        pub fn make(self: *Self, comptime T: type, index: usize, builder: anytype) anyerror!T {
            var before: usize = 0;
            inline for (namespaces, 0..) |namespace, part| {
                const here = locator.Locator(namespace).count(T);
                if (index < before + here) {
                    return self.parts[part].make(T, index - before, builder);
                }
                before += here;
            }
            return error.NoSuchValueFactory;
        }

        // Calls the factory at `index` and writes its value into `slot`, counting through the
        // namespaces in order. The only way to call a factory for an error set.
        pub fn makeInto(self: *Self, comptime T: type, index: usize, builder: anytype, slot: *T) anyerror!void {
            var before: usize = 0;
            inline for (namespaces, 0..) |namespace, part| {
                const here = locator.Locator(namespace).count(T);
                if (index < before + here) {
                    return self.parts[part].makeInto(T, index - before, builder, slot);
                }
                before += here;
            }
            return error.NoSuchValueFactory;
        }
    };
}

test {
    _ = @import("locators.test.zig");
}
