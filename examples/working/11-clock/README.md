# A clock that does not move on its own

A function whose answer depends on time, reached with clocks that stand still, jump forward and jump backward past where they started. The clock is a plain struct, so Faultline builds it from its type and tries its boundary values, and no scenario or value factory is written. The same calls reached an overflow in the first version of the subtraction, which is why it saturates.
