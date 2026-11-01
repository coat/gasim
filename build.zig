const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coverage = b.option(bool, "coverage", "Generate a coverage report with kcov") orelse false;
    const fuzz = b.option(bool, "fuzz", "Build the tests with LLVM, which --fuzz needs for its coverage") orelse false;
    const isocline = b.option(bool, "isocline", "Edit lines at the aforth prompt with isocline, which links libc (default true)") orelse true;
    const strip = b.option(bool, "strip", "Leave out debug info, as the releases do");
    // only with it are dvui, and SDL3's source, fetched
    const with_gui = b.option(bool, "gui", "Build the GUI, gasim-gui, too, with dvui and SDL3") orelse false;

    const mod = b.addModule("gasim", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // only the executable needs a terminal UI, not the gasim module
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(bool, "isocline", isocline);

    const exe = b.addExecutable(.{
        .name = "gasim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            // isocline is C, and only the executable uses it
            .link_libc = if (isocline) true else null,
            .imports = &.{
                .{ .name = "gasim", .module = mod },
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    if (isocline) if (b.lazyDependency("isocline", .{})) |dependency| {
        exe.root_module.addCSourceFile(.{ .file = dependency.path("src/isocline.c"), .flags = &.{"-std=c99"} });
        exe.root_module.addIncludePath(dependency.path("include"));
    };

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run gasim");
    run_step.dependOn(&run_cmd.step);

    // the web version: the core as a wasm32-freestanding module, with no
    // I/O and no libc, and web/, in zig-out/web. Debug builds are slow, so it
    // is ReleaseSmall unless another release mode is asked for.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_optimize: std.lang.Optimize = if (optimize == .debug) .small else optimize;
    const wasm = b.addExecutable(.{
        .name = "gasim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/main.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{.{ .name = "gasim", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = wasm_target,
                .optimize = wasm_optimize,
            }) }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // arrayForth 3's interpreter is kept on the stack as it assembles, such as
    // the ROM, which overflows wasm's default of 1 MiB
    wasm.stack_size = 8 * 1024 * 1024;
    const wasm_step = b.step("wasm", "Build the core for wasm32-freestanding, as the web version uses it");
    wasm_step.dependOn(&wasm.step);

    const web_step = b.step("web", "Build the web version into zig-out/web");
    web_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "web",
        .exclude_extensions = &.{".test.js"},
    }).step);
    web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    web_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("examples"),
        .install_dir = .prefix,
        .install_subdir = "web/examples",
        .include_extensions = &.{ ".ga", ".af", ".cf" },
    }).step);
    // the ROM is GreenArrays', and not in the repository: the page looks for
    // ga144.txt beside it, and otherwise asks for one
    if (b.option([]const u8, "rom", "A ROM dump to serve with the web version as ga144.txt")) |rom|
        web_step.dependOn(&b.addInstallFileWithDir(.{ .cwd_relative = rom }, .{ .custom = "web" }, "ga144.txt").step);

    // Deno runs the page's modules as they are, and the wasm too
    const test_web = b.addSystemCommand(&.{ "deno", "test", "--allow-read" });
    test_web.addPrefixedFileArg("--config=", b.path("deno.json"));
    test_web.addDirectoryArg(b.path("web"));
    test_web.addArg("--");
    test_web.addArtifactArg(wasm);
    const test_web_step = b.step("test-web", "Run the web version's tests, with Deno");
    test_web_step.dependOn(&test_web.step);

    // the GUI: the web version's Sim drawn with dvui in an SDL3 window,
    // installed beside gasim with -Dgui. Only an option can say so, not a
    // step, as dvui is fetched as the build is configured, before the steps
    // asked for are known. On Linux it links the system's SDL3, as SDL3 built from source
    // finds no display on NixOS; -fno-sys=sdl3 builds it anyway. Declared
    // here, before dvui asks, so dvui gets this default.
    _ = b.systemIntegrationOption("sdl3", .{ .default = target.result.os.tag == .linux });
    const run_gui_step = b.step("run-gui", "Run the GUI (with -Dgui)");
    // its tests open a hidden window, so they need a display, and are not
    // part of `test`
    const test_gui_step = b.step("test-gui", "Run the GUI's tests, in a hidden window (with -Dgui)");
    const gui_options = b.addOptions();
    gui_options.addOption(?[]const u8, "gui_images", b.option([]const u8, "gui-images", "A directory for test-gui to save what it draws in, as PNGs"));
    if (!with_gui) {
        const fail = b.addFail("the GUI is built with -Dgui, which fetches dvui and SDL3");
        run_gui_step.dependOn(&fail.step);
        test_gui_step.dependOn(&fail.step);
    } else if (b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 })) |dvui| {
        // the toolbar's icons, the web version's SVGs as the TinyVG dvui
        // draws, each a constant of icons.zig named in snake_case. dvui's
        // svgPathToTvgPath assumes its lazy svg2tvg is fetched, so it is
        // asked for first, and the build configured again once it is.
        const icons = b.addWriteFiles();
        var icons_zig: []const u8 = "";
        if (dvui.builder.lazyDependency("svg2tvg", .{ .optimize = .ReleaseFast, .target = dvui.builder.graph.host }) != null)
            if (b.lazyImport(@This(), "dvui")) |dvui_build| for (gui_icons) |name| {
                const tvg = dvui_build.svgPathToTvgPath(dvui.builder, b.path(b.fmt("web/icons/{s}.svg", .{name})));
                _ = icons.addCopyFile(tvg, b.fmt("{s}.tvg", .{name}));
                const constant = std.mem.replaceOwned(u8, b.allocator, name, "-", "_") catch @panic("OOM");
                icons_zig = b.fmt("{s}pub const {s} = @embedFile(\"{s}.tvg\");\n", .{ icons_zig, constant, name });
            };
        const gui_imports: []const std.Build.Module.Import = &.{
            .{ .name = "gasim", .module = mod },
            .{ .name = "Sim", .module = b.createModule(.{
                .root_source_file = b.path("src/web/Sim.zig"),
                .imports = &.{.{ .name = "gasim", .module = mod }},
            }) },
            .{ .name = "dvui", .module = dvui.module("dvui_sdl3") },
            .{ .name = "build_options", .module = gui_options.createModule() },
            // embedded, for its Examples menu
            .{ .name = "examples", .module = b.createModule(.{ .root_source_file = b.path("examples/examples.zig") }) },
            .{ .name = "icons", .module = b.createModule(.{ .root_source_file = icons.add("icons.zig", icons_zig) }) },
        };
        const gui_mod = b.createModule(.{
            .root_source_file = b.path("src/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = gui_imports,
        });
        const gui = b.addExecutable(.{ .name = "gasim-gui", .root_module = gui_mod });
        const install_gui = b.addInstallArtifact(gui, .{});
        b.getInstallStep().dependOn(&install_gui.step);
        const run_gui = b.addRunArtifact(gui);
        run_gui.step.dependOn(&install_gui.step);
        run_gui.addPassthruArgs();
        run_gui_step.dependOn(&run_gui.step);

        const gui_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui/ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = gui_imports,
        }) });
        test_gui_step.dependOn(&b.addRunArtifact(gui_tests).step);
        addMacSdk(b, &.{ gui_mod, gui_tests.root_module }, target.result);
    }

    const serve = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve/main.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const serve_cmd = b.addRunArtifact(serve);
    serve_cmd.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "web" } });
    serve_cmd.addPassthruArgs();
    serve_cmd.step.dependOn(web_step);
    const serve_step = b.step("serve", "Build the web version and serve it on http://localhost:8080 (-- PORT for another)");
    serve_step.dependOn(&serve_cmd.step);

    // ga-tools (github.com/mschuldt/ga-tools) compiles the programs, and
    // node 708 boots from ROM, so neither CI nor `test` runs this
    const ga = b.option([]const u8, "ga", "ga-tools' ga command, for the ga-tools step (default: ga on PATH)") orelse
        b.findProgram(.{ .names = &.{"ga"} });
    const ga_rom = b.option([]const u8, "ga-rom", "ROM for the ga-tools step: arrayForth 3's disk or a dump (default: rom/pFDISK.blk, or the ROM gasim saved)") orelse "";
    const ga_tools_step = b.step("ga-tools", "Boot node 708 with streams ga-tools compiles from tests/ga-tools, and check what they send");
    if (ga) |command| {
        const ga_tools_check = b.addExecutable(.{
            .name = "ga-tools-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/ga-tools/main.zig"),
                .target = b.graph.host,
                // streams at 115200 baud run for seconds of the chip's time
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = "gasim", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = b.graph.host,
                    .optimize = .ReleaseSafe,
                }) }},
            }),
        });
        const check = b.addRunArtifact(ga_tools_check);
        // a path, rather than a command on PATH, from the repository's root
        if (std.mem.indexOfScalar(u8, command, '/') == null)
            check.addArg(command)
        else
            check.addFileArg(if (std.fs.path.isAbsolute(command)) .{ .cwd_relative = command } else b.path(command));
        check.addArg(ga_rom);
        for ([_][]const u8{ "words.ga", "row.ga" }) |program| check.addFileArg(b.path(b.fmt("tests/ga-tools/{s}", .{program})));
        // where rom/pFDISK.blk is looked for
        check.setCwd(b.path("."));
        check.has_side_effects = true;
        ga_tools_step.dependOn(&check.step);
    } else ga_tools_step.dependOn(&b.addFail("the ga-tools step needs ga-tools' ga on PATH, or -Dga=<path>").step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .use_llvm = if (coverage or fuzz) true else null,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_llvm = if (coverage or fuzz) true else null,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gasim", .module = mod },
            },
        }),
    });

    const run_example_tests = b.addRunArtifact(example_tests);

    // the web version's Sim, natively
    const web_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/Sim.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gasim", .module = mod }},
        }),
        .use_llvm = if (coverage or fuzz) true else null,
    });

    const run_web_tests = b.addRunArtifact(web_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_web_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_example_tests.step);

    if (coverage) {
        var run_test_steps: std.ArrayList(*std.Build.Step.Run) = .empty;
        run_test_steps.append(b.allocator, run_mod_tests) catch @panic("OOM");
        run_test_steps.append(b.allocator, run_exe_tests) catch @panic("OOM");
        run_test_steps.append(b.allocator, run_web_tests) catch @panic("OOM");

        const kcov_bin = b.findProgram(.{ .names = &.{"kcov"} }) orelse "kcov";

        const merge_step = std.Build.Step.Run.create(b, "merge coverage");
        merge_step.addArgs(&.{ kcov_bin, "--merge" });
        merge_step.rename_step_with_output_arg = false;
        const merged_coverage_output = merge_step.addOutputFileArg(".");

        for (run_test_steps.items) |step| {
            step.setName(b.fmt("{s} (collect coverage)", .{step.step.name}));

            // prepend the kcov exec args
            const argv = step.argv.toOwnedSlice(b.allocator) catch @panic("OOM");
            step.addArgs(&.{ kcov_bin, "--collect-only" });
            // kcov matches against the absolute paths in the debug info
            step.addDirectoryArg2(b.path("src"), .{ .prefix = "--include-pattern=", .make_absolute = true });
            merge_step.addDirectoryArg(step.addOutputFileArg(step.producer.?.name));
            step.argv.appendSlice(b.allocator, argv) catch @panic("OOM");
        }

        const install_coverage = b.addInstallDirectory(.{
            .source_dir = merged_coverage_output,
            .install_dir = .{ .custom = "coverage" },
            .install_subdir = "",
        });
        test_step.dependOn(&install_coverage.step);
    }
}

