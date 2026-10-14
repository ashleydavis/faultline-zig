# A crash that only a failure shows

`firstWord` says an allocation cannot fail. Faultline makes the allocation fail, the function crashes, and the report names it with a command that repeats exactly that call. The smoke test runs the command twice and checks it crashes the same way each time.
