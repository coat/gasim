//! What the web version will use of the core, built for wasm32-freestanding
//! by `zig build wasm`, so that I/O or libc creeping into the core breaks
//! the build. Each export reaches one part, as nothing is compiled that is
//! not reached. See docs/WEB.md; the web's own exports will replace this.
const std = @import("std");
const gasim = @import("gasim");
const Chip = gasim.Chip;
const Console = gasim.Console;
const Editor = gasim.Editor;
const arrayforth = gasim.arrayforth;
const ga144 = gasim.ga144;

const gpa = std.heap.wasm_allocator;

var chip: Chip = undefined;
var console: Console = undefined;
var output: [256]u8 = undefined;
var writer: std.Io.Writer = .fixed(&output);

export fn initChip() bool {
    chip = Chip.init(gpa, .ga144) catch return false;
    console = .{ .output = &writer };
    chip.attachConsole(&console, 0, .up) catch return false;
    return true;
}

export fn loadRom(text: [*]const u8, len: usize) bool {
    var roms: [144]ga144.NodeRom = undefined;
    const parsed = ga144.parseRom(text[0..len], &roms) catch return false;
    chip.loadRom(parsed) catch return false;
    return true;
}

export fn give(bytes: [*]const u8, len: usize) usize {
    return console.give(bytes[0..len]);
}

export fn run(budget: usize) bool {
    for (0..budget) |_| if (!(chip.advance() catch return false)) return false;
    return !console.wantsInput();
}

var programs: [144]arrayforth.Program = undefined;
var descriptors: [144]gasim.boot.Descriptor = undefined;
var diagnostic: arrayforth.Diagnostic = .{};

export fn interpret(source: [*]const u8, len: usize) usize {
    var session: arrayforth.Session = .init(&programs, &descriptors, &diagnostic, .{ .out = &writer, .chip = &chip });
    session.interpret(source[0..len]) catch return 0;
    return session.stack().len;
}

var editor: Editor = undefined;
var blocks: [4 * gasim.colorforth.block_size]u8 = @splat(0);

export fn editKey(c: u8) bool {
    editor.open(&blocks, 4);
    _ = editor.key(.char(c)) catch |err| return Editor.describe(err).len > 0;
    editor.moveTo(0) catch return false;
    return editor.contents().len > 0;
}
