// Runs one call in a forked child process so a call that crashes or never returns costs that call
// and nothing else, and so every call starts from a process that has done nothing yet.
//
// What the child says crosses a pipe as plain bytes, and what it complains about on its error
// stream crosses a second pipe. The parent never trusts the child to finish: how the child ended
// (exited, killed by a signal, or killed for taking too long) is read from the system and returned
// with whatever the child managed to say.
//
// Linux only: it uses `fork`, `pipe2`, `poll`, `setrlimit` and `wait4` directly. Nothing here knows
// what a call is. A caller hands over a runner and gets back the bytes it wrote.

const std = @import("std");
const linux = std.os.linux;

// How long a child may take and how much processor time it may use.
pub const Limits = struct {
    // Processor time the child may use before the kernel stops it. This is what catches a call
    // stuck in a loop, and processor time is the right measure because a busy machine does not
    // change it.
    processor_seconds: u32,

    // How long the child may take on the clock before the parent kills it. The backstop for a child
    // that has stopped without using any processor time.
    wall_ms: u32,
};

// What a call gets unless a caller says otherwise. Five processor seconds is about a thousand times
// what the slowest call that finishes uses, so a run on a loaded machine never loses a call to
// scheduling gaps. The wall limit is far above that for the same reason: coverage that depends on
// how busy the machine is would make a run give different answers.
pub const default_limits: Limits = .{ .processor_seconds = 5, .wall_ms = 30_000 };

// The most a child may say on its output. A call that prints without end is stopped rather than
// allowed to fill the parent's memory.
pub const max_output_bytes = 64 * 1024 * 1024;

// The most of a child's error stream that is kept. A panic message and a short trace fit well
// inside it, and the end is dropped because the start says what happened.
pub const max_complaint_bytes = 64 * 1024;

// How a child's life ended.
pub const Ending = union(enum) {
    // The child returned and exited with this status.
    exited: u8,

    // The system stopped the child with this signal number: a crash, a panic or the processor limit.
    signaled: u32,

    // The parent killed the child for taking longer than the wall limit.
    timed_out,
};

// What one child did.
pub const Attempt = struct {
    // How the child ended.
    ending: Ending,

    // What the child wrote on its output, in full, even when it later crashed.
    output: []u8,

    // What the child wrote on its error stream, cut at `max_complaint_bytes`. For a crash this is
    // the panic message and the trace.
    complaint: []u8,

    pub fn deinit(self: *Attempt, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        allocator.free(self.complaint);
    }

    // Whether the child returned and exited cleanly.
    pub fn isClean(self: Attempt) bool {
        return switch (self.ending) {
            .exited => |status| status == 0,
            else => false,
        };
    }
};

// The signal the kernel sends when the processor limit is reached.
pub const processor_limit_signal: u32 = @intFromEnum(linux.SIG.XCPU);

// Runs `runner.run(&writer)` in a forked child and returns what came of it. `runner` is any value
// with a `run` method taking a `*std.Io.Writer`; the child writes its report there and the bytes
// reach the parent through the pipe when the method returns.
pub fn attempt(allocator: std.mem.Allocator, runner: anytype, limits: Limits) !Attempt {
    var output_pipe: [2]i32 = undefined;
    var complaint_pipe: [2]i32 = undefined;
    try makePipe(&output_pipe);
    errdefer closeBoth(output_pipe);
    try makePipe(&complaint_pipe);
    errdefer closeBoth(complaint_pipe);

    const forked = linux.fork();
    if (linux.errno(forked) != .SUCCESS) {
        return error.ForkFailed;
    }
    if (forked == 0) {
        runInChild(runner, limits, output_pipe, complaint_pipe);
    }

    // The parent only reads, so it closes the ends the child writes to. Without that the reads
    // below would never see the end of the stream.
    _ = linux.close(output_pipe[1]);
    _ = linux.close(complaint_pipe[1]);
    defer _ = linux.close(output_pipe[0]);
    defer _ = linux.close(complaint_pipe[0]);

    return collect(allocator, @intCast(forked), output_pipe[0], complaint_pipe[0], limits);
}

