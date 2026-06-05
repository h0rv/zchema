//! Optional runtime dispatcher for registered routes.
//!
//! This is a convenience, not a framework: it never owns the accept loop, the
//! socket lifecycle, or the threading model. The application runs its own
//! `std.http.Server` loop and calls `handle` per request. Unmatched requests
//! return `false` so the caller can fall through to raw stdlib handling.
//!
//! Handler arguments are filled by comptime reflection:
//!   - a `*std.http.Server.Request` parameter receives the live request,
//!   - a `Body(T)` parameter receives the parsed-and-validated JSON body,
//!   - any other parameter receives the caller-provided `ctx` (coerced to type).
//!
//! A handler that returns `void` is assumed to have written its own response
//! (the raw stdlib escape hatch); zchema sends nothing further.

const std = @import("std");
const markers = @import("markers.zig");
const helpers = @import("helpers.zig");
const errors = @import("errors.zig");
const routes_mod = @import("routes.zig");

const Request = std.http.Server.Request;

/// Options for `handle`.
pub const DispatchOptions = struct {
    body: helpers.BodyOptions = .{},
    response: helpers.ResponseOptions = .{},
};

/// Try to handle `req` with a route from `ApiT`.
///
/// Returns `true` when a route matched (a response was sent, including the
/// structured error response for a bad request body). Returns `false` when no
/// route matched, leaving `req` untouched for the caller to handle.
///
/// `ctx` is passed through to any handler parameter that is not the request or
/// the body marker.
pub fn handle(
    comptime ApiT: type,
    ctx: anytype,
    arena: std.mem.Allocator,
    req: *Request,
    opts: DispatchOptions,
) !bool {
    inline for (ApiT.routes) |r| {
        if (req.head.method == r.method and pathMatch(r.path, requestPath(req))) {
            try invoke(r, ctx, arena, req, opts);
            return true;
        }
    }
    return false;
}

fn invoke(
    comptime r: routes_mod.Route,
    ctx: anytype,
    arena: std.mem.Allocator,
    req: *Request,
    opts: DispatchOptions,
) !void {
    const Fn = r.Handler.Fn;
    const fn_info = @typeInfo(Fn).@"fn";

    var args: std.meta.ArgsTuple(Fn) = undefined;
    inline for (fn_info.params, 0..) |p, i| {
        const PT = p.type orelse @compileError("zchema dispatch cannot handle generic handler parameters");
        if (PT == *Request) {
            args[i] = req;
        } else if (PT == std.mem.Allocator) {
            args[i] = arena;
        } else if (comptime markers.isBody(PT)) {
            var field_errors: std.ArrayListUnmanaged(errors.FieldError) = .empty;
            const parsed = helpers.jsonBodyWithErrors(PT.Inner, arena, req, opts.body, &field_errors) catch |err| {
                try respondError(arena, req, err, field_errors.items, opts.response);
                return;
            };
            args[i] = .{ .value = parsed };
        } else {
            // Pass the caller context through, coerced to the expected type.
            args[i] = @as(PT, ctx);
        }
    }

    const ret = @call(.auto, r.Handler.call, args) catch |err| {
        std.log.scoped(.zchema).err("handler for {s} {s} failed: {s}", .{
            @tagName(r.method), r.path, @errorName(err),
        });
        const problem = errors.errorBody(.internal_server_error, "The handler failed to process the request.", &.{});
        try helpers.respondErrorBody(arena, req, problem, opts.response);
        return;
    };

    const Payload = @TypeOf(ret);
    if (Payload == void) {
        // The handler took the raw escape hatch and responded itself.
        return;
    } else if (comptime markers.isResponse(Payload)) {
        try helpers.respondJson(Payload.Inner, arena, req, Payload.status, ret.value, opts.response);
    } else {
        try helpers.respondJson(Payload, arena, req, .ok, ret, opts.response);
    }
}

/// Send a default structured problem response for a boundary error, carrying
/// any per-field validation field_errors.
fn respondError(
    arena: std.mem.Allocator,
    req: *Request,
    err: anyerror,
    details: []const errors.FieldError,
    resp_opts: helpers.ResponseOptions,
) !void {
    const e: errors.Error = switch (err) {
        error.InvalidJson => error.InvalidJson,
        error.SchemaValidationFailed => error.SchemaValidationFailed,
        error.UnsupportedContentType => error.UnsupportedContentType,
        error.BodyTooLarge => error.BodyTooLarge,
        error.ResponseValidationFailed => error.ResponseValidationFailed,
        else => error.ResponseValidationFailed,
    };
    try helpers.respondErrorBody(arena, req, errors.errorBodyFor(e, details), resp_opts);
}

fn requestPath(req: *const Request) []const u8 {
    const target = req.head.target;
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..end];
}

/// Match a route path template against a concrete request path. A `{name}`
/// segment matches any single non-empty segment.
pub fn pathMatch(template: []const u8, actual: []const u8) bool {
    var t_it = std.mem.splitScalar(u8, template, '/');
    var a_it = std.mem.splitScalar(u8, actual, '/');
    while (true) {
        const t = t_it.next();
        const a = a_it.next();
        if (t == null and a == null) return true;
        if (t == null or a == null) return false;
        const ts = t.?;
        const as = a.?;
        if (ts.len >= 2 and ts[0] == '{' and ts[ts.len - 1] == '}') {
            if (as.len == 0) return false; // template segment requires a value
            continue;
        }
        if (!std.mem.eql(u8, ts, as)) return false;
    }
}

test "pathMatch handles templates" {
    try std.testing.expect(pathMatch("/users", "/users"));
    try std.testing.expect(!pathMatch("/users", "/users/1"));
    try std.testing.expect(pathMatch("/users/{id}", "/users/42"));
    try std.testing.expect(!pathMatch("/users/{id}", "/users/"));
    try std.testing.expect(pathMatch("/users/{id}/posts", "/users/42/posts"));
    try std.testing.expect(!pathMatch("/users/{id}/posts", "/users/42/comments"));
}
