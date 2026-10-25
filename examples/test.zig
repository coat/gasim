//! Runs each example and checks its console output

test "hello" {
    try expectOutput(@embedFile("hello.ga"), "", "Hello, world!\n");
}

test "echo" {
    try expectOutput(@embedFile("echo.ga"), "echo me\n", "echo me\n");
}

test "upcase" {
    try expectOutput(@embedFile("upcase.ga"), "Hello, World! az{`@[\n", "HELLO, WORLD! AZ{`@[\n");
}

const expectOutput = @import("gasim").Chip.expectOutput;
