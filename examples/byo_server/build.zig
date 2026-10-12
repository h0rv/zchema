const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zchema", .module = zchema.module("zchema") }},
    });
    const exe = b.addExecutable(.{ .name = "byo_server", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run this example").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Build and test this example").dependOn(&b.addRunArtifact(tests).step);
}
