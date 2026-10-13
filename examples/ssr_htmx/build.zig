const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize });
    const templates_dep = b.dependency("zt", .{ .target = target, .optimize = optimize });
    const templates = zt.addTemplates(b, templates_dep, &.{b.path("src/pages.zt")});
    const catalog = b.addModule("catalog", .{ .root_source_file = b.path("src/catalog.zig"), .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "catalog", .module = catalog },
        .{ .name = "zchema", .module = zchema.module("zchema") },
        .{ .name = "zt", .module = templates_dep.module("zt") },
    };
    const test_step = b.step("test", "Run HTTP, allocation, and cancellation tests");
    const catalog_tests = b.addTest(.{ .root_module = catalog });
    test_step.dependOn(&b.addRunArtifact(catalog_tests).step);
    const with_zio = b.option(bool, "zio", "Also build and test the pinned Zio runtime") orelse false;
    const zio_dep = if (with_zio) b.lazyDependency("zio", .{ .target = target, .optimize = optimize }) else null;
    for ([_]bool{ false, true }) |use_zio| {
        if (use_zio and zio_dep == null) continue;
        const options = b.addOptions();
        options.addOption(bool, "use_zio", use_zio);
        const mod = b.createModule(.{
            .root_source_file = b.path(if (use_zio) "src/main_zio.zig" else "src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        });
        if (use_zio) mod.addImport("zio", zio_dep.?.module("zio"));
        const exe = b.addExecutable(.{ .name = if (use_zio) "ssr-htmx-zio" else "ssr-htmx", .root_module = mod });
        exe.step.dependOn(templates);
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        b.step(if (use_zio) "run-zio" else "run", "Serve the catalog on 127.0.0.1:8080").dependOn(&run.step);
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        });
        test_mod.addOptions("runtime_options", options);
        if (use_zio) test_mod.addImport("zio", zio_dep.?.module("zio"));
        const tests = b.addTest(.{ .root_module = test_mod });
        tests.step.dependOn(templates);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
