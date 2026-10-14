// What Faultline knows about the project it was compiled with, found by reflection at compile time.
//
// The build step hands over a table of the project's source files and sim files, each with the
// namespace the file declares. From that this builds, for every function of every source file, the
// pieces the run loop needs without knowing the function's type: whether it can be called, how to
// list the specifications for its parameters and how to make one call of it in a child process. It
// does the same for every scenario of every sim file.
//
// The table is a struct with two declarations:
//
// - `sources`: a tuple of `.{ .path = "<relative path>", .namespace = <the file as a type> }`
// - `simulations`: a tuple of `.{ .path = "<sim path>", .source = "<path of the file it belongs to>", .namespace = <the sim file as a type> }`

const std = @import("std");
const sim = @import("sim");
const auto = @import("auto.zig");
const call_mod = @import("call.zig");
const call_specs = @import("call_specs.zig");
const condition = @import("condition.zig");
const functions_mod = @import("functions.zig");
const isolate = @import("isolate.zig");
const locators = @import("locators.zig");

// How much compile-time work reflecting over a whole project may do. A project has hundreds of
// functions and every one of them is examined several times, so the default limit is far too low.
const comptime_branch_quota: u32 = 2_000_000_000;

// Whether a function is generic: it takes a type or an `anytype`, so nothing in its signature says
// what to call it with.
pub fn isGeneric(comptime Function: type) bool {
    const info = @typeInfo(Function);
    if (info != .@"fn") {
        return false;
    }
    return info.@"fn".is_generic;
}

// An expectation function as the call code runs it.
pub const ExpectationFunction = *const fn (*sim.ExpectationContext) anyerror!void;

// One expectation function of a sim file.
pub const ExpectationEntry = struct {
    // The name the function is declared with.
    name: []const u8,

    // The function.
    call: ExpectationFunction,
};

// The ways a function of the project can be used, without its type.
pub const FunctionEntry = struct {
    // The source file the function is in, relative to the project root.
    file: []const u8,

    // The name of the function, as `name` or `Owner.name` for a method.
    name: []const u8,

    // Whether the function can be called from its signature alone.
    can_call: bool,

    // The type of the first parameter nothing can build, or an empty string.
    unbuildable: []const u8,

    // Whether the function is generic: a type parameter or an `anytype` parameter, which stand for
    // nothing until a call says what, so only a scenario can call it.
    is_generic: bool,

    // Lists the specifications for the function's parameters. `arena` holds the list.
    list_specs: *const fn (arena: std.mem.Allocator, real_io: std.Io, seed: u64, conditions: []const condition.Condition) anyerror![]const call_specs.Spec,

    // Makes one call in a child process.
    attempt: *const fn (allocator: std.mem.Allocator, request: call_mod.Request, limits: isolate.Limits) anyerror!isolate.Attempt,

    // Makes one call in this process and writes the report to `out`. Only for a child that makes
    // calls for its parent: a call that crashes takes the process with it.
    run_here: *const fn (request: call_mod.Request, out: *std.Io.Writer) void,

    // The value factory a factory choice at `index` picks for the parameter at `position`, or null
    // when that parameter has none, for saying which values a call was made with.
    factory_of: *const fn (position: usize, index: usize) ?call_mod.Factory = Unreachable.factoryOf,

    // The sim files whose value factories the function is called with, in the order they are
    // searched, so a factory's namespace can be named by its file.
    factory_files: []const []const u8 = &.{},
};

// A sim file and the source file it belongs to.
pub const SimulationFile = struct {
    // The sim file, relative to the project root.
    path: []const u8,

    // The source file beside it, relative to the project root.
    source: []const u8,
};

// One scenario of a sim file.
pub const ScenarioEntry = struct {
    // The sim file the scenario is in, relative to the project root.
    file: []const u8,

    // The name the scenario is declared with.
    name: []const u8,

    // Runs the scenario in a child process.
    attempt: *const fn (allocator: std.mem.Allocator, real_io: std.Io, seed: u64, limits: isolate.Limits) anyerror!isolate.Attempt,
};

