# A directory the function is given

`settingsLength` takes an `std.Io.Dir` and reads a file from it. Faultline gives it the simulated current directory, so the read reaches the simulated filesystem and its failures, and never the real one.
