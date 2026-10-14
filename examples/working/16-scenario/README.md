# A scenario for a code path nothing else reaches

Taking a lock that is already held needs two calls in order, which no single call can produce. A scenario makes the two calls and states with `context.expect` what must be true after them.
