# A branch that turns on a string in the source

The condition compares against `"OK"`, which no boundary value of a string equals. Faultline reads the string from the condition and calls the function with it, so the true side is exercised without a value factory or a scenario.
