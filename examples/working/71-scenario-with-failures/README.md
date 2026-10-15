# A scenario that has failures injected

Reading a file that exists needs the file written first, which a value factory does not do, so a scenario writes it and then calls the code. Faultline runs the scenario once with no failure and then once for each failure at each place that run reached, so the branch for a file that opens but cannot be read is exercised without a scenario of its own.
