# A type Faultline cannot instantiate and no value factory for it

`Store` holds a function pointer, so Faultline cannot instantiate one and never calls `valueFor`. The report asks for a value factory that returns a `Store`. The example in `working/13-factory` has one.
