# A nested function and a private one

A function declared inside another and a private function. Faultline calls the private function directly. The nested function can only be reached through the function it is declared in, because code outside that function cannot name it. Each gets its own line in the report. The branch of the nested function that needs a long text is reached by a scenario, because the nested function only sees the text's length.
