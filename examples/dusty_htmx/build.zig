const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = .{ .target = target, .optimize = optimize };

    const zchema = b.dependency("zchema", options);
    const zt = b.dependency("zt", options);
    const catalog = b.dependency("catalog_example", options);
    const zio = b.dependency("zio", options);
    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
        .use_tls = false,
        .use_zlib = false,
    });
    dusty.module("dusty").addImport("zio", zio.module("zio"));

    // Compile the shared template into this build's cache.
    const compile_templates = b.addRunArtifact(zt.artifact("zt-compile"));
    compile_templates.addFileArg(catalog.path("src/pages.zt"));
    const generated_pages = compile_templates.addOutputFileArg("pages.zig");
    const pages = b.createModule(.{
        .root_source_file = generated_pages,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "catalog", .module = catalog.module("catalog") },
            .{ .name = "zt", .module = zt.module("zt") },
        },
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "catalog", .module = catalog.module("catalog") },
        .{ .name = "pages", .module = pages },
        .{ .name = "zchema", .module = zchema.module("zchema") },
        .{ .name = "zio", .module = zio.module("zio") },
        .{ .name = "dusty", .module = dusty.module("dusty") },
    };
    const exe = b.addExecutable(.{
        .name = "dusty-htmx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Serve catalog on localhost:8080").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Test HTTP and shutdown").dependOn(&run_tests.step);
}
