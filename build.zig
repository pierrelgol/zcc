const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_sources = &.{
        "codegen.c",
        "hashmap.c",
        "parse.c",
        "preprocess.c",
        "strings.c",
        "tokenize.c",
        "type.c",
        "unicode.c",
    };

    const c_sources_with_main = &.{
        "codegen.c",
        "hashmap.c",
        "main.c",
        "parse.c",
        "preprocess.c",
        "strings.c",
        "tokenize.c",
        "type.c",
        "unicode.c",
    };

    const exe = b.addExecutable(.{
        .name = "zcc",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addIncludePath(b.path("src/"));
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src/"),
        .files = c_sources_with_main,
        .flags = &.{
            "-std=c11",
            "-g",
            "-fno-common",
            "-Wall",
            "-Wno-switch",
        },
        .language = .c,
    });
    b.installArtifact(exe);

    const zig_driver = b.addExecutable(.{
        .name = "zcc-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    zig_driver.root_module.addIncludePath(b.path("src/"));
    zig_driver.root_module.addCSourceFiles(.{
        .root = b.path("src/"),
        .files = c_sources,
        .flags = &.{
            "-std=c11",
            "-g",
            "-fno-common",
            "-Wall",
            "-Wno-switch",
        },
        .language = .c,
    });
    b.installArtifact(zig_driver);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const run_zig_driver = b.addRunArtifact(zig_driver);
    const zig_step = b.step("run-zig", "Run the Zig driver");
    zig_step.dependOn(&run_zig_driver.step);

    const check_step = b.step("check", "Run checks");
    check_step.dependOn(&exe.step);
}
