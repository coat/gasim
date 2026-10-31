//! The examples, embedded, with what each does, as the GUI's Examples menu
//! and the web version's list them

pub const Example = struct {
    name: []const u8,
    about: []const u8,
    bytes: []const u8,
};

pub const all = [_]Example{
    .{ .name = "hello.ga", .about = "Print a greeting", .bytes = @embedFile("hello.ga") },
    .{ .name = "hello.af", .about = "Print a greeting, in arrayForth 3", .bytes = @embedFile("hello.af") },
    .{ .name = "hello.cf", .about = "Print a greeting, in colorForth", .bytes = @embedFile("hello.cf") },
    .{ .name = "echo.ga", .about = "Copy console input to the console", .bytes = @embedFile("echo.ga") },
    .{ .name = "echo.af", .about = "Copy console input, in arrayForth 3", .bytes = @embedFile("echo.af") },
    .{ .name = "echo.cf", .about = "Copy console input, in colorForth", .bytes = @embedFile("echo.cf") },
    .{ .name = "upcase.ga", .about = "Upper-case console input", .bytes = @embedFile("upcase.ga") },
    .{ .name = "upcase.af", .about = "Upper-case console input, in arrayForth 3", .bytes = @embedFile("upcase.af") },
    .{ .name = "upcase.cf", .about = "Upper-case console input, in colorForth", .bytes = @embedFile("upcase.cf") },
    .{ .name = "alphabet.cf", .about = "Print the alphabet", .bytes = @embedFile("alphabet.cf") },
    .{ .name = "variables.cf", .about = "Count with a variable", .bytes = @embedFile("variables.cf") },
    .{ .name = "multiply.cf", .about = "Multiply with +*", .bytes = @embedFile("multiply.cf") },
};