// Stands in for the listing and the call of a function that cannot be called.
const Unreachable = struct {
    fn listSpecs(_: std.mem.Allocator, _: std.Io, _: u64, _: []const condition.Condition) anyerror![]const call_specs.Spec {
        return &.{};
    }

    fn attempt(_: std.mem.Allocator, _: call_mod.Request, _: isolate.Limits) anyerror!isolate.Attempt {
        return error.CannotBeCalled;
    }

    fn runHere(_: call_mod.Request, _: *std.Io.Writer) void {}

    fn factoryOf(_: usize, _: usize) ?call_mod.Factory {
        return null;
    }
};

// The name of a sim file whose value factories are used for every file, not only the one beside it.
pub const global_sim_name = "global.sim.zig";

// What the project offers, built from the table the build step wrote.
pub fn Project(comptime files: anytype) type {
    return struct {
        // The path of every source file in the table, in order. A source file with no function
        // Faultline can call still has code paths, in the functions declared inside others.
        pub const source_files: []const []const u8 = blk: {
            var found: []const []const u8 = &.{};
            for (files.sources) |source| {
                found = found ++ [1][]const u8{source.path};
            }
            break :blk found;
        };

        // Every sim file in the table, in order, with the source file it belongs to.
        pub const simulation_files: []const SimulationFile = blk: {
            var found: []const SimulationFile = &.{};
            for (files.simulations) |simulation| {
                found = found ++ [1]SimulationFile{.{ .path = simulation.path, .source = simulation.source }};
            }
            break :blk found;
        };

        // Every function of every source file, in the order of the table.
        pub const function_entries: []const FunctionEntry = blk: {
            @setEvalBranchQuota(comptime_branch_quota);
            var found: []const FunctionEntry = &.{};
            for (files.sources) |source| {
                const expectations = expectationsFor(source.path);
                for (functions_mod.listIn(source.namespace)) |listed| {
                    found = found ++ [1]FunctionEntry{entryFor(source.path, source.namespace, listed, expectations)};
                }
            }
            break :blk found;
        };

        // Every scenario of every sim file, in the order of the table.
        pub const scenario_entries: []const ScenarioEntry = blk: {
            @setEvalBranchQuota(comptime_branch_quota);
            var found: []const ScenarioEntry = &.{};
            for (files.simulations) |simulation| {
                const expectations = expectationsIn(simulation.namespace);
                for (@typeInfo(simulation.namespace).@"struct".decls) |declaration| {
                    const value = @field(simulation.namespace, declaration.name);
                    if (isScenario(@TypeOf(value))) {
                        found = found ++ [1]ScenarioEntry{scenarioEntryFor(simulation.path, declaration.name, value, expectations)};
                    }
                }
            }
            break :blk found;
        };

        // The value factories a source file's functions are called with: those in the sim file
        // paired with it, then those in every `global.sim.zig`, which are used for every file.
        fn FactoriesFor(comptime source_path: []const u8) type {
            @setEvalBranchQuota(comptime_branch_quota);
            var found: []const type = &.{};
            for (files.simulations) |simulation| {
                if (std.mem.eql(u8, simulation.source, source_path)) {
                    found = found ++ [1]type{simulation.namespace};
                }
            }
            for (files.simulations) |simulation| {
                if (isGlobal(simulation.path) and !std.mem.eql(u8, simulation.source, source_path)) {
                    found = found ++ [1]type{simulation.namespace};
                }
            }
            return locators.Combined(found);
        }

        // The paths of the sim files `FactoriesFor(source_path)` searches, in the same order.
        fn factoryFilesFor(comptime source_path: []const u8) []const []const u8 {
            var found: []const []const u8 = &.{};
            for (files.simulations) |simulation| {
                if (std.mem.eql(u8, simulation.source, source_path)) {
                    found = found ++ [1][]const u8{simulation.path};
                }
            }
            for (files.simulations) |simulation| {
                if (isGlobal(simulation.path) and !std.mem.eql(u8, simulation.source, source_path)) {
                    found = found ++ [1][]const u8{simulation.path};
                }
            }
            return found;
        }

        // Whether the sim file at `path` holds value factories used for every file.
        fn isGlobal(comptime path: []const u8) bool {
            return std.mem.eql(u8, std.fs.path.basename(path), global_sim_name);
        }

        // The expectation functions that belong to a source file: those in the sim file paired
        // with it.
        fn expectationsFor(comptime source_path: []const u8) []const ExpectationEntry {
            for (files.simulations) |simulation| {
                if (std.mem.eql(u8, simulation.source, source_path)) {
                    return expectationsIn(simulation.namespace);
                }
            }
            return &.{};
        }

        fn entryFor(
            comptime path: []const u8,
            comptime Namespace: type,
            comptime listed: functions_mod.Found,
            comptime expectations: []const ExpectationEntry,
        ) FunctionEntry {
            const function = functions_mod.functionOf(Namespace, listed);
            const Runner = call_mod.Call(FactoriesFor(path), function, expectations);
            var buffer: [256]u8 = undefined;
            const name = std.fmt.comptimePrint("{s}", .{listed.qualifiedName(&buffer)});
            if (!Runner.can_call) {
                // A function nothing can build the arguments of is never listed or called, and the
                // code that would do so is not compiled for it, because it would not compile.
                return .{
                    .file = path,
                    .name = name,
                    .can_call = false,
                    .unbuildable = if (isGeneric(@TypeOf(function))) "" else Runner.unbuildable,
                    .is_generic = isGeneric(@TypeOf(function)),
                    .list_specs = Unreachable.listSpecs,
                    .attempt = Unreachable.attempt,
                    .run_here = Unreachable.runHere,
                };
            }
            const Wrapper = struct {
                fn attempt(allocator: std.mem.Allocator, request: call_mod.Request, limits: isolate.Limits) anyerror!isolate.Attempt {
                    return isolate.attempt(allocator, Runner.Child{ .request = request }, limits);
                }

                fn runHere(request: call_mod.Request, out: *std.Io.Writer) void {
                    (Runner.Child{ .request = request }).run(out);
                }
            };
            return .{
                .file = path,
                .name = name,
                .can_call = true,
                .unbuildable = "",
                .is_generic = false,
                .list_specs = Runner.listSpecs,
                .attempt = Wrapper.attempt,
                .run_here = Wrapper.runHere,
                .factory_of = Runner.factoryOf,
                .factory_files = factoryFilesFor(path),
            };
        }

        fn scenarioEntryFor(
            comptime path: []const u8,
            comptime name: []const u8,
            comptime function: anytype,
            comptime expectations: []const ExpectationEntry,
        ) ScenarioEntry {
            const Runner = call_mod.Scenario(name, function, expectations);
            const Wrapper = struct {
                fn attempt(allocator: std.mem.Allocator, real_io: std.Io, seed: u64, limits: isolate.Limits) anyerror!isolate.Attempt {
                    return isolate.attempt(allocator, Runner.Child{ .real_io = real_io, .seed = seed }, limits);
                }
            };
            return .{ .file = path, .name = name, .attempt = Wrapper.attempt };
        }
    };
}

