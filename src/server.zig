//! Batteries-included HTTP serve loop for a zchema `App`.
//!
//! `serve` owns the accept loop and per-connection lifecycle so applications
//! that want the common case do not have to write it themselves. It wraps an
//! `App` (routes plus the spec and docs endpoints) and falls back to a 404 for
//! anything unmatched. Applications that need control over the socket lifecycle,
//! threading, or non-JSON behavior keep using `App.handle` directly instead.

const std = @import("std");
const dispatch = @import("dispatch.zig");
const helpers = @import("helpers.zig");
const errors = @import("errors.zig");

const Request = std.http.Server.Request;

/// Options for `serve`.
pub const ServeOptions = struct {
    /// Address to bind.
    host: []const u8 = "127.0.0.1",
    /// Port to bind.
    port: u16 = 8080,
    /// Dispatch options forwarded to `App.handle` per request.
    dispatch: dispatch.DispatchOptions = .{},
    /// Called when no route matched. Default sends a 404 ErrorBody.
    on_not_found: ?*const fn (arena: std.mem.Allocator, req: *Request) anyerror!void = null,
};

/// Serve `AppT` forever: bind, accept connections, and handle each request.
///
/// Single-threaded and blocking. `ctx` is passed through to handlers.
pub fn serve(
    comptime AppT: type,
    io: std.Io,
    gpa: std.mem.Allocator,
    ctx: anytype,
    opts: ServeOptions,
) !void {
    var addr = try std.Io.net.IpAddress.parseIp4(opts.host, opts.port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.log.info("serving on http://{s}:{d}", .{ opts.host, opts.port });

    while (true) {
        const stream = server.accept(io) catch continue;
        serveConnection(AppT, io, gpa, ctx, stream, opts);
    }
}

/// Serve every request on one connection until it closes or errors.
fn serveConnection(
    comptime AppT: type,
    io: std.Io,
    gpa: std.mem.Allocator,
    ctx: anytype,
    stream: std.Io.net.Stream,
    opts: ServeOptions,
) void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &recv);
    var sw = stream.writer(io, &send);
    var http = std.http.Server.init(&sr.interface, &sw.interface);

    while (true) {
        var req = http.receiveHead() catch return;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        handleOnce(AppT, ctx, arena, &req, opts) catch return;
    }
}

/// Handle one request: dispatch to the app, falling back to a 404 when nothing
/// matched. Uses `opts.on_not_found` when set, else a default ErrorBody.
fn handleOnce(
    comptime AppT: type,
    ctx: anytype,
    arena: std.mem.Allocator,
    req: *Request,
    opts: ServeOptions,
) !void {
    if (try AppT.handle(ctx, arena, req, opts.dispatch)) return;

    if (opts.on_not_found) |cb| {
        try cb(arena, req);
    } else {
        try helpers.respondErrorBody(arena, req, errors.errorBody(.not_found, "No matching route.", &.{}), .{});
    }
}

// --- tests ------------------------------------------------------------------

const routes_mod = @import("routes.zig");
const app_mod = @import("app.zig");

const Pong = struct {
    message: []const u8,
    pub const jsonschema = .{ .name = "Pong" };
};

fn ping() !Pong {
    return .{ .message = "pong" };
}

const TestApi = routes_mod.Api(.{routes_mod.get("/ping", ping)});
// Docs off keeps the test app to a single route.
const TestApp = app_mod.App(TestApi, .{ .docs = .{ .enabled = false } });

fn run(arena: std.mem.Allocator, request_bytes: []const u8, opts: ServeOptions) ![]const u8 {
    var in = std.Io.Reader.fixed(request_bytes);
    var out: std.Io.Writer.Allocating = .init(arena);
    var server = std.http.Server.init(&in, &out.writer);
    var req = try server.receiveHead();
    try handleOnce(TestApp, {}, arena, &req, opts);
    return out.written();
}

test "handleOnce serves a matched route" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run(arena, "GET /ping HTTP/1.1\r\n\r\n", .{});
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"message\":\"pong\"") != null);
}

test "handleOnce sends a default 404 for an unmatched route" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run(arena, "GET /missing HTTP/1.1\r\n\r\n", .{});
    try std.testing.expect(std.mem.indexOf(u8, resp, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "application/problem+json") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"status\":404") != null);
}

const not_found_marker = "OVERRIDE NOT FOUND";

fn customNotFound(arena: std.mem.Allocator, req: *Request) anyerror!void {
    try helpers.respondJsonRaw(arena, req, .not_found, "{\"note\":\"" ++ not_found_marker ++ "\"}", .{});
}

test "handleOnce invokes the on_not_found override" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run(arena, "GET /missing HTTP/1.1\r\n\r\n", .{ .on_not_found = customNotFound });
    try std.testing.expect(std.mem.indexOf(u8, resp, not_found_marker) != null);
    // The default ErrorBody detail must not appear.
    try std.testing.expect(std.mem.indexOf(u8, resp, "No matching route.") == null);
}
