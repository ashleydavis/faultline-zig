// The command line of the program Faultline builds for a project.
//
// Most of these are written by the build step and never typed: the build knows where the sources
// were copied to and where kcov puts its output. The ones a person reaches for are named in the
// user guide as build options (`-Dfile`, `-Dfunction`, `-Dreplay`, `-Dkcov`, `-Dreport`) and the
// build step turns each into one of these.

const std = @import("std");

pub const Args = struct {
    // The project's own directory, for naming files the way the project does.
    repository: []const u8 = "",

    // Where the full list of code paths is written, when a person asked for it.
    report: ?[]const u8 = null,

    // The kcov binary, when it is not on the PATH.
    kcov: ?[]const u8 = null,

    // Where kcov writes what it measured.
    kcov_output: []const u8 = "",

    // The directory the project's sources were copied to, which is what kcov reports on.
    sources_root: []const u8 = "",

    // Fault test only this file, relative to the project root.
    only_file: ?[]const u8 = null,

    // Fault test only functions of this name.
    only_function: ?[]const u8 = null,

    // A replay token from an earlier failure.
    replay: ?[]const u8 = null,

    // Whether this is a worker the driver started under kcov, and not the driver itself.
    worker: bool = false,

    // The file a worker reads its list of calls from.
    work: ?[]const u8 = null,

    // The file a worker writes what it found to.
    result: ?[]const u8 = null,

    // The seed the random number generator starts from, as a decimal number. The driver picks one
    // for each run and hands it to every worker so they agree.
    seed: ?u64 = null,

    // Where to write the exit code, as text, when the program is to exit with zero whatever the
    // code is. The build step reads it and fails the build itself, so Zig does not print its own
    // account of a failed program after Faultline's report.
    exit_file: ?[]const u8 = null,

    // Whether colour is off.
    no_color: bool = false,

    // How many workers run at once, or null for one per processor core.
    jobs: ?usize = null,

    // The file a worker writes how far it has got to, for the driver to read, instead of printing a
    // progress line of its own that would overwrite the other workers' lines.
    progress_file: ?[]const u8 = null,
};

// What can be wrong with a command line.
pub const ParseError = error{
    UnknownOption,
    MissingValue,
    BadNumber,
};

// Reads the command line, without the program's own name.
pub fn parse(arguments: []const []const u8) ParseError!Args {
    var parsed: Args = .{};
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const option = arguments[index];
        if (std.mem.eql(u8, option, "--worker")) {
            parsed.worker = true;
        } else if (std.mem.eql(u8, option, "--no-color")) {
            parsed.no_color = true;
        } else if (std.mem.eql(u8, option, "--repository")) {
            parsed.repository = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--report")) {
            parsed.report = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--kcov")) {
            parsed.kcov = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--kcov-out")) {
            parsed.kcov_output = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--sources-root")) {
            parsed.sources_root = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--file")) {
            parsed.only_file = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--function")) {
            parsed.only_function = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--replay")) {
            parsed.replay = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--work")) {
            parsed.work = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--result")) {
            parsed.result = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--exit-file")) {
            parsed.exit_file = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--progress-file")) {
            parsed.progress_file = try valueOf(arguments, &index);
        } else if (std.mem.eql(u8, option, "--jobs")) {
            const text = try valueOf(arguments, &index);
            const jobs = std.fmt.parseInt(usize, text, 10) catch return error.BadNumber;
            if (jobs == 0) {
                return error.BadNumber;
            }
            parsed.jobs = jobs;
        } else if (std.mem.eql(u8, option, "--seed")) {
            const text = try valueOf(arguments, &index);
            parsed.seed = std.fmt.parseInt(u64, text, 10) catch return error.BadNumber;
        } else {
            return error.UnknownOption;
        }
    }
    return parsed;
}

// The argument after the option at `index`, advancing `index` past it.
fn valueOf(arguments: []const []const u8, index: *usize) ParseError![]const u8 {
    if (index.* + 1 >= arguments.len) {
        return error.MissingValue;
    }
    index.* += 1;
    return arguments[index.*];
}

test {
    _ = @import("args.test.zig");
}
