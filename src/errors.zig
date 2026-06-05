//! Structured error bodies and the zchema error set.
//!
//! Error bodies follow RFC 9457 (Problem Details for HTTP APIs) and are sent as
//! `application/problem+json`. Per-field validation failures are carried in an
//! `errors` extension member, each with a JSON Pointer (RFC 6901) into the
//! request body. Layer 3 lets applications declare their own error body types;
//! `ErrorBody` is the default used by the helpers and the dispatcher.

const std = @import("std");

/// Media type for RFC 9457 problem documents.
pub const error_content_type = "application/problem+json";

/// Errors surfaced by the helpers and the dispatcher.
pub const Error = error{
    /// The request body was not well-formed JSON.
    InvalidJson,
    /// The request body parsed but failed JSON Schema validation.
    SchemaValidationFailed,
    /// The request Content-Type was not an accepted JSON media type.
    UnsupportedContentType,
    /// The request body exceeded the configured byte limit.
    BodyTooLarge,
    /// The serialized response failed JSON Schema validation (when enabled).
    ResponseValidationFailed,
};

/// A single field-level validation failure, preserving the JSON Pointer path
/// reported by `jsonschema.Validator`. Carried in `ErrorBody.errors`.
pub const FieldError = struct {
    /// JSON Pointer into the instance (for example `/name`). Empty for the root.
    pointer: []const u8 = "",
    /// Human-readable message describing the failure.
    message: []const u8,

    pub const jsonschema = .{ .name = "FieldError" };
};

/// RFC 9457 error body. `type`, `title`, and `status` are the core members;
/// `detail`, `instance`, and the `errors` extension are included when relevant.
pub const ErrorBody = struct {
    /// A URI reference identifying the problem type. `about:blank` means the
    /// status code is the only semantic.
    type: []const u8 = "about:blank",
    /// Short, human-readable summary of the problem type (the status phrase).
    title: []const u8,
    /// The HTTP status code.
    status: u16,
    /// Human-readable explanation specific to this occurrence.
    detail: ?[]const u8 = null,
    /// URI reference identifying the specific occurrence (often the request path).
    instance: ?[]const u8 = null,
    /// Per-field validation failures. Empty unless this is a validation error.
    errors: []const FieldError = &.{},

    pub const jsonschema = .{
        .name = "ErrorBody",
        .description = "RFC 9457 error body.",
        .fields = .{
            .type = .{ .description = "URI reference identifying the problem type." },
            .title = .{ .description = "Short summary of the problem type." },
            .status = .{ .description = "HTTP status code.", .minimum = 100, .maximum = 599 },
            .detail = .{ .description = "Explanation specific to this occurrence.", .required = false },
            .instance = .{ .description = "URI reference for this specific occurrence.", .required = false },
        },
    };
};

/// Build an `ErrorBody` from an HTTP status, optional detail, and field errors.
pub fn errorBody(status: std.http.Status, detail: ?[]const u8, field_errors: []const FieldError) ErrorBody {
    return .{
        .title = status.phrase() orelse "Error",
        .status = @intFromEnum(status),
        .detail = detail,
        .errors = field_errors,
    };
}

/// Build an `ErrorBody` from a zchema `Error` and any field errors.
pub fn errorBodyFor(err: Error, field_errors: []const FieldError) ErrorBody {
    return errorBody(statusForError(err), detailForError(err), field_errors);
}

/// Map a zchema `Error` to its HTTP status.
pub fn statusForError(err: Error) std.http.Status {
    return switch (err) {
        error.InvalidJson => .bad_request,
        error.SchemaValidationFailed => .unprocessable_entity,
        error.UnsupportedContentType => .unsupported_media_type,
        error.BodyTooLarge => .payload_too_large,
        error.ResponseValidationFailed => .internal_server_error,
    };
}

/// Default human-readable detail for a zchema `Error`.
pub fn detailForError(err: Error) []const u8 {
    return switch (err) {
        error.InvalidJson => "Request body is not valid JSON.",
        error.SchemaValidationFailed => "Request body failed validation.",
        error.UnsupportedContentType => "Unsupported request content type.",
        error.BodyTooLarge => "Request body is too large.",
        error.ResponseValidationFailed => "Response failed schema validation.",
    };
}

test "error mapping is total and builds bodies" {
    const all = [_]Error{
        error.InvalidJson,
        error.SchemaValidationFailed,
        error.UnsupportedContentType,
        error.BodyTooLarge,
        error.ResponseValidationFailed,
    };
    for (all) |e| {
        const b = errorBodyFor(e, &.{});
        try std.testing.expect(b.status >= 400);
        try std.testing.expect(b.title.len > 0);
        try std.testing.expect(b.detail.?.len > 0);
        try std.testing.expectEqual(@intFromEnum(statusForError(e)), b.status);
    }
}

test "errorBody carries field errors" {
    const items = [_]FieldError{.{ .pointer = "/name", .message = "unexpected property" }};
    const b = errorBody(.unprocessable_entity, "bad", &items);
    try std.testing.expectEqual(@as(u16, 422), b.status);
    try std.testing.expectEqualStrings("Unprocessable Entity", b.title);
    try std.testing.expectEqual(@as(usize, 1), b.errors.len);
}
