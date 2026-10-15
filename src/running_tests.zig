// The test root for what runs calls: the child process a call runs in, the token that replays a
// call, the call itself and the loop that drives them. It sits in `src/` and not in `src/framework/`
// because the worker imports the condition reader from `src/cmd/`, and Zig refuses an import that
// leaves the directory of the module's root file.

test {
    _ = @import("framework/isolate.zig");
    _ = @import("framework/wire.zig");
    _ = @import("framework/args.zig");
    _ = @import("framework/functions.zig");
    _ = @import("framework/plan.zig");
    _ = @import("framework/session.zig");
    _ = @import("framework/locators.zig");
    _ = @import("framework/call.zig");
    _ = @import("framework/explore.zig");
    _ = @import("framework/project.zig");
    _ = @import("framework/worker.zig");
    _ = @import("framework/replay.zig");
    _ = @import("framework/checklist.zig");
    _ = @import("framework/selection.zig");
    _ = @import("framework/driver.zig");
    _ = @import("framework/results_cache.zig");
    _ = @import("framework/crash_store.zig");
    _ = @import("framework/crash_view.zig");
    _ = @import("framework/report.zig");
}
