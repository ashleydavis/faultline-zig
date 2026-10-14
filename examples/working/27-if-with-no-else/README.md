# An if with no else

When the body of an `if` with no `else` does not leave the function, no line proves the false side ran, so Faultline does not count that side and does not list it. When the body returns, the line after the `if` proves the false side, so both sides are counted.
