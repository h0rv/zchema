const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The JSON Schema toolkit powers boundary validation and schema emission.
    const jsonschema_dep = b.dependency("jsonschema", .{
        .target = target,
        .optimize = optimize,
    });
    const jsonschema_mod = jsonschema_dep.module("jsonschema");

    // The public `zchema` module.
    const mod = b.addModule("zchema", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "jsonschema", .module = jsonschema_mod },
        },
    });

    // A small demo executable.
    const exe = b.addExecutable(.{
        .name = "zchema",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zchema", .module = mod },
                .{ .name = "jsonschema", .module = jsonschema_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Unit tests live alongside the module sources.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Integration tests exercise the public API the way a consumer would.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zchema", .module = mod },
                .{ .name = "jsonschema", .module = jsonschema_mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Examples. Each builds its own executable and gets a `run-<name>` step.
    // Compiling them is part of `test` so they cannot silently rot.
    const examples = [_][]const u8{ "users_api", "threaded" };
    const examples_step = b.step("examples", "Build the examples");
    for (examples) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zchema", .module = mod }},
            }),
        });
        examples_step.dependOn(&example.step);
        test_step.dependOn(&example.step);

        const run_example = b.addRunArtifact(example);
        if (b.args) |args| run_example.addArgs(args);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}))
            .dependOn(&run_example.step);
    }
}
