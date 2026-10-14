# A value factory with state

The value factory for `Feed` is a function on a struct, so the struct can keep state between calls. Each feed it builds holds one more number than the one before, so Faultline calls `total` with an empty feed and with feeds that are not empty.
