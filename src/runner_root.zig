// The root of the program Faultline builds for a project. The build step copies this file into the
// build's cache beside copies of the project's own files and a table of them (`flt_files.zig`),
// and compiles it as the program `zig build flt` runs.
//
// It holds no logic: it hands the table to Faultline's own code, which does everything else.

const faultline = @import("faultline");
const files = @import("flt_files.zig");

pub const panic = faultline.panic;

pub const main = faultline.mainFor(faultline.Project(files));
