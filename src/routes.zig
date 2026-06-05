//! Route registration and handler-signature reflection.
//!
//! Registering routes is the minimum requirement for OpenAPI generation. A
//! `Route` pairs an HTTP method and path with a handler function, plus optional
//! explicit request/response contracts. What a route cannot state explicitly is
//! inferred from the handler's signature: a `Body(T)` parameter gives the request
//! body, and a `Created`/`Status`/`Response` return type gives the response.

const std = @import("std");
const markers = @import("markers.zig");
const contract = @import("contract.zig");

/// A registered route. Values of this type are produced by `get`/`post`/etc and
/// collected by `Api`. Everything is comptime-known.
pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    /// Wrapper type exposing the handler function and its type.
    Handler: type,
    /// Explicit request contract (`Request(...)`), if provided.
    request: ?type = null,
    /// Explicit response contract (`Response(...)`), if provided.
    response: ?type = null,

    /// Attach explicit request/response contracts to a route.
    ///
    /// ```zig
    /// zchema.post("/users", createUser).with(.{
    ///     .request = CreateUserRequest,
    ///     .response = CreateUserResponse,
    /// })
    /// ```
    pub fn with(comptime self: Route, comptime opts: anytype) Route {
        const Opts = @TypeOf(opts);
        var next = self;
        if (@hasField(Opts, "request")) next.request = opts.request;
        if (@hasField(Opts, "response")) next.response = opts.response;
        return next;
    }
};

/// Wrap a handler function so its value and type can be stored in a `Route`.
fn Wrap(comptime handler: anytype) type {
    if (@typeInfo(@TypeOf(handler)) != .@"fn") @compileError("route handler must be a function");
    return struct {
        pub const call = handler;
        pub const Fn = @TypeOf(handler);
    };
}

fn route(comptime method: std.http.Method, comptime path: []const u8, comptime handler: anytype) Route {
    if (path.len == 0 or path[0] != '/') @compileError("route path must start with '/': " ++ path);
    return .{ .method = method, .path = path, .Handler = Wrap(handler) };
}

pub fn get(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.GET, path, handler);
}
pub fn post(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.POST, path, handler);
}
pub fn put(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.PUT, path, handler);
}
pub fn patch(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.PATCH, path, handler);
}
pub fn delete(comptime path: []const u8, comptime handler: anytype) Route {
    return route(.DELETE, path, handler);
}

/// Register a route with explicit request/response contracts in one call.
///
/// ```zig
/// zchema.op(.POST, "/users", createUser, .{
///     .request = CreateUserRequest,
///     .response = CreateUserResponse,
/// })
/// ```
pub fn op(
    comptime method: std.http.Method,
    comptime path: []const u8,
    comptime handler: anytype,
    comptime opts: anytype,
) Route {
    return route(method, path, handler).with(opts);
}

/// Build an API type from a tuple of `Route` values. The resulting type exposes
/// `routes: [N]Route` for OpenAPI generation and dispatch.
pub fn Api(comptime routes_tuple: anytype) type {
    const fields = std.meta.fields(@TypeOf(routes_tuple));
    var arr: [fields.len]Route = undefined;
    inline for (fields, 0..) |f, i| {
        const r = @field(routes_tuple, f.name);
        if (@TypeOf(r) != Route) @compileError("Api entries must be Route values from get/post/...");
        for (arr[0..i]) |prev| {
            if (prev.method == r.method and std.mem.eql(u8, prev.path, r.path))
                @compileError("duplicate route " ++ lowerMethod(r.method) ++ " " ++ r.path);
        }
        arr[i] = r;
    }
    const final = arr;
    return struct {
        pub const zchema_api = true;
        pub const routes: [final.len]Route = final;
    };
}

// --- Handler-signature reflection -------------------------------------------

/// Where an operation parameter is carried.
pub const ParamIn = enum { path, query };

/// A single path or query parameter of an operation.
pub const OperationParam = struct {
    name: []const u8,
    in: ParamIn,
    Type: type,
    required: bool,
};

/// One response of an operation: a status and an optional body type.
pub const OperationResponse = struct {
    status: std.http.Status,
    Type: ?type,
};

/// The fully-resolved shape of one operation, combining explicit contracts and
/// signature inference.
pub const Operation = struct {
    method: std.http.Method,
    path: []const u8,
    operation_id: []const u8,
    /// Request body data type, or null if the operation takes no JSON body.
    BodyType: ?type,
    params: []const OperationParam,
    responses: []const OperationResponse,
};