fn makePipe(ends: *[2]i32) !void {
    const made = linux.pipe2(ends, .{ .CLOEXEC = false });
    if (linux.errno(made) != .SUCCESS) {
        return error.PipeFailed;
    }
}

fn closeBoth(ends: [2]i32) void {
    _ = linux.close(ends[0]);
    _ = linux.close(ends[1]);
}

// Whether this process is a forked child. Set once, straight after the fork, and read by the panic
// handler, which does one thing in a child and another in the parent.
var in_child = false;

// What a panic does. A child writes the message and leaves with the status of an abort, without a
// stack trace: building one means reading the program's debug information, which was measured at
// about 0.2 seconds for each panic here against 0.005 seconds for a call that returns, and a
// project with functions that panic on most inputs spends nearly all of a run on it. The parent
// keeps only the first line of what the child wrote, so the trace was never shown.
//
// The status is the one the signal handler for an abort leaves with, so the parent reads the end
// of the child as the same crash it read before. The parent panics the ordinary way: a crash
// there is a defect in Faultline and the message and trace are the whole diagnosis.
pub fn panicInChild(message: []const u8, first_trace_address: ?usize) noreturn {
    if (in_child) {
        writeAll(2, "panic: ");
        writeAll(2, message);
        writeAll(2, "\n");
        linux.exit_group(@intCast(signal_exit_base + @intFromEnum(linux.SIG.ABRT)));
    }
    std.debug.defaultPanic(message, first_trace_address);
}

// What the child does between being forked and ending. Never returns.
fn runInChild(runner: anytype, limits: Limits, output_pipe: [2]i32, complaint_pipe: [2]i32) noreturn {
    in_child = true;
    _ = linux.close(output_pipe[0]);
    _ = linux.close(complaint_pipe[0]);

    // The child's error stream goes down the second pipe, so a panic message reaches the parent
    // instead of the terminal.
    _ = linux.dup2(complaint_pipe[1], 2);
    _ = linux.close(complaint_pipe[1]);

    // Past the soft limit the kernel sends `XCPU`, whose default action ends the process, so the
    // parent reads the signal. The hard limit is a second later in case the signal is ignored.
    const processor: linux.rlimit = .{ .cur = limits.processor_seconds, .max = limits.processor_seconds + 1 };
    _ = linux.setrlimit(.CPU, &processor);

    // A call that crashes is an ordinary result here, so the system must not write a core file or
    // start a crash reporter for it: a reporter is slow and writes outside the project. The
    // signals that would dump a core are caught instead and the child leaves with a status that
    // names the signal.
    catchCrashes();

    // Memory the child allocates is never freed: the process is about to exit.
    var report: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    runner.run(&report.writer);

    writeAll(output_pipe[1], report.written());
    _ = linux.close(output_pipe[1]);
    linux.exit_group(0);
}

// The signals whose default action is to stop the process and dump a core. A crash, an abort (which
// is what a panic ends in) and the processor limit are all among them.
const crash_signals = [_]linux.SIG{ .SEGV, .BUS, .ILL, .FPE, .TRAP, .ABRT, .XCPU };

// What a child's exit status is when it left because of a signal it caught: this plus the signal
// number. 128 is the number a shell gives a process killed by a signal, so a status above it
// is read the same way here.
const signal_exit_base: u8 = 128;

// Where the handler runs. A segmentation fault from a stack that ran out has no stack to run on, so
// the handler has one of its own. The size is the standard library's own recommended signal stack,
// which is enough for a handler that makes one system call and nothing else. It is static because
// the child is forked from a parent that never runs the handler.
var crash_stack: [linux.SIGSTKSZ]u8 align(16) = undefined;

