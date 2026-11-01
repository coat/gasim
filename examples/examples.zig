//! The examples, with what each does, as the GUI's Examples menu and the
//! web version's list them. Both read the files from where they are
//! installed, rather than embedding them.

pub const Example = struct {
    name: []const u8,
    about: []const u8,
};

pub const all = [_]Example{
    .{ .name = "hello.ga", .about = "Print a greeting" },
    .{ .name = "hello.af", .about = "Print a greeting, in arrayForth 3" },
    .{ .name = "hello.cf", .about = "Print a greeting, in colorForth" },
    .{ .name = "echo.ga", .about = "Copy console input to the console" },
    .{ .name = "echo.af", .about = "Copy console input, in arrayForth 3" },
    .{ .name = "echo.cf", .about = "Copy console input, in colorForth" },
    .{ .name = "upcase.ga", .about = "Upper-case console input" },
    .{ .name = "upcase.af", .about = "Upper-case console input, in arrayForth 3" },
    .{ .name = "upcase.cf", .about = "Upper-case console input, in colorForth" },
    .{ .name = "alphabet.cf", .about = "Print the alphabet" },
    .{ .name = "variables.cf", .about = "Count with a variable" },
    .{ .name = "multiply.cf", .about = "Multiply with +*" },
};
