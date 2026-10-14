# A private function covered by lines

`clamp` is private and Faultline never calls it directly. It is reached through `clampedDouble`, and kcov records its lines running there, so both of its sides are exercised.
