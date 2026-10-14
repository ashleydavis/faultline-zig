# A file that imports the framework is not tested

`check_parsing.zig` imports `sim`, which makes it harness code. Faultline skips it, so the report lists `parsing.zig` only. The file says so itself, so no list of harness files exists to go stale.
