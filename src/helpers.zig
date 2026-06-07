//! Helper functions for existing `std.http.Server` handlers.
//!
//! These are the migration surface. Applications keep their own routing and call
//! these where they want JSON contracts. They do not generate OpenAPI; that
//! requires registering routes (see `routes.zig`).

const std = @import("std");
const jsonschema = @import("jsonschema");

const errors = @import("errors.zig");
const validation = @import("validation.zig");
const Error = errors.Error;

const Request = std.http.Server.Request;

/// Options controlling how a request body is read and validated.
pub const BodyOptions = struct {
    /// Hard upper bound on the body size in bytes. Exceeding it yields
    /// `error.BodyTooLarge`.
    max_bytes: usize = 1 << 20,
    /// Upper bound on the streaming read buffer handed to the body reader. The
    /// actual buffer is capped by `max_bytes` and the request content length.
    read_buffer_size: usize = 64 * 1024,
    /// When true (the default), the request Content-Type must be a JSON media
    /// type or `jsonBody` returns `error.UnsupportedContentType`.
    require_json_content_type: bool = true,
    /// When true (the default), the body is validated against the schema for `T`.
    /// Set false to skip schema validation on trusted or hot paths (the parser
    /// still enforces types and required fields).
    validate: bool = true,
};

/// Options controlling JSON response serialization.
pub const ResponseOptions = struct {
    /// When true, the serialized response is validated against the schema for
    /// its type before it is sent. Off by default to avoid the extra work on
    /// the hot path.
    validate: bool = false,
    /// Content type sent with the body. Defaults to `application/json`; error
    /// responders use `application/problem+json`.
    content_type: []const u8 = json_content_type,
    /// Extra response headers, sent in addition to the content type.
    extra_headers: []const std.http.Header = &.{},
    /// Whether the connection should be kept alive.
    keep_alive: bool = true,
};

/// JSON media type sent with every `respondJson` response.
pub const json_content_type = "application/json";

/// True when `path` matches the request target's path component, ignoring any
/// query string.
pub fn pathEql(req: *const Request, path: []const u8) bool {
    return std.mem.eql(u8, targetPath(req), path);
}

/// Extract the value of a `{name}` segment from the request path, matched
/// against `template`. Returns null when the path does not match the template
/// or the parameter is absent.
///
/// ```zig
/// const id = zchema.pathParam(req, "/users/{id}", "id") orelse return error.NotFound;
/// ```
///
/// Read this before consuming the body; see `body` on head invalidation.
pub fn pathParam(req: *const Request, template: []const u8, name: []const u8) ?[]const u8 {
    var t_it = std.mem.splitScalar(u8, template, '/');
    var a_it = std.mem.splitScalar(u8, targetPath(req), '/');
    var found: ?[]const u8 = null;
    while (true) {
        const t = t_it.next();
        const a = a_it.next();
        if (t == null and a == null) return found;
        if (t == null or a == null) return null; // segment counts differ
        const ts = t.?;
        const as = a.?;
        if (ts.len >= 2 and ts[0] == '{' and ts[ts.len - 1] == '}') {
            if (as.len == 0) return null;
            if (std.mem.eql(u8, ts[1 .. ts.len - 1], name)) found = as;
        } else if (!std.mem.eql(u8, ts, as)) {
            return null;
        }
    }
}

/// Header name matching. HTTP header names are case-insensitive, so that is the
/// default; `sensitive` is available for the rare case that needs exact bytes.
pub const HeaderCase = enum { insensitive, sensitive };

/// The value of request header `name` (case-insensitive), or null when absent.
///
/// Read headers before consuming the body; see `body` on head invalidation.
pub fn header(req: *const Request, name: []const u8) ?[]const u8 {
    return headerWith(req, name, .insensitive);
}

/// Like `header`, but with selectable case sensitivity.
pub fn headerWith(req: *const Request, name: []const u8, case: HeaderCase) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        const match = switch (case) {
            .insensitive => std.ascii.eqlIgnoreCase(h.name, name),
            .sensitive => std.mem.eql(u8, h.name, name),
        };
        if (match) return h.value;
    }
    return null;
}

