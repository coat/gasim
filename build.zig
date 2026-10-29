const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coverage = b.option(bool, "coverage", "Generate a coverage report with kcov") orelse false;
    const isocline = b.option(bool, "isocline", "Edit lines at the repl with isocline, which links libc (default true)") orelse true;

    const mod = b.addModule("gasim", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
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
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
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

    // the core for the web: wasm32-freestanding, with no I/O and no libc
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "gasim-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/check.zig"),
            .target = wasm_target,
            .optimize = if (optimize == .debug) .small else optimize,
            .imports = &.{.{ .name = "gasim", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = wasm_target,
                .optimize = if (optimize == .debug) .small else optimize,
            }) }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm", "Build the core for wasm32-freestanding, as the web version will");
    wasm_step.dependOn(&wasm.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .use_llvm = if (coverage) true else null,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_llvm = if (coverage) true else null,
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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_example_tests.step);

    if (coverage) {
        var run_test_steps: std.ArrayList(*std.Build.Step.Run) = .empty;
        run_test_steps.append(b.allocator, run_mod_tests) catch @panic("OOM");
        run_test_steps.append(b.allocator, run_exe_tests) catch @panic("OOM");

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
