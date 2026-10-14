# A branch on the line of its condition

`isLarge` puts the body of its `if` on the same line as the condition. kcov reports whether a line ran and not which part of it, so it cannot tell whether the body ran. Faultline leaves that code path out of the count and does not list it. Put the body on its own line and Faultline counts it.
