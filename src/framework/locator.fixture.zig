// A file used only by the locator's tests, to show a whole imported file is searched the same way
// as a struct written in place.

// A standalone factory.
pub fn seven() u16 {
    return 7;
}

// A struct factory with state.
pub const Ticker = struct {
    // How many values have been handed out.
    handed_out: u16 = 0,

    // The next number.
    pub fn next(self: *Ticker) u16 {
        self.handed_out += 1;
        return self.handed_out;
    }
};
