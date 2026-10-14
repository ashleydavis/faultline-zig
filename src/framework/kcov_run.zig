// Runs one worker process under kcov and checks at startup that kcov can be run at all.
//
// kcov reports which lines ran only when the process it watched has exited, so every pass that
// needs coverage is a worker process of its own, started by `runWorker`. When the worker exits
// kcov writes `cov.xml` into the output directory, which `covered_lines.zig` reads. What a pass
// means for the code paths is the caller's: this file only starts the process and says how it
// ended.

const std = @import("std");

// What kcov is called when `-Dkcov=<path>` is not given: a bare name, which is looked up on the
// PATH the way a shell would.
pub const default_kcov = "kcov";

// The name of the file kcov writes into its output directory when `--cobertura-only` is given.
pub const coverage_file_name = "cov.xml";

// How one worker process is run under kcov.
pub const Options = struct {
    // The kcov binary: a bare name looked up on the PATH, or a path.
    kcov: []const u8 = default_kcov,

    // The directory kcov writes its output into. One directory per pass, so what a pass added can
    // be read on its own and kcov never mixes one pass into the next.
    out_dir: []const u8,

    // The directory holding the copies of the project's sources the worker was compiled from,
    // which is what kcov is told to report on. Everything else in the binary, Faultline itself and
    // the standard library, is left alone, which keeps a pass to the cost of a bare run.
    sources_root: []const u8,

    // The worker binary: the program kcov watches.
    worker: []const u8,

    // The arguments the worker is given, after its own path.
    worker_args: []const []const u8 = &.{},

    // The environment kcov and the worker run with. Null gives a spawned process the standard
    // library's own default, which does not carry a PATH that holds a kcov installed in a home
    // directory, so a run passes the environment it was started with.
    environ_map: ?*const std.process.Environ.Map = null,
};

// The two ways a worker ends badly. `WorkerFailed` means it exited with a non-zero status and
// `WorkerWasKilled` means a signal ended it. What the worker printed has already gone to the
// terminal, so the caller only has to say which happened.
pub const RunError = error{ WorkerFailed, WorkerWasKilled };

// The one way the startup check fails: kcov cannot be run. The caller turns it into exit code 1.
pub const StartupError = error{KcovNotFound};

// Runs the worker under kcov and returns when it exits. The worker's output goes straight to the
// terminal. The output directory is emptied first, because kcov adds a run to the data already in
// it and the coverage of an earlier run would be counted as this one's. Fails with `WorkerFailed`
// on a non-zero exit and `WorkerWasKilled` on a signal. Spawning and waiting fail with the errors
// of the standard library, which pass through unchanged.
pub fn runWorker(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var child = try startWorker(allocator, io, options);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                return error.WorkerFailed;
            }
        },
        else => {
            return error.WorkerWasKilled;
        },
    }
}

// Starts the worker under kcov the way `runWorker` does and returns without waiting for it, so
// several can run at once. `checkWorker` says when it has ended.
pub fn startWorker(allocator: std.mem.Allocator, io: std.Io, options: Options) !std.process.Child {
    try std.Io.Dir.cwd().deleteTree(io, options.out_dir);
    try std.Io.Dir.cwd().createDirPath(io, options.out_dir);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const include = try includeArgument(allocator, options.sources_root);
    defer allocator.free(include);
    try argv.appendSlice(allocator, &.{
        options.kcov,
        "--cobertura-only",
        include,
        options.out_dir,
        options.worker,
    });
    try argv.appendSlice(allocator, options.worker_args);

    return std.process.spawn(io, .{ .argv = argv.items, .environ_map = options.environ_map });
}

// Whether a worker `startWorker` started has ended, without waiting for it. True once it exited
// with zero, and then it has been waited for. Fails as `runWorker` does when it ended badly.
pub fn checkWorker(child: *std.process.Child) RunError!bool {
    const linux = std.os.linux;
    const pid = child.id orelse return true;
    var status: u32 = 0;
    const waited = linux.wait4(pid, &status, linux.W.NOHANG, null);
    if (linux.errno(waited) != .SUCCESS or waited == 0) {
        return false;
    }
    child.id = null;
    if (linux.W.IFEXITED(status)) {
        if (linux.W.EXITSTATUS(status) != 0) {
            return error.WorkerFailed;
        }
        return true;
    }
    return error.WorkerWasKilled;
}

// The argument that restricts kcov's report to the project's own sources. Free with `allocator`.
pub fn includeArgument(allocator: std.mem.Allocator, sources_root: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "--include-path={s}", .{sources_root});
}

// The path of the coverage file kcov writes for a pass whose output directory is `out_dir`. Free
// with `allocator`.
pub fn coveragePathOf(allocator: std.mem.Allocator, out_dir: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, coverage_file_name });
}

// Whether `kcov` can be run at all: it is started with `--version` and has to exit cleanly. A bare
// name is looked up on the PATH the way a shell would.
pub fn isKcovRunnable(io: std.Io, kcov: []const u8, environ_map: ?*const std.process.Environ.Map) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ kcov, "--version" },
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = environ_map,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

// The startup check. When `kcov` cannot be run, writes one sentence to `writer` saying so and
// where the install instructions are and fails with `KcovNotFound` so the caller exits with
// code 1 before anything runs. Writes nothing when kcov can be run.
pub fn requireKcov(io: std.Io, writer: *std.Io.Writer, kcov: []const u8, environ_map: ?*const std.process.Environ.Map) (StartupError || std.Io.Writer.Error)!void {
    if (isKcovRunnable(io, kcov, environ_map)) {
        return;
    }
    try writer.print(
        "Faultline needs kcov to see which lines ran and could not find \"{s}\", so install kcov as described in docs/USER-GUIDE.md under \"Install kcov\" or name it with -Dkcov=<path>.\n",
        .{kcov},
    );
    return error.KcovNotFound;
}

test {
    _ = @import("kcov_run.test.zig");
}
