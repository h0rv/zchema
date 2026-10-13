//! Parse path and query parameters from a request target into typed structs.
//!
//! Field types may be strings, integers, floats, bools, enums, and optionals of
//! those. Query fields with a Zig default or an optional type are not required;
//! all path fields are required (a route either matches the template or it does
//! not). Failures are collected as `FieldError`s and surfaced as one error.

const std = @import("std");
const errors = @import("errors.zig");
const validation = @import("validation.zig");
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
    return decodeQuery(T, arena, RawQuery{ .arena = arena, .query = query }, field_errors, .{});
}

pub const QueryOptions = struct {
    /// Apply T's JSON Schema constraints after coercion. Off by default to
    /// preserve the std.http dispatcher's existing parameter behavior.
    validate: bool = false,
};

/// Decode query fields from a lookup with `get(name)` returning `?[]const u8`
/// or an error union containing it. Values must already be URL-decoded.
/// Missing fields use Zig defaults or null; unknown fields are ignored.
/// Duplicate-key and URL-decoding policy belong to the lookup.
///
/// Result strings borrow lookup storage; that storage must outlive the result.
/// Validation scratch and appended field errors use `arena`. Lookup and
/// allocation errors propagate unchanged. No server or Io runtime is required.
pub fn decodeQuery(
    comptime T: type,
    arena: std.mem.Allocator,
    values: anytype,
    field_errors: *std.ArrayListUnmanaged(FieldError),
    comptime options: QueryOptions,
) !T {
    var result: T = undefined;
    var ok = true;

    inline for (std.meta.fields(T)) |f| {
        if (try lookup(values, f.name)) |raw| {
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
    if (options.validate) {
        const json = try std.json.Stringify.valueAlloc(arena, result, .{});
        const instance = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
        try validation.validateValue(T, arena, &instance, field_errors);
    }

    return result;
}

fn lookup(values: anytype, name: []const u8) !?[]const u8 {
    return values.get(name);
}

const RawQuery = struct {
    arena: std.mem.Allocator,
    query: []const u8,

    pub fn get(self: RawQuery, name: []const u8) !?[]const u8 {
        return queryValue(self.arena, self.query, name);
    }
};

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
    // The decoded length is at most the input length, so presize once and skip
    // per-byte capacity checks below.
    try out.ensureTotalCapacityPrecise(arena, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '+' => out.appendAssumeCapacity(' '),
            '%' => {
                if (i + 2 < s.len) {
                    const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                        out.appendAssumeCapacity(s[i]);
                        continue;
                    };
                    const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                        out.appendAssumeCapacity(s[i]);
                        continue;
                    };
                    out.appendAssumeCapacity(@intCast(hi * 16 + lo));
                    i += 2;
                } else out.appendAssumeCapacity(s[i]);
            },
            else => out.appendAssumeCapacity(s[i]),
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

test "decode handles percent-encoding, plus, and fast path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Fast path: no '%' or '+' returns the input slice unchanged.
    const plain = try decode(arena, "hello");
    try testing.expectEqualStrings("hello", plain);

    try testing.expectEqualStrings("ada lovelace", try decode(arena, "ada+lovelace"));
    try testing.expectEqualStrings("a b&c", try decode(arena, "a%20b%26c"));
    // A trailing, truncated percent escape is passed through literally.
    try testing.expectEqualStrings("x%2", try decode(arena, "x%2"));
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

test "decoded and raw queries share coercion, defaults, and optional fields" {
    const Search = struct {
        term: []const u8,
        limit: u8 = 20,
        ratio: f64,
        enabled: bool,
        category: enum { books, tools },
        cursor: ?u32 = null,
    };
    const values = std.StaticStringMap([]const u8).initComptime(.{
        .{ "term", "a+b%2F" },
        .{ "ratio", "1.5" },
        .{ "enabled", "1" },
        .{ "category", "books" },
        .{ "ignored", "value" },
    });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    const decoded = try decodeQuery(Search, arena, values, &errs, .{});
    const raw = try queryParams(Search, arena, "/?term=a%2Bb%252F&ratio=1.5&enabled=1&category=books&ignored=value", &errs);

    try testing.expectEqualDeep(raw, decoded);
    try testing.expectEqualStrings("a+b%2F", decoded.term);
    try testing.expectEqual(@as(u8, 20), decoded.limit);
    try testing.expectEqual(@as(?u32, null), decoded.cursor);
    try testing.expectEqual(values.get("term").?.ptr, decoded.term.ptr);
    try testing.expectEqual(@as(usize, 0), errs.items.len);
}

test "decoded query reports missing and malformed fields and accepts empty strings" {
    const Search = struct {
        term: []const u8,
        limit: u8,
        enabled: bool,
        category: enum { books, tools },
        required: u32,
    };
    const values = std.StaticStringMap([]const u8).initComptime(.{
        .{ "term", "" },
        .{ "limit", "256" },
        .{ "enabled", "yes" },
        .{ "category", "unknown" },
    });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    try testing.expectError(error.InvalidParameters, decodeQuery(Search, arena_state.allocator(), values, &errs, .{}));
    try testing.expectEqual(@as(usize, 4), errs.items.len);
    for (errs.items, [_][]const u8{ "/limit", "/enabled", "/category", "/required" }) |err, pointer| {
        try testing.expectEqualStrings(pointer, err.pointer);
    }
}

test "schema validation is explicit and works with either lookup" {
    const Search = struct {
        term: []const u8,

        pub const jsonschema = .{ .fields = .{ .term = .{ .minLength = 3 } } };
    };
    const values = std.StaticStringMap([]const u8).initComptime(.{.{ "term", "ab" }});
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    // Existing std.http Query behavior remains coercion-only.
    _ = try queryParams(Search, arena, "/?term=ab", &errs);
    _ = try decodeQuery(Search, arena, values, &errs, .{});

    inline for (.{ values, RawQuery{ .arena = arena, .query = "term=ab" } }) |source| {
        errs.clearRetainingCapacity();
        try testing.expectError(error.SchemaValidationFailed, decodeQuery(Search, arena, source, &errs, .{ .validate = true }));
        try testing.expectEqualStrings("/term", errs.items[0].pointer);
    }

    const valid = std.StaticStringMap([]const u8).initComptime(.{.{ "term", "books" }});
    const result = try decodeQuery(Search, arena, valid, &errs, .{ .validate = true });
    try testing.expectEqual(valid.get("term").?.ptr, result.term.ptr);
}

test "decoded query propagates lookup and allocation failures" {
    const Unavailable = struct {
        pub fn get(_: @This(), _: []const u8) error{Canceled}!?[]const u8 {
            return error.Canceled;
        }
    };
    const Search = struct { term: []const u8 };
    var buffer: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&buffer);
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    try testing.expectError(error.Canceled, decodeQuery(Search, allocator.allocator(), Unavailable{}, &errs, .{}));

    const missing = std.StaticStringMap([]const u8).initComptime(.{});
    try testing.expectError(error.OutOfMemory, decodeQuery(Search, allocator.allocator(), missing, &errs, .{}));

    const present = std.StaticStringMap([]const u8).initComptime(.{.{ "term", "books" }});
    try testing.expectError(error.OutOfMemory, decodeQuery(Search, allocator.allocator(), present, &errs, .{ .validate = true }));
}

