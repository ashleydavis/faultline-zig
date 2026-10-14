# A file that is not there, and one that is

A call Faultline makes on its own meets an empty filesystem, so `settings.sim.zig` has scenarios that make a file for the function to read. The code paths for a file that is missing, one that is empty and one that holds a setting are all exercised, the first by Faultline's own calls and the rest by the scenarios.
