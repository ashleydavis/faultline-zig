// Makes one call of one function in the simulated world and writes down what came of it.
//
// A call is a function, a specification of the values for its parameters, the failures to inject
// and the run's seed. The call runs in a child process (see `isolate.zig`): it begins a fresh
// session, builds the arguments, calls the function, notes what it returned, notes every place a
// failure could have happened, then runs the expectation functions that belong to the function's
// source file and writes the report for the parent to read.

const std = @import("std");
const sim = @import("sim");
const auto = @import("auto.zig");
const call_specs = @import("call_specs.zig");
const condition = @import("condition.zig");
const injector_mod = @import("injector.zig");
const isolate = @import("isolate.zig");
const session_mod = @import("session.zig");
const wire = @import("wire.zig");

// What a call is made with.
pub const Request = struct {
    // The seed every generator starts from.
    seed: u64,

    // One choice per parameter of the function.
    spec: call_specs.Spec,

    // The failures to inject. Empty for a call that injects none.
    plan: []const injector_mod.Injection,

    // The conditions read from the function, whose values are the condition choices. Empty when
    // the condition choices are not wanted.
    conditions: []const condition.Condition,

    // The real `Io` the simulated world is layered over.
    real_io: std.Io,
};

// How much memory building the arguments of one call may use before the call is taken to be
// running away. Arguments are small, so this only catches a defect in a value factory.
const argument_arena_limit_bytes = 256 * 1024 * 1024;

// What can be done with one function of the project.
//
// `Locator` finds value factories, `function` is the function and `expectations` is a tuple of the
// expectation functions that run after every call of it, each a struct with a `name` and a `call`.
// Writes each argument of a call to the error stream, one line each as `argument <position>:
// <value>`, for the replay that shows where a crash happened to say what the call was made with.
// A line is cut at a length a person reads at a glance, because a value can be a whole structure.
pub fn writeArguments(arguments: anytype) void {
    inline for (arguments, 0..) |argument, position| {
        // Long enough for a string or a number in full and the start of anything larger.
        var buffer: [200]u8 = undefined;
        var line = std.Io.Writer.fixed(&buffer);
        line.print("argument {d}: ", .{position}) catch {};
        writeValue(&line, argument) catch {
            line.end = buffer.len - "...".len;
            line.writeAll("...") catch {};
        };
        isolate.writeAll(2, line.buffered());
        isolate.writeAll(2, "\n");
    }
}

// Writes one argument the way a person reads it: a string in quotes, the values Faultline itself
// supplies by what they are, and anything else as Zig formats it.
pub fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (T == std.mem.Allocator) {
        return writer.writeAll("the allocator Faultline supplies");
    }
    if (T == std.Io) {
        return writer.writeAll("the simulated filesystem and network Faultline supplies");
    }
    if (T == *std.Io.Writer) {
        return writer.writeAll("the writer Faultline supplies");
    }
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) {
                return writer.print("\"{f}\"", .{std.zig.fmtString(value)});
            }
        },
        // Written field by field, so a string inside it is written as a string too.
        .@"struct" => |info| {
            if (!info.is_tuple) {
                try writer.writeAll(".{");
                inline for (info.fields, 0..) |field, index| {
                    try writer.print("{s} .{s} = ", .{ if (index == 0) "" else ",", field.name });
                    try writeValue(writer, @field(value, field.name));
                }
                return writer.writeAll(" }");
            }
        },
        .optional => {
            if (value) |present| {
                return writeValue(writer, present);
            }
            return writer.writeAll("null");
        },
        else => {},
    }
    return writer.print("{any}", .{value});
}

// A value factory a call was made with: its name and which of the locator's namespaces holds it.
pub const Factory = struct {
    // The name the sim file declares it with.
    name: []const u8,

    // The namespace's position among those the locator searches, counting from zero.
    namespace: usize,
};

