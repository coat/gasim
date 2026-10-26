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

// and the same in arrayForth 3

test "hello.af" {
    try expectArrayForthOutput(@embedFile("hello.af"), "", "Hello, world!\n");
}

test "echo.af" {
    try expectArrayForthOutput(@embedFile("echo.af"), "echo me\n", "echo me\n");
}

test "upcase.af" {
    try expectArrayForthOutput(@embedFile("upcase.af"), "Hello, World! az{`@[\n", "HELLO, WORLD! AZ{`@[\n");
}

// and in colorForth

test "hello.cf" {
    try expectColorForthOutput(@embedFile("hello.cf"), "", "Hello, world!\n");
}

test "echo.cf" {
    try expectColorForthOutput(@embedFile("echo.cf"), "echo me\n", "echo me\n");
}

test "upcase.cf" {
    try expectColorForthOutput(@embedFile("upcase.cf"), "Hello, World! az{`@[\n", "HELLO, WORLD! AZ{`@[\n");
}

const expectOutput = @import("gasim").Chip.expectOutput;
const expectArrayForthOutput = @import("gasim").Chip.expectArrayForthOutput;
const expectColorForthOutput = @import("gasim").Chip.expectColorForthOutput;
