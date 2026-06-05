//! Parse path and query parameters from a request target into typed structs.
//!
//! Field types may be strings, integers, floats, bools, enums, and optionals of
//! those. Query fields with a Zig default or an optional type are not required;
//! all path fields are required (a route either matches the template or it does
//! not). Failures are collected as `FieldError`s and surfaced as one error.

const std = @import("std");
const errors = @import("errors.zig");
const FieldError = errors.FieldError;

/// Returned when one or more parameters are missing or malformed. The caller
/// inspects the `field_errors` list it passed in for details.
pub const ParamError = error{InvalidParameters} || std.mem.Allocator.Error;

/// Parse the `{name}` segments of `path` (matched against `template`) into `T`.
pub fn pathParams(
    comptime T: type,
    arena: std.mem.Allocator,
    template: []const u8,
    path: []const u8,
    field_errors: *std.ArrayListUnmanaged(FieldError),
) ParamError!T {
    var result: T = undefined;
    var ok = true;

    inline for (std.meta.fields(T)) |f| {
        if (segmentValue(template, path, f.name)) |raw| {
            if (coerce(f.type, arena, raw)) |v| {
                @field(result, f.name) = v;
            } else |_| {
                ok = false;
                try field_errors.append(arena, .{
                    .pointer = "/" ++ f.name,
                    .message = "invalid path parameter",
                });
            }
        } else {
            ok = false;
            try field_errors.append(arena, .{ .pointer = "/" ++ f.name, .message = "missing path parameter" });
        }
    }

    if (!ok) return error.InvalidParameters;
    return result;
}

/// Parse the query string of `target` into `T`.
pub fn queryParams(
    comptime T: type,
    arena: std.mem.Allocator,
    target: []const u8,
    field_errors: *std.ArrayListUnmanaged(FieldError),
) ParamError!T {
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "";
    var result: T = undefined;
    var ok = true;

    inline for (std.meta.fields(T)) |f| {
        if (try queryValue(arena, query, f.name)) |raw| {
            if (coerce(f.type, arena, raw)) |v| {
                @field(result, f.name) = v;
            } else |_| {
                ok = false;
                try field_errors.append(arena, .{ .pointer = "/" ++ f.name, .message = "invalid query parameter" });
            }
        } else if (f.defaultValue()) |dflt| {
            @field(result, f.name) = dflt;
        } else if (@typeInfo(f.type) == .optional) {
            @field(result, f.name) = null;
        } else {
            ok = false;
            try field_errors.append(arena, .{ .pointer = "/" ++ f.name, .message = "missing query parameter" });
        }
    }

    if (!ok) return error.InvalidParameters;
    return result;
}

/// The value of the template `{name}` segment from `path`, or null when the
/// segment counts differ or `name` is not a template segment.
fn segmentValue(template: []const u8, path: []const u8, name: []const u8) ?[]const u8 {
    const just_path = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;
    var t_it = std.mem.splitScalar(u8, template, '/');
    var a_it = std.mem.splitScalar(u8, just_path, '/');
    var found: ?[]const u8 = null;
    while (true) {
        const t = t_it.next();
        const a = a_it.next();
        if (t == null and a == null) return found;
        if (t == null or a == null) return null;
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

/// The decoded value of query key `name`, or null when absent.
fn queryValue(arena: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = pair[0..eq];
        if (!std.mem.eql(u8, key, name)) continue;
        const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
        return try decode(arena, raw);
    }
    return null;
}

/// Percent-decode a query component, turning `+` into space.
fn decode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null and std.mem.indexOfScalar(u8, s, '+') == null)
        return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '+' => try out.append(arena, ' '),
            '%' => {
                if (i + 2 < s.len) {
                    const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                        try out.append(arena, s[i]);
                        continue;
                    };
                    const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                        try out.append(arena, s[i]);
                        continue;
                    };
                    try out.append(arena, @intCast(hi * 16 + lo));
                    i += 2;
                } else try out.append(arena, s[i]);
            },
            else => try out.append(arena, s[i]),
        }
    }
    return out.items;
}

/// Coerce a raw string into a scalar field type.
fn coerce(comptime T: type, arena: std.mem.Allocator, raw: []const u8) !T {
    switch (@typeInfo(T)) {
        .optional => |o| return try coerce(o.child, arena, raw),
        .pointer => return raw, // []const u8
        .int => return std.fmt.parseInt(T, raw, 10),
        .float => return std.fmt.parseFloat(T, raw),
        .bool => {
            if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) return true;
            if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) return false;
            return error.InvalidParameter;
        },
        .@"enum" => return std.meta.stringToEnum(T, raw) orelse error.InvalidParameter,
        else => @compileError("unsupported path/query parameter type: " ++ @typeName(T)),
    }
}

const testing = std.testing;

const Pagination = struct {
    limit: u32 = 20,
    offset: u32 = 0,
    q: ?[]const u8 = null,
    desc: bool = false,
};

test "queryParams applies defaults, optionals, and coercion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    const p = try queryParams(Pagination, arena, "/items?limit=5&desc=true&q=ada%20l", &errs);
    try testing.expectEqual(@as(u32, 5), p.limit);
    try testing.expectEqual(@as(u32, 0), p.offset);
    try testing.expect(p.desc);
    try testing.expectEqualStrings("ada l", p.q.?);
}

test "queryParams reports invalid values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    try testing.expectError(error.InvalidParameters, queryParams(Pagination, arena, "/x?limit=abc", &errs));
    try testing.expect(errs.items.len == 1);
    try testing.expectEqualStrings("/limit", errs.items[0].pointer);
}

test "pathParams extracts and coerces typed segments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    const P = struct { id: u32, slug: []const u8 };
    const p = try pathParams(P, arena, "/posts/{id}/{slug}", "/posts/42/hello", &errs);
    try testing.expectEqual(@as(u32, 42), p.id);
    try testing.expectEqualStrings("hello", p.slug);
}
