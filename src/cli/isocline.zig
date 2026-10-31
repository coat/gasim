//! The isocline functions the repl uses for line editing, declared by hand.
//! isocline is MIT licensed, by Daan Leijen: https://github.com/daanx/isocline

pub const CompletionEnv = opaque {};
pub const Completer = fn (cenv: *CompletionEnv, prefix: [*:0]const u8) callconv(.c) void;

pub extern fn ic_readline(prompt_text: [*:0]const u8) ?[*:0]u8;
pub extern fn ic_free(p: ?*anyopaque) void;
pub extern fn ic_set_history(fname: ?[*:0]const u8, max_entries: c_long) void;
pub extern fn ic_set_default_completer(completer: *const Completer, arg: ?*anyopaque) void;
pub extern fn ic_completion_arg(cenv: *const CompletionEnv) ?*anyopaque;
pub extern fn ic_add_completion_prim(
    cenv: *CompletionEnv,
    completion: [*:0]const u8,
    display: ?[*:0]const u8,
    help: ?[*:0]const u8,
    delete_before: c_long,
    delete_after: c_long,
) bool;
pub extern fn ic_set_prompt_marker(prompt_marker: ?[*:0]const u8, continuation_prompt_marker: ?[*:0]const u8) void;
pub extern fn ic_enable_multiline(enable: bool) bool;
pub extern fn ic_enable_hint(enable: bool) bool;
