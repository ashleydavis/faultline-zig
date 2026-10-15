const std = @import("std");
const walk = @import("src/cmd/walk.zig");
const import_table = @import("src/cmd/import_table.zig");
const make_public = @import("src/cmd/make_public.zig");
const module_table = @import("src/cmd/module_table.zig");

// Faultline's build. It declares the modules a project's build uses (`sim`, which a project's sim
// files import, and `faultline`, which the program built for a project is made of), the step a
// project adds with `addFaultTest`, and the unit tests.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one module a project's `.sim.zig` files import. The name is `sim` because that is what
    // the project's sim files import.
    const sim_module = b.addModule("sim", .{
        .root_source_file = b.path("src/sim/sim.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Everything the program built for a project is made of except the project's own files. It is
    // rooted in `src/` because the files under `src/framework/` and `src/cmd/` import each other,
    // and Zig refuses an import that leaves the directory of the module's root file.
    _ = b.addModule("faultline", .{
        .root_source_file = b.path("src/faultline.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sim", .module = sim_module }},
    });

    // Each root is a file that pulls in the files of one part of Faultline through `test` blocks,
    // so a part's tests are collected by building its root. A root is built twice: in the default
    // optimisation and in `ReleaseSafe`, because the program a run compiles is not built the way
    // `zig build test` builds by default.
    const test_roots = [_][]const u8{
        "src/sim/sim.zig",
        "src/framework/places.zig",
        "src/framework/condition.zig",
        "src/framework/printing.zig",
        "src/running_tests.zig",
        "src/discover_tests.zig",
        "src/framework/kcov.zig",
        "src/framework/world.zig",
        "src/framework/world_effects.zig",
        "src/framework/values.zig",
    };

    const test_step = b.step("test", "Run every unit test, in the default optimisation and again in ReleaseSafe");
    for (test_roots) |root| {
        for ([_]std.builtin.OptimizeMode{ optimize, .ReleaseSafe }) |mode| {
            const root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = mode,
            });
            // The framework reaches the project-facing contexts through the module of the name
            // `sim`, the same one a project's sim files import, so the two share one set of types.
            if (!std.mem.eql(u8, root, "src/sim/sim.zig")) {
                root_module.addImport("sim", sim_module);
            }
            const unit_tests = b.addTest(.{ .root_module = root_module });
            const run_tests = b.addRunArtifact(unit_tests);
            // Some tests read files in this repository, such as the table of failures in the
            // docs, so they run from its root and not from wherever the test binary is written.
            run_tests.setCwd(b.path("."));
            test_step.dependOn(&run_tests.step);
        }
    }
}

// What a project passes to `addFaultTest`.
pub const FaultTestOptions = struct {
    // The files and directories to fault test, as paths relative to the project root. Naming any
    // entry turns off the search of the whole project, so only what is named is taken.
    include: []const []const u8 = &.{},

    // The files and directories to leave out, as paths relative to the project root. Leaving a
    // path out wins over including it.
    exclude: []const []const u8 = &.{},

    // What the program is built for. The host, because it runs on the machine that builds it.
    target: ?std.Build.ResolvedTarget = null,

    // What the program is built at. `Debug`, because kcov reads which lines ran from the line table
    // of the binary and a release build drops the line of most statements.
    optimize: std.builtin.OptimizeMode = .Debug,
};

