// The module the program Faultline builds for a project is made of. It sits in `src/` so the files
// under `src/framework/` and `src/cmd/` can import each other: Zig refuses an import that leaves
// the directory of the module's root file.
//
// The static root file of that program imports this module as `faultline` and calls `mainFor`.

pub const driver = @import("framework/driver.zig");
pub const project = @import("framework/project.zig");

// The `main` for a project, given the table of its files: `project.Project(files)`.
pub const mainFor = driver.mainFor;

// The project of a table of files.
pub const Project = project.Project;

// The panic handler the program declares in its root.
pub const panic = driver.panic;