// The expectation functions declared in a sim file's namespace.
fn expectationsIn(comptime Namespace: type) []const ExpectationEntry {
    @setEvalBranchQuota(comptime_branch_quota);
    var found: []const ExpectationEntry = &.{};
    for (@typeInfo(Namespace).@"struct".decls) |declaration| {
        const value = @field(Namespace, declaration.name);
        if (isExpectation(@TypeOf(value))) {
            found = found ++ [1]ExpectationEntry{.{ .name = declaration.name, .call = value }};
        }
    }
    return found;
}

// Whether a type is `fn (*sim.ExpectationContext) anyerror!void`.
pub fn isExpectation(comptime Type: type) bool {
    return hasContext(Type, sim.ExpectationContext);
}

// Whether a type is `fn (*sim.ScenarioContext) anyerror!void`.
pub fn isScenario(comptime Type: type) bool {
    return hasContext(Type, sim.ScenarioContext);
}

fn hasContext(comptime Type: type, comptime Context: type) bool {
    const info = @typeInfo(Type);
    if (info != .@"fn") {
        return false;
    }
    const signature = info.@"fn";
    if (signature.params.len != 1 or signature.is_generic or signature.is_var_args) {
        return false;
    }
    const parameter = signature.params[0].type orelse return false;
    if (parameter != *Context) {
        return false;
    }
    const returned = signature.return_type orelse return false;
    return returned == anyerror!void;
}

test {
    _ = @import("project.test.zig");
}
