# An expectation function that fails after a failure

`aNoteEndsItsLastLine` is checked after every call of `save`. It holds when every call goes right and not when Faultline makes the second write fail, which leaves a last line with no end. The report names the call and the failure with a command that repeats it.
