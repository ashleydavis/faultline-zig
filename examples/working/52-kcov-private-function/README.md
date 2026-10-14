# A private function called directly

`clamp` is private and Faultline calls it directly, as it does `clampedDouble`, which calls it too. kcov records its lines running in both, so both of its sides are exercised.
