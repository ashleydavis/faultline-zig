# An if with a capture

`if (x) |value| else` over an optional, `if (x) |value| else |e|` over an error union, and an `orelse` written as a block. Each side is on a line of its own, so kcov reports which side ran and Faultline reaches them with null and not null, and with an argument that makes the call fail and one that makes it succeed.
