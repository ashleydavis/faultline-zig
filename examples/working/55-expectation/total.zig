// Code that a scenario exercises and then states expectations about.

// A running total, so a scenario has something to expect a value from after it calls `add`.
pub const Total = struct {
    // The amount added so far.
    amount: i64 = 0,

    // Adds an amount to the total. An amount of zero leaves it alone.
    pub fn add(self: *Total, amount: i64) void {
        if (amount == 0) {
            return;
        }
        self.amount += amount;
    }
};
