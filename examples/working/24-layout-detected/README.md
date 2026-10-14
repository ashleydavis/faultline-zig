# Code found wherever it is

This project keeps its code under `source` and `build.zig` says nothing about it. With no `.include`, Faultline searches the whole project for Zig files and finds it. Example 22 shows `.include` narrowing the search.