test "validated queries retain numeric types and reject non-finite numbers" {
    const Search = struct {
        count: u32,
        ratio: f64,

        pub const jsonschema = .{ .fields = .{ .count = .{ .minimum = 5 } } };
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errs: std.ArrayListUnmanaged(FieldError) = .empty;

    const valid = std.StaticStringMap([]const u8).initComptime(.{ .{ "count", "5" }, .{ "ratio", "1.5" } });
    const result = try decodeQuery(Search, arena, valid, &errs, .{ .validate = true });
    try testing.expectEqual(@as(u32, 5), result.count);
    try testing.expectEqual(@as(f64, 1.5), result.ratio);

    const too_small = std.StaticStringMap([]const u8).initComptime(.{ .{ "count", "4" }, .{ "ratio", "1.5" } });
    try testing.expectError(error.SchemaValidationFailed, decodeQuery(Search, arena, too_small, &errs, .{ .validate = true }));
    try testing.expectEqualStrings("/count", errs.items[0].pointer);

    errs.clearRetainingCapacity();
    const non_finite = std.StaticStringMap([]const u8).initComptime(.{ .{ "count", "5" }, .{ "ratio", "nan" } });
    try testing.expectError(error.SchemaValidationFailed, decodeQuery(Search, arena, non_finite, &errs, .{ .validate = true }));
    try testing.expectEqualStrings("/ratio", errs.items[0].pointer);
}
