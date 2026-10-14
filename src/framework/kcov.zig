// The test root for coverage from kcov: reading kcov's output, turning source into code paths
// and ticking them, then running a worker under kcov.

test {
    _ = @import("covered_lines.zig");
    _ = @import("coverage.zig");
    _ = @import("kcov_run.zig");
}
