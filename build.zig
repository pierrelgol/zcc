const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    exe.root_module.addIncludePath(b.path("src/include"));
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src/"),
        .files = &.{
            "codegen.c",
            "hashmap.c",
            "main.c",
            "parse.c",
            "preprocess.c",
            "strings.c",
            "tokenize.c",
            "type.c",
            "unicode.c",
        },
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

    const check_step = b.step("check", "Run checks");
    check_step.dependOn(&exe.step);
}