fn catchCrashes() void {
    const alternate: linux.stack_t = .{ .sp = &crash_stack, .flags = 0, .size = crash_stack.len };
    _ = linux.sigaltstack(&alternate, null);

    const leaving: linux.Sigaction = .{
        .handler = .{ .handler = &leaveOnSignal },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.ONSTACK,
    };
    for (crash_signals) |signal| {
        _ = linux.sigaction(signal, &leaving, null);
    }
}

fn leaveOnSignal(signal: linux.SIG) callconv(.c) void {
    linux.exit_group(@intCast(signal_exit_base + @intFromEnum(signal)));
}

fn writeAll(fd: i32, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const wrote = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(wrote) != .SUCCESS or wrote == 0) {
            return;
        }
        done += wrote;
    }
}

// Reads both pipes until the child closes them or the wall limit passes, then reaps the child.
fn collect(allocator: std.mem.Allocator, pid: i32, output_fd: i32, complaint_fd: i32, limits: Limits) !Attempt {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var complaint: std.ArrayList(u8) = .empty;
    errdefer complaint.deinit(allocator);

    var watched = [_]linux.pollfd{
        .{ .fd = output_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = complaint_fd, .events = linux.POLL.IN, .revents = 0 },
    };
    var open_count: usize = 2;
    var timed_out = false;
    const started = nowMs();
    var buffer: [16 * 1024]u8 = undefined;

    while (open_count > 0) {
        const elapsed = nowMs() - started;
        if (elapsed >= limits.wall_ms) {
            timed_out = true;
            break;
        }
        const remaining: i32 = @intCast(@min(limits.wall_ms - elapsed, std.math.maxInt(i32)));
        const ready = linux.poll(&watched, watched.len, remaining);
        if (linux.errno(ready) == .INTR) {
            continue;
        }
        if (linux.errno(ready) != .SUCCESS) {
            return error.PollFailed;
        }
        for (&watched, 0..) |*entry, index| {
            if (entry.fd < 0 or entry.revents == 0) {
                continue;
            }
            const got = linux.read(entry.fd, &buffer, buffer.len);
            if (linux.errno(got) == .INTR) {
                continue;
            }
            if (linux.errno(got) != .SUCCESS or got == 0) {
                entry.fd = -1;
                open_count -= 1;
                continue;
            }
            if (index == 0) {
                if (output.items.len + got > max_output_bytes) {
                    return error.OutputTooLong;
                }
                try output.appendSlice(allocator, buffer[0..got]);
            } else if (complaint.items.len < max_complaint_bytes) {
                const room = max_complaint_bytes - complaint.items.len;
                try complaint.appendSlice(allocator, buffer[0..@min(got, room)]);
            }
        }
    }

    if (timed_out) {
        _ = linux.kill(pid, .KILL);
    }
    var status: u32 = 0;
    while (true) {
        const waited = linux.wait4(pid, &status, 0, null);
        if (linux.errno(waited) == .INTR) {
            continue;
        }
        break;
    }

    const ending: Ending = if (timed_out)
        .timed_out
    else if (linux.W.IFSIGNALED(status))
        .{ .signaled = @intFromEnum(linux.W.TERMSIG(status)) }
    else if (isCaughtSignalStatus(linux.W.EXITSTATUS(status)))
        .{ .signaled = linux.W.EXITSTATUS(status) - signal_exit_base }
    else
        .{ .exited = linux.W.EXITSTATUS(status) };

    return .{
        .ending = ending,
        .output = try output.toOwnedSlice(allocator),
        .complaint = try complaint.toOwnedSlice(allocator),
    };
}

// Whether an exit status is the one a child leaves with after catching one of the crash signals.
fn isCaughtSignalStatus(status: u8) bool {
    for (crash_signals) |signal| {
        if (status == signal_exit_base + @intFromEnum(signal)) {
            return true;
        }
    }
    return false;
}

// The monotonic clock in milliseconds.
fn nowMs() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / 1_000_000;
}

test {
    _ = @import("isolate.test.zig");
}
