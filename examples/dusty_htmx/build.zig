const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const z = b.dependency("zchema", .{ .target = target, .optimize = optimize });
    const templates_dep = b.dependency("zt", .{ .target = target, .optimize = optimize });
    const shared = b.dependency("catalog_example", .{ .target = target, .optimize = optimize });
    // Compile the existing catalog template into the build cache, leaving its
    // source and the std.http example's generated files untouched.
    const templates = b.addRunArtifact(templates_dep.artifact("zt-compile"));
    templates.addFileArg(shared.path("src/pages.zt"));
    const generated = templates.addOutputFileArg("pages.zig");
    const pages = b.createModule(.{ .root_source_file = generated, .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "catalog", .module = shared.module("catalog") },
        .{ .name = "zt", .module = templates_dep.module("zt") },
    } });
    const runtime = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const http = b.dependency("dusty", .{ .target = target, .optimize = optimize, .use_tls = false, .use_zlib = false });
    http.module("dusty").addImport("zio", runtime.module("zio"));
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "catalog", .module = shared.module("catalog") },
        .{ .name = "pages", .module = pages },
        .{ .name = "zchema", .module = z.module("zchema") },
        .{ .name = "zt", .module = templates_dep.module("zt") },
        .{ .name = "zio", .module = runtime.module("zio") },
        .{ .name = "dusty", .module = http.module("dusty") },
    };
    const exe = b.addExecutable(.{ .name = "dusty-htmx", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = imports }) });
    b.installArtifact(exe);
    b.step("run", "Serve catalog on localhost:8080").dependOn(&b.addRunArtifact(exe).step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .imports = imports }) });
    b.step("test", "Test actual HTTP and shutdown").dependOn(&b.addRunArtifact(tests).step);
}
