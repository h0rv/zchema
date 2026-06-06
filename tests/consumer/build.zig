const std = @import("std");

// A consumer that depends on zchema and nothing else. Building this proves that
// jsonschema resolves transitively and that importing only `zchema` is enough.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zchema", .module = zchema.module("zchema") }},
        }),
    });
    b.installArtifact(exe);
}