pub fn Call(comptime Locator: type, comptime function: anytype, comptime expectations: anytype) type {
    const Function = @TypeOf(function);
    const Context = auto.Context(Locator);

    return struct {
        // Whether the function can be called from its signature alone.
        pub const can_call = auto.canExercise(Function, Locator);

        // The name of the type of the first parameter nothing can build, or an empty string.
        pub const unbuildable = if (auto.firstUnbuildableParameter(Function, Locator)) |T| @typeName(T) else "";

        // The value factory a factory choice at `index` picks for the parameter at `position`: its
        // name and which of the locator's namespaces holds it. Null when that parameter has no such
        // factory.
        pub fn factoryOf(position: usize, index: usize) ?Factory {
            inline for (@typeInfo(Function).@"fn".params, 0..) |param, at| {
                if (position == at) {
                    const Parameter = param.type orelse return null;
                    if (comptime !Locator.canMake(Parameter)) {
                        return null;
                    }
                    return .{
                        .name = Locator.nameOf(Parameter, index) orelse return null,
                        .namespace = Locator.namespaceOf(Parameter, index) orelse return null,
                    };
                }
            }
            return null;
        }

        // The finite list of specifications for the function. `arena` holds the list. Run in the
        // process that drives the calls, so values are never built here, only counted.
        pub fn listSpecs(
            arena: std.mem.Allocator,
            real_io: std.Io,
            seed: u64,
            conditions: []const condition.Condition,
        ) ![]const call_specs.Spec {
            var locator = Locator.init();
            var prng = std.Random.Xoshiro256.init(seed);
            var scratch: [64]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&scratch);
            const ctx: Context = .{
                .locator = &locator,
                .arena = arena,
                .call_allocator = std.heap.page_allocator,
                .io = real_io,
                .random = prng.random(),
                .writer = &writer,
                .seed = seed,
                .conditions = conditions,
            };
            return auto.listCallSpecs(Function, Locator, ctx);
        }

        // What the child process runs for a call.
        pub const Child = struct {
            request: Request,

            // Runs the call and writes the report to `out`.
            pub fn run(self: Child, out: *std.Io.Writer) void {
                runCall(self.request, out);
            }
        };

        fn runCall(request: Request, out: *std.Io.Writer) void {
            var session: session_mod.Session = .{ .injector = undefined };
            session.begin(std.heap.page_allocator, request.real_io, request.plan, request.seed) catch {
                writeResult(out, .{ .errored = "TheWorldCouldNotBeBegun" }, &.{});
                return;
            };
            // A child can make many calls, so what one call took is given back when it is done.
            defer session.end();

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var locator = Locator.init();
            const ctx: Context = .{
                .locator = &locator,
                .arena = arena.allocator(),
                .call_allocator = session.allocator(),
                .io = session.io,
                .random = session.random(),
                .writer = &session.writer.interface,
                .seed = request.seed,
                .conditions = request.conditions,
            };

            const arguments = auto.buildArguments(Function, Locator, ctx, request.spec) catch |err| {
                writeResult(out, .{ .errored = @errorName(err) }, &.{});
                return;
            };
            // Building the arguments may have used the allocator or the io. Those calls are not
            // the function's, so the injector starts counting from here.
            session.injector.reset();
            if (isolate.is_trace_wanted) {
                writeArguments(arguments);
            }

            const outcome: wire.Result = blk: {
                const result = @call(.auto, function, arguments);
                if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
                    if (result) |_| {
                        break :blk .returned;
                    } else |err| {
                        break :blk .{ .errored = @errorName(err) };
                    }
                }
                break :blk .returned;
            };

            // The places are copied before the expectation functions run, because they use the
            // world too and their calls are not places the function under test reached.
            const reached = std.heap.page_allocator.dupe(injector_mod.Place, session.places()) catch &.{};
            defer {
                if (reached.len != 0) {
                    std.heap.page_allocator.free(reached);
                }
            }
            session.injector.plan = &.{};

            const final = runExpectations(&session, expectations, outcome);
            writeResult(out, final, reached);
        }

        fn writeResult(out: *std.Io.Writer, result: wire.Result, places: []const injector_mod.Place) void {
            wire.write(out, result, places) catch {};
        }
    };
}

// Runs every expectation function after a call or a scenario. The first one that is false replaces
// the outcome, because an expectation that does not hold is the thing to report. `expectations` is
// a tuple of structs with a `name` and a `call`.
fn runExpectations(session: *session_mod.Session, comptime expectations: anytype, outcome: wire.Result) wire.Result {
    inline for (expectations) |expectation| {
        var context: sim.ExpectationContext = .{
            .io = session.io,
            .allocator = std.heap.page_allocator,
        };
        expectation.call(&context) catch |err| {
            if (context.failed) |failed| {
                return .{ .expectation_failed = .{
                    .function = expectation.name,
                    .file = failed.file,
                    .line = failed.line,
                    .text = failed.text,
                } };
            }
            return .{ .expectation_failed = .{
                .function = expectation.name,
                .file = "",
                .line = 0,
                .text = @errorName(err),
            } };
        };
    }
    return outcome;
}

// What the child process runs for one scenario.
//
// A scenario runs in a world with no failures unless it asks for one, and its own expectations
// decide whether it passed. The expectation functions of its sim file run after it.
pub fn Scenario(comptime name: []const u8, comptime function: anytype, comptime expectations: anytype) type {
    return struct {
        pub const Child = struct {
            real_io: std.Io,
            seed: u64,

            pub fn run(self: Child, out: *std.Io.Writer) void {
                var session: session_mod.Session = .{ .injector = undefined };
                session.begin(std.heap.page_allocator, self.real_io, &.{}, self.seed) catch {
                    wire.write(out, .{ .errored = "TheWorldCouldNotBeBegun" }, &.{}) catch {};
                    return;
                };
                var faults: sim.Faults = .{};
                var context: sim.ScenarioContext = .{
                    .faults = &faults,
                    .io = session.io,
                    .allocator = session.allocator(),
                };

                var outcome: wire.Result = .returned;
                function(&context) catch |err| {
                    if (context.failed) |failed| {
                        outcome = .{ .expectation_failed = .{
                            .function = name,
                            .file = failed.file,
                            .line = failed.line,
                            .text = failed.text,
                        } };
                    } else {
                        outcome = .{ .errored = @errorName(err) };
                    }
                };

                session.injector.plan = &.{};
                const final = runExpectations(&session, expectations, outcome);
                wire.write(out, final, &.{}) catch {};
            }
        };
    };
}

test {
    _ = @import("call.test.zig");
}
