const std = @import("std");
const walk = @import("src/cmd/walk.zig");
const import_table = @import("src/cmd/import_table.zig");

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

    // Every `.zig` file in the project is copied, so an import in a file that is fault tested finds
    // the file it names even when that file is not itself fault tested. A file that is skipped is
    // still copied. Only the files named in the table below are called.
    const written = b.addWriteFiles();
    const everything = walk.report(b.allocator, io, project, .{}) catch @panic("faultline: the project cannot be searched");
    for (everything) |record| {
        if (record.is_directory or !std.mem.endsWith(u8, record.path, ".zig")) {
            continue;
        }
        _ = written.addCopyFile(b.path(record.path), record.path);
    }

    const found = walk.collect(b.allocator, io, project, .{ .include = options.include, .exclude = options.exclude }) catch {
        @panic("faultline: the project cannot be searched");
    };
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

    b.step("flt", "Fault test every function down every code path").dependOn(&exit_step.step);
}

// Fails the build when the program's exit code, written to a file, is not zero. Its one sentence
// points back at Faultline's report, which is what says what failed. Zig needs a failed step to
// carry a message and prints nothing else about it.
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
            return step.fail("Faultline exited with code {s}. What it found is above.", .{code});
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