fn unwrapError(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

/// Find a `Body(T)` parameter in a handler signature and return `T`.
fn inferredBodyType(comptime Fn: type) ?type {
    const info = @typeInfo(Fn).@"fn";
    inline for (info.params) |p| {
        const PT = p.type orelse continue;
        if (markers.isBody(PT)) return PT.Inner;
    }
    return null;
}

fn responsesFromType(comptime Payload: type) []const OperationResponse {
    if (Payload == void) {
        const one = [_]OperationResponse{.{ .status = .no_content, .Type = null }};
        return &one;
    }
    if (markers.isResponse(Payload)) {
        const one = [_]OperationResponse{.{ .status = Payload.status, .Type = Payload.Inner }};
        return &one;
    }
    if (contract.isResponseContract(Payload)) {
        var arr: [Payload.cases.len]OperationResponse = undefined;
        inline for (Payload.cases, 0..) |c, i| {
            arr[i] = .{ .status = c.status, .Type = c.Type };
        }
        const final = arr;
        return &final;
    }
    // A plain data type: treat as a 200 OK JSON body.
    const one = [_]OperationResponse{.{ .status = .ok, .Type = Payload }};
    return &one;
}

fn paramsFromContract(comptime ReqContract: type) []const OperationParam {
    var list: []const OperationParam = &.{};
    if (ReqContract.PathType) |P| {
        inline for (std.meta.fields(P)) |f| {
            list = list ++ [_]OperationParam{.{
                .name = f.name,
                .in = .path,
                .Type = stripOptional(f.type),
                .required = true,
            }};
        }
    }
    if (ReqContract.QueryType) |Q| {
        inline for (std.meta.fields(Q)) |f| {
            // A query field is optional when it is `?T` or carries a default.
            const required = @typeInfo(f.type) != .optional and f.default_value_ptr == null;
            list = list ++ [_]OperationParam{.{
                .name = f.name,
                .in = .query,
                .Type = stripOptional(f.type),
                .required = required,
            }};
        }
    }
    return list;
}

fn stripOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Sanitize a method+path pair into an operationId such as `post_users_id`.
fn operationId(comptime method: std.http.Method, comptime path: []const u8) []const u8 {
    comptime {
        var out: []const u8 = lowerMethod(method);
        for (path) |ch| {
            switch (ch) {
                '/', '{', '}' => {
                    if (out.len > 0 and out[out.len - 1] != '_') out = out ++ "_";
                },
                else => out = out ++ &[_]u8{ch},
            }
        }
        if (out.len > 0 and out[out.len - 1] == '_') out = out[0 .. out.len - 1];
        return out;
    }
}

/// Lowercase OpenAPI method name for `method` (e.g. `.POST` -> `"post"`).
pub fn lowerMethod(comptime method: std.http.Method) []const u8 {
    return switch (method) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .PATCH => "patch",
        .DELETE => "delete",
        .HEAD => "head",
        .OPTIONS => "options",
        .CONNECT => "connect",
        .TRACE => "trace",
    };
}

/// Resolve the full operation shape for a route.
pub fn operation(comptime r: Route) Operation {
    comptime {
        const Fn = r.Handler.Fn;
        const ret = @typeInfo(Fn).@"fn".return_type orelse void;
        const payload = unwrapError(ret);

        // Request body: explicit contract wins, else infer from a Body(T) param.
        var body_type: ?type = null;
        var params: []const OperationParam = &.{};
        if (r.request) |Req| {
            if (!contract.isRequestContract(Req))
                @compileError("route .request must be a zchema.Request(...) type");
            body_type = Req.BodyType;
            params = paramsFromContract(Req);
        } else {
            body_type = inferredBodyType(Fn);
        }

        // Responses: explicit contract wins, else infer from the return type.
        const responses = if (r.response) |Resp| blk: {
            if (!contract.isResponseContract(Resp))
                @compileError("route .response must be a zchema.Response(...) type");
            var arr: [Resp.cases.len]OperationResponse = undefined;
            for (Resp.cases, 0..) |c, i| {
                arr[i] = .{ .status = c.status, .Type = c.Type };
            }
            const final = arr;
            break :blk @as([]const OperationResponse, &final);
        } else responsesFromType(payload);

        return .{
            .method = r.method,
            .path = r.path,
            .operation_id = operationId(r.method, r.path),
            .BodyType = body_type,
            .params = params,
            .responses = responses,
        };
    }
}

// --- Tests ------------------------------------------------------------------

const TUser = struct { id: u32, name: []const u8 };
const TCreate = struct { name: []const u8 };

fn createT(body: markers.Body(TCreate)) !markers.Created(TUser) {
    return .{ .value = .{ .id = 1, .name = body.value.name } };
}

fn listT() ![]const TUser {
    return &.{};
}

test "get/post produce routes" {
    const r = post("/users", createT);
    try std.testing.expectEqual(std.http.Method.POST, r.method);
    try std.testing.expectEqualStrings("/users", r.path);
}

test "Api collects routes" {
    const A = Api(.{ get("/users", createT), post("/users", createT) });
    try std.testing.expectEqual(@as(usize, 2), A.routes.len);
}

test "operation infers body and response from signature" {
    const o = comptime operation(post("/users", createT));
    try std.testing.expect(o.BodyType.? == TCreate);
    try std.testing.expectEqual(@as(usize, 1), o.responses.len);
    try std.testing.expectEqual(std.http.Status.created, o.responses[0].status);
    try std.testing.expect(o.responses[0].Type.? == TUser);
    try std.testing.expectEqualStrings("post_users", o.operation_id);
}

test "query params are optional when nullable or defaulted" {
    const Req = contract.Request(.{
        .query = struct {
            q: []const u8, // required
            limit: u32 = 20, // optional via default
            cursor: ?[]const u8 = null, // optional via ?T
        },
    });
    const o = comptime operation(op(.GET, "/search", listT, .{ .request = Req }));
    try std.testing.expectEqual(@as(usize, 3), o.params.len);
    inline for (o.params) |p| {
        try std.testing.expectEqual(ParamIn.query, p.in);
        const want_required = comptime std.mem.eql(u8, p.name, "q");
        try std.testing.expectEqual(want_required, p.required);
    }
}

test "operation uses explicit contracts" {
    const Req = contract.Request(.{ .body = TCreate, .path = struct { id: u32 } });
    const Resp = contract.Response(.{
        contract.case(.created, TUser),
        contract.case(.bad_request, struct { message: []const u8 }),
    });
    const o = comptime operation(op(.POST, "/users/{id}", createT, .{ .request = Req, .response = Resp }));
    try std.testing.expect(o.BodyType.? == TCreate);
    try std.testing.expectEqual(@as(usize, 2), o.responses.len);
    try std.testing.expectEqual(@as(usize, 1), o.params.len);
    try std.testing.expectEqualStrings("id", o.params[0].name);
    try std.testing.expectEqual(ParamIn.path, o.params[0].in);
    try std.testing.expectEqualStrings("post_users_id", o.operation_id);
}