// Adds the `flt` step to a project's own build. Call it after the project's modules are registered
// with `b.addModule`, because the program is given every module the build has.
//
// Everything happens inside the project's build, in its cache. The step copies the project's `.zig`
// files and Faultline's static root into a directory of the cache, writes a table of the files to
// fault test beside them, compiles the program from that and runs it from a directory of its own in
// the cache. It writes nothing into the project.
pub fn addFaultTest(b: *std.Build, options: FaultTestOptions) void {
    const faultline = b.dependency("faultline", .{});
    const target = options.target orelse b.graph.host;

    var threaded = std.Io.Threaded.init(b.allocator, .{});
    const io = threaded.io();

    const project_root = b.build_root.path orelse ".";
    var project = std.Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true }) catch {
        @panic("faultline: the project root cannot be opened");
    };
    defer project.close(io);

    const found = walk.collect(b.allocator, io, project, .{ .include = options.include, .exclude = options.exclude }) catch {
        @panic("faultline: the project cannot be searched");
    };

    // Every `.zig` file in the project is copied, so an import in a file that is fault tested finds
    // the file it names even when that file is not itself fault tested. A file that is skipped is
    // still copied. Only the files named in the table below are called. In the copy of each file
    // that is fault tested every function is made public, so each one is called directly.
    var fault_tested: std.StringHashMapUnmanaged(void) = .empty;
    for (found) |file| {
        if (file.kind == .source) {
            fault_tested.put(b.allocator, file.path, {}) catch @panic("OOM");
        }
    }
    const written = b.addWriteFiles();
    const everything = walk.report(b.allocator, io, project, .{}) catch @panic("faultline: the project cannot be searched");
    for (everything) |record| {
        if (record.is_directory or !std.mem.endsWith(u8, record.path, ".zig")) {
            continue;
        }
        if (!fault_tested.contains(record.path)) {
            _ = written.addCopyFile(b.path(record.path), record.path);
            continue;
        }
        const source = project.readFileAllocOptions(io, record.path, b.allocator, .unlimited, .of(u8), 0) catch {
            @panic("faultline: a file to fault test cannot be read");
        };
        const made = make_public.makePublic(b.allocator, source) catch @panic("OOM");
        _ = written.add(record.path, made);
    }
    var sources: std.ArrayList(import_table.Source) = .empty;
    var simulations: std.ArrayList(import_table.Simulation) = .empty;
    for (found) |file| {
        switch (file.kind) {
            .source => sources.append(b.allocator, .{ .path = file.path }) catch @panic("OOM"),
            .sim => {
                const beside = file.partner orelse std.fmt.allocPrint(b.allocator, "{s}.zig", .{file.path[0 .. file.path.len - ".sim.zig".len]}) catch @panic("OOM");
                simulations.append(b.allocator, .{ .path = file.path, .source = beside }) catch @panic("OOM");
            },
        }
    }
    const table = import_table.render(b.allocator, sources.items, simulations.items) catch @panic("OOM");
    _ = written.add("flt_files.zig", table);
    const root = written.addCopyFile(faultline.path("src/runner_root.zig"), "flt_root.zig");

    std.debug.print("Fault testing the Zig source in {s}.\n", .{std.fs.path.basename(project_root)});

    // The program is given `sim` and `faultline` and every module the project's build has, with the
    // modules each of those imports, so the copies of the project's files find what they import.
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    var named: std.StringHashMapUnmanaged(void) = .empty;
    const reserved = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "sim", .module = faultline.module("sim") },
        .{ .name = "faultline", .module = faultline.module("faultline") },
    };
    for (reserved) |entry| {
        imports.append(b.allocator, .{ .name = entry.name, .module = entry.module }) catch @panic("OOM");
        named.put(b.allocator, entry.name, {}) catch @panic("OOM");
    }
    var modules = b.modules.iterator();
    while (modules.next()) |entry| {
        addImportOnce(b, &imports, &named, entry.key_ptr.*, entry.value_ptr.*);
        var inner = entry.value_ptr.*.import_table.iterator();
        while (inner.next()) |dependency| {
            addImportOnce(b, &imports, &named, dependency.key_ptr.*, dependency.value_ptr.*);
        }
    }

    // Where each module's root file is, so the results kept of a file are thrown away when a
    // module it imports changes.
    var table_of_modules: std.ArrayList(module_table.Module) = .empty;
    for (imports.items) |import| {
        if (isReserved(import.name)) {
            continue;
        }
        const placed = placeOf(b, import.module) orelse continue;
        table_of_modules.append(b.allocator, .{ .name = import.name, .place = placed.place, .path = placed.path }) catch @panic("OOM");
    }
    _ = written.add(module_table.file_name, module_table.render(b.allocator, table_of_modules.items) catch @panic("OOM"));

    const program = b.addExecutable(.{
        .name = "flt-sim",
        // The LLVM backend, because kcov reads the binary's line table through libdw and gets no
        // lines at all out of the one Zig's own x86 backend writes for a Debug build.
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = options.optimize,
            .imports = imports.items,
        }),
    });

    // The program stands in a directory of its own, never in the project, because the functions it
    // calls are the project's own and a function creates files where it is standing.
    const sandbox = b.cache_root.join(b.allocator, &.{"flt-sandbox"}) catch @panic("OOM");
    std.Io.Dir.cwd().createDirPath(io, sandbox) catch @panic("faultline: the sandbox cannot be made");

    const run = b.addRunArtifact(program);
    run.setCwd(.{ .cwd_relative = sandbox });
    run.has_side_effects = true;
    run.addArgs(&.{ "--repository", project_root });

    // Paths are made absolute because the program stands in the sandbox and not in the project.
    const cache = b.pathJoin(&.{ project_root, b.cache_root.join(b.allocator, &.{}) catch @panic("OOM") });
    const report_path = if (b.option([]const u8, "report", "Where the full list of code paths is written")) |named_path|
        (if (std.fs.path.isAbsolute(named_path)) named_path else b.pathJoin(&.{ project_root, named_path }))
    else
        b.pathJoin(&.{ cache, "faultline-report.txt" });
    run.addArgs(&.{ "--report", report_path });
    run.addArgs(&.{ "--kcov-out", b.pathJoin(&.{ cache, "flt-kcov" }) });

    // The results of earlier runs, so code an earlier run proved and that has not changed since is
    // not executed again. The salt is which Faultline this is and how the program is built, so a
    // different Faultline or a different build throws every kept result away.
    const results_path = b.pathJoin(&.{ cache, "flt-results" });
    run.addArgs(&.{ "--results-cache", results_path });
    run.addArgs(&.{ "--cache-salt", saltOf(b, faultline, target, options.optimize) });
    run.addArg("--sources-root");
    run.addDirectoryArg(written.getDirectory());
    if (b.option([]const u8, "kcov", "The kcov binary, when it is not on the PATH")) |named_path| {
        run.addArgs(&.{ "--kcov", named_path });
    }
    if (b.option([]const u8, "file", "Fault test only this file, relative to the project root")) |only| {
        run.addArgs(&.{ "--file", only });
    }
    if (b.option([]const u8, "function", "Fault test only functions of this name")) |only| {
        run.addArgs(&.{ "--function", only });
    }
    if (b.option([]const u8, "replay", "Repeat a failure Faultline already reported")) |token| {
        run.addArgs(&.{ "--replay", token });
    }
    if (b.option(usize, "jobs", "How many workers run at once, one per processor core by default")) |jobs| {
        if (jobs == 0) {
            std.debug.print("-Djobs is how many workers run at once, so it has to be at least 1.\n", .{});
            std.process.exit(1);
        }
        run.addArgs(&.{ "--jobs", b.fmt("{d}", .{jobs}) });
    }

    // The program exits with zero and writes the code it would have exited with to a file, and a
    // step of Faultline's own fails the build from it. A failed run step makes Zig print the whole
    // command line of the program after Faultline's report, which says nothing the report has not.
    const exit_path = b.pathJoin(&.{ cache, "flt-exit.txt" });
    run.addArgs(&.{ "--exit-file", exit_path });
    const exit_step = b.allocator.create(ExitStep) catch @panic("OOM");
    exit_step.* = .{
        .step = std.Build.Step.init(.{ .id = .custom, .name = "faultline", .owner = b, .makeFn = ExitStep.make }),
        .path = exit_path,
    };
    exit_step.step.dependOn(&run.step);

    // What follows `--` on the command line, such as `--no-cache`, goes to the program as it is.
    if (b.args) |extra| {
        run.addArgs(extra);
    }

    // `zig build flt clear` throws away the kept results and runs nothing. Zig reads `clear` as a
    // second step to run beside `flt`, so `flt` is told to do nothing else when it is there.
    const clear_step = b.allocator.create(ClearStep) catch @panic("OOM");
    clear_step.* = .{
        .step = std.Build.Step.init(.{ .id = .custom, .name = "clear Faultline's cache", .owner = b, .makeFn = ClearStep.make }),
        .path = results_path,
    };
    const flt_step = b.step("flt", "Fault test every function down every code path. `zig build flt clear` throws away the results kept of earlier runs");
    if (!b.top_level_steps.contains("clear")) {
        b.step("clear", "With `flt`, throw away the results Faultline kept of earlier runs").dependOn(&clear_step.step);
    }
    if (isClearAsked(b, io)) {
        flt_step.dependOn(&clear_step.step);
    } else {
        flt_step.dependOn(&exit_step.step);
    }
}

