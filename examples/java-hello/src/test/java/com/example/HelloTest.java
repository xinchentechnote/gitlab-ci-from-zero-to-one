package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class HelloTest {
    @Test
    void greetNamesTheCaller() {
        assertEquals("hello, java!", Hello.greet("java"));
    }
}
