// A switch as a statement, with a plain arm, a range arm, a multi-value arm and an else arm.

// Every kind of arm a switch can have, each with a body on a line of its own.
pub fn band(value: u8) usize {
    switch (value) {
        0 => {
            return 0;
        },
        1...9 => {
            return 1;
        },
        10, 20, 30 => {
            return 2;
        },
        else => {
            return 3;
        },
    }
}
