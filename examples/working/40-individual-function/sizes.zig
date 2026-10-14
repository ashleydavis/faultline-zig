// Three size checks. The run is narrowed to `middle`, so only its code paths are counted.

// Whether the value is below the first threshold. It is here so the file holds more than the one
// function the run is asked for.
pub fn small(value: u32) bool {
    if (value < 10) {
        return true;
    } else {
        return false;
    }
}

// The function the run is narrowed to.
pub fn middle(value: u32) bool {
    if (value < 10) {
        return false;
    }
    if (value > 100) {
        return false;
    }
    return true;
}

// Whether the value is above the second threshold. It is here for the same reason as `small`.
pub fn large(value: u32) bool {
    if (value > 100) {
        return true;
    } else {
        return false;
    }
}
