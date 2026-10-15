// Running another program. Nothing is ever started: a spawn returns a child that has not run and
// waiting for it reports that it exited with code 0 and wrote nothing. Each failure in the table is
// returned from the call that can return it.
//
// Three calls can fail, each asks the injector once:
// - starting the program (`processSpawn` and `processSpawnPath`): not found, access denied, not an
//   executable, too many open files, out of memory.
// - waiting for it (`childWait`): exits with a non-zero code, killed by a signal.
// - collecting its output and waiting within a time limit: output past the limit, timed out. The
//   child's pipes are empty files of the simulated filesystem, so `std.process.run` reads them
//   to their end at once. `run` in this file is the same call made without pipes and is what asks
//   about the output.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("effect_state.zig");
const filesystem = @import("filesystem.zig");

// The process identifier the next spawned child gets. Starts at `state.first_handle` so it is never
// the identifier of a real process and counts up so two children differ.
var next_id: i32 = state.first_handle;

// The signal a "killed by a signal" failure reports: kill, the one signal that cannot be caught
// or ignored, so no handler in the code under test could have prevented it.
const killing_signal: std.posix.SIG = .KILL;

// The exit code a "non-zero code" failure reports. One is the code a program uses for a general
// failure, which is the most common non-zero code.
const failure_exit_code: u8 = 1;

const spawn_kinds = state.kindsFor(.spawn, &.{ "program_not_found", "access_denied", "not_an_executable", "too_many_open_files", "out_of_memory" });
const wait_kinds = state.kindsFor(.spawn, &.{ "exits_with_a_non_zero_code", "killed_by_a_signal" });
const limited_output_kinds = state.kindsFor(.spawn, &.{ "output_past_the_limit", "timed_out" });
const unlimited_output_kinds = state.kindsFor(.spawn, &.{"timed_out"});

// Forgets every child and starts the identifiers again.
pub fn reset() void {
    next_id = state.first_handle;
}

// Writes the process entries of the `Io` vtable into `room`.
pub fn override(room: *std.Io.VTable) void {
    room.processSpawn = spawn;
    room.processSpawnPath = spawnPath;
    room.childWait = wait;
    room.childKill = kill;
}

// Whether `id` is the identifier of a child this module started.
fn isMine(id: ?std.process.Child.Id) bool {
    const value = id orelse {
        return false;
    };
    return value >= state.first_handle;
}

fn spawn(_: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    if (state.ask(.spawn, &spawn_kinds)) |kind| {
        if (state.isKind(.spawn, "program_not_found", kind)) {
            return error.FileNotFound;
        }
        if (state.isKind(.spawn, "access_denied", kind)) {
            return error.AccessDenied;
        }
        if (state.isKind(.spawn, "not_an_executable", kind)) {
            return error.InvalidExe;
        }
        if (state.isKind(.spawn, "too_many_open_files", kind)) {
            return error.ProcessFdQuotaExceeded;
        }
        return error.OutOfMemory;
    }
    next_id += 1;
    // A stream asked for as `.pipe` is an empty pipe of the simulated filesystem, so the code that
    // reads the child's output, `std.process.run` among it, reads its end at once, as it would read
    // a child that wrote nothing.
    return .{
        .id = next_id,
        .thread_handle = if (builtin.os.tag == .windows) undefined else {},
        .stdin = null,
        .stdout = if (options.stdout == .pipe) try pipeFor() else null,
        .stderr = if (options.stderr == .pipe) try pipeFor() else null,
        .request_resource_usage_statistics = options.request_resource_usage_statistics,
    };
}

// An empty pipe for a child's stream, or the error a spawn returns when there is no memory for it.
fn pipeFor() std.process.SpawnError!std.Io.File {
    return filesystem.openEmptyPipe() catch error.OutOfMemory;
}

fn spawnPath(userdata: ?*anyopaque, _: std.Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    return spawn(userdata, options);
}

fn wait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    if (!isMine(child.id)) {
        return state.underneath.vtable.childWait(userdata, child);
    }
    child.id = null;
    closeStreams(child);
    if (state.ask(.spawn, &wait_kinds)) |kind| {
        if (state.isKind(.spawn, "exits_with_a_non_zero_code", kind)) {
            return .{ .exited = failure_exit_code };
        }
        return .{ .signal = killing_signal };
    }
    return .{ .exited = 0 };
}

fn kill(userdata: ?*anyopaque, child: *std.process.Child) void {
    if (!isMine(child.id)) {
        return state.underneath.vtable.childKill(userdata, child);
    }
    child.id = null;
    closeStreams(child);
}

// Closes a finished child's pipes and forgets them, as the real wait and kill do, because the code
// that started the child expects them gone once it has ended.
fn closeStreams(child: *std.process.Child) void {
    inline for (.{ &child.stdin, &child.stdout, &child.stderr }) |stream| {
        if (stream.*) |file| {
            filesystem.closeFile(file);
            stream.* = null;
        }
    }
}

// The same call as `std.process.run` for the simulated world: starts the program, collects its
// output, waits for it and returns what it did. The output is always empty and the caller owns the
// two empty slices as it would own the real ones.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: std.process.RunOptions,
) std.process.RunError!std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    const has_limit = options.stdout_limit.toInt() != null or options.stderr_limit.toInt() != null;
    const kinds: []const u8 = if (has_limit) &limited_output_kinds else &unlimited_output_kinds;
    if (state.ask(.spawn, kinds)) |kind| {
        if (state.isKind(.spawn, "output_past_the_limit", kind)) {
            return error.StreamTooLong;
        }
        return error.Timeout;
    }

    const term = try child.wait(io);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

test {
    _ = @import("effect_spawn.test.zig");
}