// Whether the command line of this build asks for `flt` and `clear` together. Zig does not hand
// the build the names of the steps it was asked for, so they are read from the build runner's own
// command line. Everything after `--` is for the program and is not a step.
fn isClearAsked(b: *std.Build, io: std.Io) bool {
    // Read as a stream, because the kernel reports a size of zero for every file under `/proc`.
    const file = std.Io.Dir.cwd().openFile(io, "/proc/self/cmdline", .{}) catch return false;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const text = reader.interface.allocRemaining(b.allocator, .unlimited) catch return false;
    var has_flt = false;
    var has_clear = false;
    var arguments = std.mem.splitScalar(u8, text, 0);
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--")) {
            break;
        }
        if (std.mem.eql(u8, argument, "flt")) {
            has_flt = true;
        } else if (std.mem.eql(u8, argument, "clear")) {
            has_clear = true;
        }
    }
    return has_flt and has_clear;
}

// Throws away the results Faultline kept of earlier runs, so the next run executes every file.
const ClearStep = struct {
    step: std.Build.Step,

    // The directory the results are kept in.
    path: []const u8,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *ClearStep = @fieldParentPtr("step", step);
        std.Io.Dir.cwd().deleteTree(step.owner.graph.io, self.path) catch |err| {
            return step.fail("Faultline's cache of results could not be cleared: {t}.", .{err});
        };
        std.debug.print("Cleared the results Faultline kept of earlier runs, so the next run executes every file.\n", .{});
    }
};

