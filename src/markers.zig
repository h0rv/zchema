//! Signature marker types (Layer 2).
//!
//! Markers are thin generic wrappers that give plain Zig data types HTTP
//! meaning without polluting the data models themselves. They appear in handler
//! signatures so that comptime reflection can recover the request body type and
//! the response status/schema for OpenAPI generation and dispatch.

const std = @import("std");

/// Discriminator stored on every marker type so reflection can classify a
/// handler parameter or return type without relying on its name.
pub const Kind = enum {
    /// A request-body marker produced by `Body`.
    body,
    /// A single-status response marker produced by `Created` / `Status`.
    response,
    /// A path-parameters marker produced by `Path`.
    path,
    /// A query-parameters marker produced by `Query`.
    query,
};

/// Request body marker: wraps the parsed-and-validated request body of type `T`.
///
/// ```zig
/// fn createUser(ctx: *Ctx, body: zchema.Body(CreateUser)) !zchema.Created(User) { ... }
/// ```
pub fn Body(comptime T: type) type {
    return struct {
        value: T,

        pub const zchema_marker: Kind = .body;
        /// The wrapped data type.
        pub const Inner = T;
    };
}

/// Path-parameters marker: `T` is a struct whose fields name the `{...}`
/// segments of the route path. The dispatcher parses them from the URL.
pub fn Path(comptime T: type) type {
    return struct {
        value: T,

        pub const zchema_marker: Kind = .path;
        pub const Inner = T;
    };
}

/// Query-parameters marker: `T` is a struct whose fields name query keys.
/// Fields with a default or an optional type are not required.
pub fn Query(comptime T: type) type {
    return struct {
        value: T,

        pub const zchema_marker: Kind = .query;
        pub const Inner = T;
    };
}

/// `201 Created` response marker for a body of type `T`.
pub fn Created(comptime T: type) type {
    return Status(.created, T);
}

/// Response marker pinning a specific status code to a body of type `T`.
pub fn Status(comptime code: std.http.Status, comptime T: type) type {
    return struct {
        value: T,

        pub const zchema_marker: Kind = .response;
        /// The HTTP status this response represents.
        pub const status: std.http.Status = code;
        /// The wrapped data type.
        pub const Inner = T;
    };
}

/// Returns the marker `Kind` of `T`, or null if `T` is not a marker type.
pub fn markerKind(comptime T: type) ?Kind {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "zchema_marker")) return null;
    return T.zchema_marker;
}

/// True when `T` is a `Body(X)` marker.
pub fn isBody(comptime T: type) bool {
    return markerKind(T) == .body;
}

/// True when `T` is a `Created`/`Status` response marker.
pub fn isResponse(comptime T: type) bool {
    return markerKind(T) == .response;
}

/// True when `T` is a `Path(X)` marker.
pub fn isPath(comptime T: type) bool {
    return markerKind(T) == .path;
}

/// True when `T` is a `Query(X)` marker.
pub fn isQuery(comptime T: type) bool {
    return markerKind(T) == .query;
}

test "body marker carries inner type" {
    const M = Body(struct { a: u8 });
    try std.testing.expect(isBody(M));
    try std.testing.expect(!isResponse(M));
    try std.testing.expectEqual(@as(?Kind, .body), markerKind(M));
}

test "created is 201 status marker" {
    const M = Created(struct { id: u32 });
    try std.testing.expect(isResponse(M));
    try std.testing.expectEqual(std.http.Status.created, M.status);
}

test "status marker pins arbitrary code" {
    const M = Status(.accepted, struct {});
    try std.testing.expectEqual(std.http.Status.accepted, M.status);
}

test "plain types are not markers" {
    try std.testing.expectEqual(@as(?Kind, null), markerKind(u32));
    try std.testing.expectEqual(@as(?Kind, null), markerKind(struct { x: u8 }));
}
