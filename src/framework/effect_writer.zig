// The simulated writer: a `std.Io.Writer` over a fixed buffer that asks the injector once for every
// write the code under test makes to it.
//
// Without a failure it accepts every byte until the buffer is full and a write that does not fit
// returns `error.WriteFailed`, as a real full buffer does. The three failures in `docs/FAILURES.md`:
// - Writer has no room: that write returns `error.WriteFailed`.
// - Writer fills part way through: that write and the writes after it succeed for a fixed number of
//   bytes (`fill_allowance`) and then return `error.WriteFailed`.
// - Short write: that write accepts fewer bytes than were offered, so a caller that does not loop
//   loses data and one that does is exercised.

const std = @import("std");
const injector_mod = @import("injector.zig");
const state = @import("effect_state.zig");

// How many more bytes a writer takes after "fills part way through" before it returns
// `error.WriteFailed`. Four is more than zero, so something is written and fewer than most
// messages, so most writes are cut off.
pub const fill_allowance: usize = 4;

const writer_kinds = state.kindsFor(.writer, &.{ "writer_has_no_room", "writer_fills_part_way_through", "short_write" });

pub const SimulatedWriter = struct {
    // Where accepted bytes go.
    contents: []u8,

    // How many bytes of `contents` have been accepted.
    length: usize = 0,

    // Where every write is asked about.
    injector: *injector_mod.Injector,

    // The most bytes this writer takes in total once it has been told it is filling up. Null until
    // "fills part way through" happens.
    limit: ?usize = null,

    // The writer the code under test uses. It has no buffer of its own, so every write reaches the
    // injector.
    interface: std.Io.Writer,

    // Builds a writer over `contents`.
    pub fn init(contents: []u8, injector: *injector_mod.Injector) SimulatedWriter {
        return .{
            .contents = contents,
            .injector = injector,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    // The bytes accepted so far.
    pub fn written(self: *const SimulatedWriter) []const u8 {
        return self.contents[0..self.length];
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SimulatedWriter = @alignCast(@fieldParentPtr("interface", writer));
        const offered = offeredLength(data, splat);
        var allowed = offered;
        if (self.injector.check(.writer, &writer_kinds)) |kind| {
            if (state.isKind(.writer, "writer_has_no_room", kind)) {
                return error.WriteFailed;
            }
            if (state.isKind(.writer, "writer_fills_part_way_through", kind)) {
                self.limit = self.length + fill_allowance;
            } else if (offered > 1) {
                // Fewer than offered but at least one, so a caller that loops makes progress.
                allowed = @max(1, offered / 2);
            }
        }
        if (offered == 0) {
            return 0;
        }
        if (self.limit) |limit| {
            allowed = @min(allowed, limit -| self.length);
        }
        allowed = @min(allowed, self.contents.len - self.length);
        if (allowed == 0) {
            return error.WriteFailed;
        }
        copyPrefix(self.contents[self.length..], data, splat, allowed);
        self.length += allowed;
        return allowed;
    }

    // How many bytes a call to `drain` offers: every slice once and the last one `splat` times.
    fn offeredLength(data: []const []const u8, splat: usize) usize {
        if (data.len == 0) {
            return 0;
        }
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            total += bytes.len;
        }
        return total + data[data.len - 1].len * splat;
    }

    // Copies the first `count` bytes of what `drain` offers into `destination`.
    fn copyPrefix(destination: []u8, data: []const []const u8, splat: usize, count: usize) void {
        var copied: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            const take = @min(bytes.len, count - copied);
            @memcpy(destination[copied..][0..take], bytes[0..take]);
            copied += take;
        }
        const pattern = data[data.len - 1];
        var repeat: usize = 0;
        while (copied < count and repeat < splat) : (repeat += 1) {
            const take = @min(pattern.len, count - copied);
            @memcpy(destination[copied..][0..take], pattern[0..take]);
            copied += take;
        }
    }
};

test {
    _ = @import("effect_writer.test.zig");
}
