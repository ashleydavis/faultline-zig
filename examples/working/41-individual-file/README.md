# Fault testing one file

`-Dfile=counting.zig`, given through `run-flags.txt`, calls the functions in that file only and counts only its code paths. `pending.zig` still has work outstanding, so a run over the whole project would exit 1, but this run exits 0.
