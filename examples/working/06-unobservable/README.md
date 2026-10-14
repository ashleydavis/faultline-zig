# Code that is not a code path

`and`, `or` and `try` are not code paths in Faultline. A function that uses them has no code path that a call can miss, so it reaches 100% by being called, and nothing about them appears on the checklist or in the percentage.
