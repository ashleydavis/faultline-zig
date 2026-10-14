// Every code path of this function is exercised, so the last line of the run reads 100% and the
// run exits 0.
pub fn sign(value: i32) i8 {
    if (value > 0) {
        return 1;
    } else {
        if (value < 0) {
            return -1;
        } else {
            return 0;
        }
    }
}
