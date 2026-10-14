// The simulated allocator: a `std.mem.Allocator` that wraps a backing allocator and asks the
// injector once for every allocation, resize and remap, so a function's memory use is a place where
// it can fail.
//
// The four failures in `docs/FAILURES.md`:
// - Allocation fails: that one `alloc` returns null (`error.OutOfMemory` to the caller). The call
//   after it works normally.
// - Resize fails: that one `resize` returns false, so the caller must allocate and copy.
// - Remap fails: that one `remap` returns null, so the caller must allocate and copy.
// - Free of a failed allocation: the allocation fails and the allocator stays in that state, which
//   is memory that is used up. Every later `alloc` returns null, a `resize` or `remap` that grows
//   returns false or null, but `free` keeps working and hands memory back to the backing
//   allocator. That is what a function's error path runs against: cleanup (`errdefer`, `defer`,
//   `deinit`) must free what was allocated before the failure without needing any more memory.
//   Every later call still asks the injector, so the places it reaches are recorded.

const std = @import("std");
const injector_mod = @import("injector.zig");
const state = @import("effect_state.zig");

const alloc_kinds = state.kindsFor(.allocator, &.{ "allocation_fails", "free_of_a_failed_allocation" });
const resize_kinds = state.kindsFor(.allocator, &.{"resize_fails"});
const remap_kinds = state.kindsFor(.allocator, &.{"remap_fails"});

pub const SimulatedAllocator = struct {
    // Where the memory comes from.
    backing: std.mem.Allocator,

    // Where every allocation, resize and remap is asked about.
    injector: *injector_mod.Injector,

    // Whether an allocation has failed with "free of a failed allocation", so no more memory is
    // given out until the function under test ends.
    is_exhausted: bool = false,

    // Wraps `backing`, asking `injector` about each call that can fail.
    pub fn init(backing: std.mem.Allocator, injector: *injector_mod.Injector) SimulatedAllocator {
        return .{ .backing = backing, .injector = injector };
    }

    // The allocator the code under test is given. It points at this struct, so the struct has to
    // stay where it is while the allocator is in use.
    pub fn allocator(self: *SimulatedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *SimulatedAllocator = @ptrCast(@alignCast(context));
        if (self.injector.check(.allocator, &alloc_kinds)) |kind| {
            if (state.isKind(.allocator, "free_of_a_failed_allocation", kind)) {
                self.is_exhausted = true;
            }
            return null;
        }
        if (self.is_exhausted) {
            return null;
        }
        return self.backing.rawAlloc(length, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
        const self: *SimulatedAllocator = @ptrCast(@alignCast(context));
        if (self.injector.check(.allocator, &resize_kinds) != null) {
            return false;
        }
        if (self.is_exhausted and new_length > memory.len) {
            return false;
        }
        return self.backing.rawResize(memory, alignment, new_length, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        const self: *SimulatedAllocator = @ptrCast(@alignCast(context));
        if (self.injector.check(.allocator, &remap_kinds) != null) {
            return null;
        }
        if (self.is_exhausted and new_length > memory.len) {
            return null;
        }
        return self.backing.rawRemap(memory, alignment, new_length, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *SimulatedAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

test {
    _ = @import("effect_allocator.test.zig");
}
