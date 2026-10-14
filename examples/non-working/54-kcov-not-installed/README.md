# A run without kcov

`-Dkcov=/no/such/kcov` names a kcov that is not there. Faultline says so in one sentence and exits 1, because coverage comes from kcov only.
