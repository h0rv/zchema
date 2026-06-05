//! Explicit request and response contracts.
//!
//! These are the most declarative surface, intended for production APIs that
//! need path/query/body request contracts and multiple structured response
//! cases. They feed both dispatch and OpenAPI generation.

const std = @import("std");

/// Build an explicit request contract type from a spec.
///
/// ```zig
/// const CreateUserRequest = zchema.Request(.{ .body = CreateUser });
/// ```
///
/// Recognized spec fields (all optional): `.path`, `.query`, `.body`, each a
/// Zig struct type. The resulting type exposes `PathType`, `QueryType`, and
/// `BodyType` as `?type`.
pub fn Request(comptime spec: anytype) type {
    const Spec = @TypeOf(spec);
    return struct {
        pub const zchema_request = true;
        pub const PathType: ?type = if (@hasField(Spec, "path")) spec.path else null;
        pub const QueryType: ?type = if (@hasField(Spec, "query")) spec.query else null;
        pub const BodyType: ?type = if (@hasField(Spec, "body")) spec.body else null;
    };
}

/// One status-to-body mapping inside a `Response` contract.
pub const ResponseCase = struct {
    status: std.http.Status,
    /// The response body type, or `null` for an empty body.
    Type: ?type = null,
};

/// Declare a single response case mapping `status` to body type `T`.
pub fn case(comptime status: std.http.Status, comptime T: type) ResponseCase {
    return .{ .status = status, .Type = T };
}

/// Declare a response case with `status` and no body.
pub fn emptyCase(comptime status: std.http.Status) ResponseCase {
    return .{ .status = status, .Type = null };
}

/// Build an explicit response contract from a tuple of `case(...)` values.
///
/// ```zig
/// const CreateUserResponse = zchema.Response(.{
///     zchema.case(.created, User),
///     zchema.case(.unprocessable_entity, ValidationProblem),
/// });
/// ```
pub fn Response(comptime cases_tuple: anytype) type {
    const fields = std.meta.fields(@TypeOf(cases_tuple));
    if (fields.len == 0) @compileError("zchema.Response requires at least one case");
    var arr: [fields.len]ResponseCase = undefined;
    inline for (fields, 0..) |f, i| {
        arr[i] = @field(cases_tuple, f.name);
    }
    const final = arr;
    return struct {
        pub const zchema_response = true;
        pub const cases: [final.len]ResponseCase = final;
    };
}

/// True when `T` is a `Request(...)` contract.
pub fn isRequestContract(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zchema_request");
}

/// True when `T` is a `Response(...)` contract.
pub fn isResponseContract(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zchema_response");
}

test "request contract exposes optional component types" {
    const Body = struct { name: []const u8 };
    const Path = struct { id: u32 };
    const R = Request(.{ .path = Path, .body = Body });
    try std.testing.expect(isRequestContract(R));
    try std.testing.expect(R.BodyType.? == Body);
    try std.testing.expect(R.PathType.? == Path);
    try std.testing.expectEqual(@as(?type, null), R.QueryType);
}

test "response contract collects cases" {
    const Ok = struct { id: u32 };
    const Err = struct { message: []const u8 };
    const R = Response(.{
        case(.created, Ok),
        case(.bad_request, Err),
        emptyCase(.no_content),
    });
    try std.testing.expect(isResponseContract(R));
    try std.testing.expectEqual(@as(usize, 3), R.cases.len);
    try std.testing.expectEqual(std.http.Status.created, R.cases[0].status);
    try std.testing.expectEqual(@as(?type, null), R.cases[2].Type);
}
