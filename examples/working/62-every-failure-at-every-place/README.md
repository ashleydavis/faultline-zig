# Every failure at every place

`saveAndReadBack` writes a file and reads it back, with an error branch for each step. Faultline finds each place the function uses a file and injects every failure that can happen there, one at a time, so the report reaches every code path without a scenario.