// Whether `name` is one of the modules every program is given, whose files are part of Faultline.
fn isReserved(name: []const u8) bool {
    return std.mem.eql(u8, name, "sim") or std.mem.eql(u8, name, "faultline");
}

// Where a module's root file is, for the table of modules, or null for a module with none.
fn placeOf(b: *std.Build, module: *std.Build.Module) ?struct { place: module_table.Place, path: []const u8 } {
    const root = module.root_source_file orelse return null;
    switch (root) {
        .src_path => |source| {
            if (source.owner == b) {
                return .{ .place = .project, .path = source.sub_path };
            }
            return .{ .place = .outside, .path = b.pathJoin(&.{ source.owner.build_root.path orelse ".", source.sub_path }) };
        },
        .dependency => |dependency| {
            return .{ .place = .outside, .path = b.pathJoin(&.{ dependency.dependency.builder.build_root.path orelse ".", dependency.sub_path }) };
        },
        .cwd_relative => |path| return .{ .place = .outside, .path = path },
        .generated => return .{ .place = .generated, .path = "" },
    }
}

// What tells one Faultline apart from another, with the target and the optimisation the program is
// built at, as text. Every key of the results cache starts from it. For a fetched Faultline it is
// the directory Zig keeps the package in, whose name Zig makes from a hash of the package's
// contents, so a new version or any change to a published one throws every kept result away. Read
// from a path Zig already knows, it costs a run nothing. A Faultline used from a local path keeps
// one directory however it is edited, so after an edit `zig build flt clear` throws the results
// away.
fn saltOf(b: *std.Build, faultline: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const u8 {
    const triple = target.result.zigTriple(b.allocator) catch @panic("OOM");
    return b.fmt("{s}|{s}|{t}", .{ faultline.builder.build_root.path orelse ".", triple, optimize });
}

// Fails the build when the program's exit code, written to a file, is not zero. Faultline's report
// above already says what failed, so the build runner is ended at once with the code it uses for a
// failure it should not describe again: a failed step would make Zig print the step tree, a build
// summary and the build runner's whole command line after the report.
const ExitStep = struct {
    step: std.Build.Step,

    // The file the program wrote its exit code to.
    path: []const u8,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *ExitStep = @fieldParentPtr("step", step);
        const text = std.Io.Dir.cwd().readFileAlloc(step.owner.graph.io, self.path, step.owner.allocator, .limited(16)) catch {
            return step.fail("Faultline did not say how it ended, so the build is failed.", .{});
        };
        const code = std.mem.trim(u8, text, " \n");
        if (!std.mem.eql(u8, code, "0")) {
            // Two is what the build runner exits with when a step failed and the failure is not
            // to be described again (`build_runner.zig`), and Zig then prints nothing more.
            std.process.exit(2);
        }
    }
};

// Adds a module to the program's imports unless one of that name is already there.
fn addImportOnce(
    b: *std.Build,
    imports: *std.ArrayList(std.Build.Module.Import),
    named: *std.StringHashMapUnmanaged(void),
    name: []const u8,
    module: *std.Build.Module,
) void {
    if (named.contains(name)) {
        return;
    }
    named.put(b.allocator, name, {}) catch @panic("OOM");
    imports.append(b.allocator, .{ .name = name, .module = module }) catch @panic("OOM");
}
