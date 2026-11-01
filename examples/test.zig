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

test "uart" {
    var chip: Chip = try .init(std.testing.allocator, .ga144);
    defer chip.deinit(std.testing.allocator);
    var programs: [1]gasim.assembler.Program = undefined;
    var diagnostic: gasim.assembler.Diagnostic = .{};
    for (try gasim.assembler.assembleNodes(@embedFile("uart.ga"), &programs, &diagnostic)) |program| try chip.load(program);

    var buffer: [32]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var uart: gasim.Uart = .init(921600, &output);
    try chip.attachUart(&uart, 708);
    try chip.run();
    try std.testing.expectEqualStrings("Hello, world!\n", output.buffered());
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

// and ideas from AshleyF's posts on the F18, in colorForth

test "alphabet.cf" {
    try expectColorForthOutput(@embedFile("alphabet.cf"), "", "abcdefghijklmnopqrstuvwxyz\n");
}

test "variables.cf" {
    try expectColorForthOutput(@embedFile("variables.cf"), "", "0123456789\n");
}

test "multiply.cf" {
    try expectColorForthOutput(@embedFile("multiply.cf"), "", "bad\nfe01\n");
}

const gasim = @import("gasim");
const Chip = gasim.Chip;
const std = @import("std");
const expectOutput = @import("gasim").Chip.expectOutput;
const expectArrayForthOutput = @import("gasim").Chip.expectArrayForthOutput;
const expectColorForthOutput = @import("gasim").Chip.expectColorForthOutput;