/// The path component of the request target, without any query string.
pub fn targetPath(req: *const Request) []const u8 {
    const target = req.head.target;
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..end];
}

/// Read the request body with a hard byte limit.
///
/// The returned slice is allocated in `arena`. Returns `error.BodyTooLarge`
/// when the body exceeds `opts.max_bytes`.
///
/// Per `std.http.Server`, reading the body invalidates the string fields of
/// `req.head` (notably `target` and the header values). Capture anything you
/// need from `req.head` (path params, headers) before calling this.
pub fn body(req: *Request, arena: std.mem.Allocator, opts: BodyOptions) ![]const u8 {
    const want: usize = if (req.head.content_length) |cl|
        std.math.lossyCast(usize, cl) +| 1
    else
        opts.read_buffer_size;
    const size = @max(@min(@min(opts.read_buffer_size, opts.max_bytes +| 1), want), 1);

    const read_buffer = try arena.alloc(u8, size);
    const reader = try req.readerExpectContinue(read_buffer);
    return reader.allocRemaining(arena, .limited(opts.max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => Error.BodyTooLarge,
        else => |e| e,
    };
}

/// Read, parse, and validate a JSON request body into `T`.
pub fn jsonBody(
    comptime T: type,
    arena: std.mem.Allocator,
    req: *Request,
    opts: BodyOptions,
) !T {
    if (opts.require_json_content_type and !isJsonContentType(req.head.content_type))
        return Error.UnsupportedContentType;

    const raw = try body(req, arena, opts);
    if (!opts.validate) return validation.parse(T, arena, raw);
    return validation.parseAndValidate(T, arena, raw, null);
}

/// Like `jsonBody`, but appends per-field validation failures (with JSON Pointer
/// paths) to `field_errors` on validation failure.
pub fn jsonBodyWithErrors(
    comptime T: type,
    arena: std.mem.Allocator,
    req: *Request,
    opts: BodyOptions,
    field_errors: *std.ArrayListUnmanaged(errors.FieldError),
) !T {
    if (opts.require_json_content_type and !isJsonContentType(req.head.content_type))
        return Error.UnsupportedContentType;

    const raw = try body(req, arena, opts);
    if (!opts.validate) return validation.parse(T, arena, raw);
    return validation.parseAndValidate(T, arena, raw, field_errors);
}

/// Serialize `value` of type `T` as JSON and send it with `status`.
///
/// Adds a JSON content type. When `opts.validate` is set, the serialized body is
/// validated against the schema for `T` first.
pub fn respondJson(
    comptime T: type,
    arena: std.mem.Allocator,
    req: *Request,
    status: std.http.Status,
    value: T,
    opts: ResponseOptions,
) !void {
    const json = try validation.serializeAndValidate(T, arena, value, opts.validate);
    try respondJsonRaw(arena, req, status, json, opts);
}

/// Respond with a structured `ErrorBody` derived from a zchema `Error`.
/// Errors outside the zchema set are re-raised for the caller to handle.
///
/// Handy in manual handlers: `zchema.jsonBody(...) catch |err|
/// return zchema.respondError(arena, req, err, .{});`
pub fn respondError(
    arena: std.mem.Allocator,
    req: *Request,
    err: anyerror,
    opts: ResponseOptions,
) !void {
    const e: Error = switch (err) {
        error.InvalidJson => error.InvalidJson,
        error.SchemaValidationFailed => error.SchemaValidationFailed,
        error.UnsupportedContentType => error.UnsupportedContentType,
        error.BodyTooLarge => error.BodyTooLarge,
        error.ResponseValidationFailed => error.ResponseValidationFailed,
        else => return err,
    };
    try respondErrorBody(arena, req, errors.errorBodyFor(e, &.{}), opts);
}

/// Send an RFC 9457 `ErrorBody` as `application/problem+json`, using the status
/// carried in the body itself.
pub fn respondErrorBody(
    arena: std.mem.Allocator,
    req: *Request,
    error_body: errors.ErrorBody,
    opts: ResponseOptions,
) !void {
    // Omit null members (detail/instance) so the body matches RFC 9457 style;
    // the ErrorBody schema marks them optional, so this stays schema-consistent.
    const json = try std.json.Stringify.valueAlloc(arena, error_body, .{ .emit_null_optional_fields = false });
    var o = opts;
    o.content_type = errors.error_content_type;
    const status: std.http.Status = @enumFromInt(error_body.status);
    try respondJsonRaw(arena, req, status, json, o);
}

/// Send an already-serialized JSON `payload` with `status`, adding the content
/// type from `opts` and any extra headers.
pub fn respondJsonRaw(
    arena: std.mem.Allocator,
    req: *Request,
    status: std.http.Status,
    payload: []const u8,
    opts: ResponseOptions,
) !void {
    const headers = try arena.alloc(std.http.Header, opts.extra_headers.len + 1);
    headers[0] = .{ .name = "content-type", .value = opts.content_type };
    @memcpy(headers[1..], opts.extra_headers);

    // A body-bearing request (POST/PUT/PATCH) with no content-length and no
    // chunked encoding has an unframed body that cannot be kept alive; std.http
    // would assert (unreachable) while trying to discard it. Close instead.
    const unframed_body = req.head.method.requestHasBody() and
        req.head.transfer_encoding == .none and
        req.head.content_length == null;

    try req.respond(payload, .{
        .status = status,
        .keep_alive = opts.keep_alive and !unframed_body,
        .extra_headers = headers,
    });
}

/// True for `application/json` and any `+json` structured-syntax suffix, ignoring
/// parameters such as `; charset=utf-8`.
pub fn isJsonContentType(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    const semi = std.mem.indexOfScalar(u8, ct, ';') orelse ct.len;
    const media = std.mem.trim(u8, ct[0..semi], " \t");
    if (std.ascii.eqlIgnoreCase(media, json_content_type)) return true;
    return std.ascii.endsWithIgnoreCase(media, "+json");
}

test "pathEql ignores query string" {
    var req: Request = undefined;
    req.head.target = "/users?page=2";
    try std.testing.expect(pathEql(&req, "/users"));
    try std.testing.expect(!pathEql(&req, "/user"));
}

test "pathParam extracts named segments" {
    var req: Request = undefined;
    req.head.target = "/users/42/posts/7?draft=1";
    try std.testing.expectEqualStrings("42", pathParam(&req, "/users/{id}/posts/{pid}", "id").?);
    try std.testing.expectEqualStrings("7", pathParam(&req, "/users/{id}/posts/{pid}", "pid").?);
    try std.testing.expectEqual(@as(?[]const u8, null), pathParam(&req, "/users/{id}", "id"));
    try std.testing.expectEqual(@as(?[]const u8, null), pathParam(&req, "/users/{id}/posts/{pid}", "missing"));
}

test "isJsonContentType matches json media types" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("application/json; charset=utf-8"));
    try std.testing.expect(isJsonContentType("application/merge-patch+json"));
    try std.testing.expect(!isJsonContentType("text/plain"));
    try std.testing.expect(!isJsonContentType(null));
}

test "header lookup is case-insensitive by default and toggleable" {
    const bytes = "GET / HTTP/1.1\r\nX-Token: abc\r\n\r\n";
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: Request = .{ .server = &server, .head = undefined, .head_buffer = bytes };

    try std.testing.expectEqualStrings("abc", header(&req, "x-token").?);
    try std.testing.expectEqualStrings("abc", headerWith(&req, "X-Token", .sensitive).?);
    try std.testing.expectEqual(@as(?[]const u8, null), headerWith(&req, "x-token", .sensitive));
    try std.testing.expectEqual(@as(?[]const u8, null), header(&req, "missing"));
}
