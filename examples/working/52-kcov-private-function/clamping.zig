// A private function that the public one below it calls. Faultline calls it directly as well, and
// kcov sees its lines run in both, so its code paths are exercised exactly as a public function's
// are.

fn clamp(value: u32) u32 {
    if (value > 100) {
        return 100;
    }
    return value;
}

pub fn clampedDouble(value: u32) u32 {
    return clamp(value) * 2;
}
