//! `App` bundles a registered `Api` with batteries-included serving: your
//! routes, plus an OpenAPI spec endpoint and a docs UI, both on by default.
//!
//! The reserved paths are checked against your routes at comptime, so a route
//! that collides with the spec or docs endpoint is a compile error (change the
//! route, override the path, or disable docs).

const std = @import("std");
const routes_mod = @import("routes.zig");
const dispatch = @import("dispatch.zig");
const openapi = @import("openapi.zig");
const docs_mod = @import("docs.zig");
const helpers = @import("helpers.zig");

const Request = std.http.Server.Request;

/// Built-in docs and spec serving.
pub const DocsServe = struct {
    /// Serve the spec and docs UI. Default: on.
    enabled: bool = true,
    /// Path the OpenAPI JSON is served from.
    spec_path: []const u8 = "/openapi.json",
    /// Path the docs UI is served from.
    ui_path: []const u8 = "/docs",
    /// Which docs UI to render.
    ui: docs_mod.DocsUi = .scalar,
    /// Page title; defaults to the OpenAPI title when null.
    title: ?[]const u8 = null,
    /// Scalar configuration (used when `ui == .scalar`).
    scalar: docs_mod.ScalarConfig = .{},
    /// CDN/asset URL overrides.
    assets: docs_mod.DocsAssets = .{},
};

/// Configuration for `App`.
pub const ServeConfig = struct {
    /// Options for the generated OpenAPI document.
    openapi: openapi.OpenApiOptions = .{},
    /// Built-in docs/spec serving.
    docs: DocsServe = .{},
};

/// Wrap an `Api` with built-in spec and docs serving.
///
/// ```zig
/// const App = zchema.App(Api, .{ .openapi = .{ .title = "Users API", .version = "1.0.0" } });
/// // in the request loop:
/// if (!try App.handle(&ctx, arena, &req, .{})) {
///     // not a route, the spec, or the docs page: fall through to raw stdlib.
/// }
/// ```
pub fn App(comptime ApiT: type, comptime cfg: ServeConfig) type {
    comptime validate(ApiT, cfg);
    return struct {
        pub const api = ApiT;
        pub const config = cfg;

        /// Handle `req`: registered routes first, then (when enabled) the spec
        /// and docs endpoints. Returns true when something was served.
        pub fn handle(
            ctx: anytype,
            arena: std.mem.Allocator,
            req: *Request,
            opts: dispatch.DispatchOptions,
        ) !bool {
            if (try dispatch.handle(ApiT, ctx, arena, req, opts)) return true;

            const getlike = req.head.method == .GET or
                (opts.head_fallback and req.head.method == .HEAD);
            if (cfg.docs.enabled and getlike) {
                const path = helpers.targetPath(req);
                if (std.mem.eql(u8, path, cfg.docs.spec_path)) {
                    const doc = try openapi.openApiJson(ApiT, arena, cfg.openapi);
                    try helpers.respondJsonRaw(arena, req, .ok, doc, .{});
                    return true;
                }
                if (std.mem.eql(u8, path, cfg.docs.ui_path)) {
                    try docs_mod.respondDocs(arena, req, .{
                        .title = cfg.docs.title orelse cfg.openapi.title,
                        .ui = cfg.docs.ui,
                        .spec_url = cfg.docs.spec_path,
                        .scalar = cfg.docs.scalar,
                        .assets = cfg.docs.assets,
                    });
                    return true;
                }
            }
            return false;
        }

        /// Allocate the OpenAPI document for this app's API and config.
        pub fn openApiJson(allocator: std.mem.Allocator) ![]u8 {
            return openapi.openApiJson(ApiT, allocator, cfg.openapi);
        }
    };
}

fn validate(comptime ApiT: type, comptime cfg: ServeConfig) void {
    if (!@hasDecl(ApiT, "routes")) @compileError("zchema.App expects a zchema.Api type");
    if (!cfg.docs.enabled) return;

    if (std.mem.eql(u8, cfg.docs.spec_path, cfg.docs.ui_path))
        @compileError("zchema.App: docs.spec_path and docs.ui_path must differ (both are '" ++ cfg.docs.spec_path ++ "')");

    for (ApiT.routes) |r| {
        if (r.method != .GET) continue;
        if (std.mem.eql(u8, r.path, cfg.docs.spec_path))
            @compileError("route GET " ++ cfg.docs.spec_path ++ " collides with the built-in spec endpoint; rename the route, set docs.spec_path, or disable docs");
        if (std.mem.eql(u8, r.path, cfg.docs.ui_path))
            @compileError("route GET " ++ cfg.docs.ui_path ++ " collides with the built-in docs endpoint; rename the route, set docs.ui_path, or disable docs");
    }
}

// --- tests ------------------------------------------------------------------

const markers = @import("markers.zig");

const TUser = struct {
    id: u32,
    name: []const u8,
    pub const jsonschema = .{ .name = "TUser" };
};

fn listUsers() ![]const TUser {
    return &.{};
}

const TestApi = routes_mod.Api(.{routes_mod.get("/users", listUsers)});
const TestApp = App(TestApi, .{ .openapi = .{ .title = "Test", .version = "1.0.0" } });

fn run(arena: std.mem.Allocator, comptime AppT: type, request_bytes: []const u8) ![]const u8 {
    var in = std.Io.Reader.fixed(request_bytes);
    var out: std.Io.Writer.Allocating = .init(arena);
    var server = std.http.Server.init(&in, &out.writer);
    var req = try server.receiveHead();
    _ = try AppT.handle({}, arena, &req, .{});
    return out.written();
}

test "App serves the spec endpoint by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run(arena, TestApp, "GET /openapi.json HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"openapi\":\"3.1.1\"") != null);
}

test "App serves the docs UI by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run(arena, TestApp, "GET /docs HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, resp, "text/html") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "@scalar/api-reference") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "/openapi.json") != null);
}

test "App can disable docs and override paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Off = App(TestApi, .{ .docs = .{ .enabled = false } });
    const resp = try run(arena, Off, "GET /openapi.json HTTP/1.1\r\n\r\n");
    // Nothing served: no response written.
    try std.testing.expectEqual(@as(usize, 0), resp.len);

    const Moved = App(TestApi, .{ .docs = .{ .spec_path = "/spec.json", .ui_path = "/reference" } });
    const resp2 = try run(arena, Moved, "GET /spec.json HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"openapi\"") != null);
}