/// the icons in web/icons the GUI draws too
const gui_icons = [_][]const u8{
    "arrow-path",       "book-open", "clock",                "code-bracket",
    "computer-desktop", "cpu-chip",  "folder-open",          "moon",
    "pause",            "play",      "question-mark-circle", "round",
    "step",             "step-back", "step-node",            "sun",
};

/// Gives the GUI and its tests, and the C libraries it links as SDL3, the macOS SDK's
/// frameworks, libraries and headers, when built on a Mac for macOS. Zig
/// finds the SDK itself only when the target's OS is native, which would
/// make the GUI need the macOS it was built on, or newer.
fn addMacSdk(b: *std.Build, roots: []const *std.Build.Module, target: std.Target) void {
    if (target.os.tag != .macos or b.graph.host.result.os.tag != .macos) return;
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target) orelse return;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    var todo: std.ArrayList(*std.Build.Module) = .empty;
    todo.appendSlice(b.allocator, roots) catch @panic("OOM");
    while (todo.pop()) |m| {
        if ((seen.getOrPut(b.allocator, m) catch @panic("OOM")).found_existing) continue;
        m.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
        for (m.import_table.values()) |imported| todo.append(b.allocator, imported) catch @panic("OOM");
        for (m.link_objects.items) |object| switch (object) {
            .other_step => |c| todo.append(b.allocator, c.root_module) catch @panic("OOM"),
            else => {},
        };
    }
}
