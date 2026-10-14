# An expectation function after every call

`onlyTheNoteExists` is an expectation function. Faultline runs it after every call of `save`, including the calls where it injected a failure, and the run fails if it is ever false. It holds here, so the report shows nothing about it.
