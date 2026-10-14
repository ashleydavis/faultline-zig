# Expectations in a scenario

A scenario states what must be true after the calls it made: `try context.expect(@src(), condition, "what you expected")`. The sentence is what the report prints when the condition is false. Both expectations here hold, so the report prints neither.
