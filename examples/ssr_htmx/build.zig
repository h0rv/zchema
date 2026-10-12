const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize });
    const templates_dep = b.dependency("zt", .{ .target = target, .optimize = optimize });
    const templates = zt.addTemplates(b, templates_dep, &.{b.path("src/pages.zt")});
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zchema", .module = zchema.module("zchema") },
            .{ .name = "zt", .module = templates_dep.module("zt") },
        },
    });
    const exe = b.addExecutable(.{ .name = "ssr-htmx", .root_module = mod });
    exe.step.dependOn(templates);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Serve the catalog on 127.0.0.1:8080").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zchema", .module = zchema.module("zchema") },
            .{ .name = "zt", .module = templates_dep.module("zt") },
        },
    }) });
    tests.step.dependOn(templates);
    b.step("test", "Test search, escaping, and OpenAPI").dependOn(&b.addRunArtifact(tests).step);
}
