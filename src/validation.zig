//! JSON boundary validation, built on `jsonschema.zig`.
//!
//! The full validation path described by the spec is:
//!   1. read the request body with a byte limit (caller's responsibility),
//!   2. parse the body as `std.json.Value`,
//!   3. validate with `jsonschema.Validator` (the full Draft 2020-12 validator),
//!   4. parse into `T` only after validation succeeds.
//!
//! Schemas are emitted from Zig types at comptime and embedded as constant
//! strings, so no schema is rebuilt at runtime.

const std = @import("std");
const jsonschema = @import("jsonschema");

const errors = @import("errors.zig");
const Error = errors.Error;
const FieldError = errors.FieldError;

/// Emitter options used for boundary schemas. Closed objects and required
/// fields make validation strict by default; `$defs` handles recursion.
pub const schema_options: jsonschema.Options = .{
    .include_schema_uri = true,
    .additional_properties = false,
    .require_all_fields = true,
    .use_defs = .auto,
};

/// Emitter options for component schemas embedded in an OpenAPI document. Same
/// as `schema_options` but without the top-level `$schema` dialect URI, which
/// OpenAPI consumers do not expect on every component.
pub const component_options: jsonschema.Options = blk: {
    var o = schema_options;
    o.include_schema_uri = false;
    break :blk o;
};

/// Emit the JSON Schema for `T` with `opts` as a comptime constant string.
pub fn emit(comptime T: type, comptime opts: jsonschema.Options) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        var w: ComptimeStringWriter = .{};
        jsonschema.write(T, &w, opts) catch |err| {
            @compileError("failed to emit JSON Schema for " ++ @typeName(T) ++ ": " ++ @errorName(err));
        };
        const final = w.buf;
        break :blk final;
    };
}

/// The standalone JSON Schema document for `T` (with the dialect URI).
pub fn schemaText(comptime T: type) []const u8 {
    return comptime emit(T, schema_options);
}

/// The component-style JSON Schema for `T` (no dialect URI), for embedding in
/// an OpenAPI document.
pub fn componentSchemaText(comptime T: type) []const u8 {
    return comptime emit(T, component_options);
}

/// The schema name zchema uses for `T` in OpenAPI `components/schemas`.
pub fn schemaName(comptime T: type) []const u8 {
    return comptime jsonschema.schemaName(T, schema_options);
}

/// The parsed schema document for `T`, built once and cached for the process.
///
/// The schema text is a comptime constant, so the parsed `std.json.Value` is
/// immutable and safe to share read-only across threads. The cache is published
/// with a lock-free compare-and-swap; under a startup race a few threads may each
/// parse and all but one leak their copy (bounded, one-time).
fn cachedSchema(comptime T: type) *const std.json.Value {
    const Holder = struct {
        var ptr: std.atomic.Value(?*std.json.Value) = .init(null);
    };
    if (Holder.ptr.load(.acquire)) |p| return p;

    // Parse into a process-lifetime arena (intentionally never freed).
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const value = a.create(std.json.Value) catch @panic("out of memory caching schema");
    value.* = std.json.parseFromSliceLeaky(std.json.Value, a, schemaText(T), .{}) catch
        unreachable; // emitter output is always valid JSON

    if (Holder.ptr.cmpxchgStrong(null, value, .acq_rel, .acquire)) |won| {
        // Another thread published first; leak ours and use theirs.
        return won.?;
    }
    return value;
}

/// Parse a JSON request body into `T` without JSON Schema validation. Types and
/// required fields are still enforced by the parser; constraints (minLength,
/// formats, additionalProperties, etc.) are not. For trusted or hot paths.
pub fn parse(comptime T: type, arena: std.mem.Allocator, raw: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, raw, .{}) catch return Error.InvalidJson;
}

/// Parse, validate, and deserialize a JSON request body into `T`.
///
/// On validation failure, when `field_errors` is non-null, one `FieldError` per
/// failed assertion (with its JSON Pointer path) is appended, allocated in
/// `arena`.
pub fn parseAndValidate(
    comptime T: type,
    arena: std.mem.Allocator,
    raw: []const u8,
    field_errors: ?*std.ArrayListUnmanaged(FieldError),
) !T {
    // 2. parse the instance.
    const instance = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch
        return Error.InvalidJson;

    // 3. validate against the comptime-emitted schema.
    try validateValue(T, arena, &instance, field_errors);

    // 4. parse into T only after validation succeeds.
    return std.json.parseFromValueLeaky(T, arena, instance, .{
        .ignore_unknown_fields = true,
        // Values may alias the already-owned `instance` memory; only copy when
        // the parser actually needs to.
        .allocate = .alloc_if_needed,
    }) catch return Error.SchemaValidationFailed;
}

/// Validate an already-parsed `std.json.Value` against the schema for `T`.
///
/// The schema document is parsed once per type and cached for the process; only
/// the per-request `Validator` is rebuilt (it accumulates in its own arena, so
/// it is not safe to reuse across requests).
pub fn validateValue(
    comptime T: type,
    arena: std.mem.Allocator,
    instance: *const std.json.Value,
    field_errors: ?*std.ArrayListUnmanaged(FieldError),
) !void {
    const schema = cachedSchema(T);

    var v = try jsonschema.Validator.init(arena, .{});
    defer v.deinit();
    try v.setRootSchema(schema);

    var verrs: std.ArrayListUnmanaged(jsonschema.ValidationError) = .empty;
    const ok = try v.validate(instance, &verrs);
    if (ok) return;

    if (field_errors) |p| {
        for (verrs.items) |e| {
            try p.append(arena, .{
                .pointer = try arena.dupe(u8, e.instance_path),
                .message = try friendlyMessage(arena, e.message),
            });
        }
    }
    return Error.SchemaValidationFailed;
}

/// Rewrite validator phrasing that leaks implementation detail into something a
/// caller can act on. zchema only ever emits a `false` subschema via
/// `additionalProperties: false`, so "schema is false" always means an
/// unexpected property here.
fn friendlyMessage(arena: std.mem.Allocator, message: []const u8) ![]const u8 {
    if (std.mem.eql(u8, message, "schema is false; no value is valid"))
        return "unexpected property";
    return arena.dupe(u8, message);
}

/// Serialize `value` to JSON and validate the result against the schema for `T`.
/// Used by response validation. Returns the serialized JSON on success.
pub fn serializeAndValidate(
    comptime T: type,
    arena: std.mem.Allocator,
    value: T,
    validate: bool,
) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(arena, value, .{});
    if (!validate) return json;

    const instance = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch
        return Error.ResponseValidationFailed;
    validateValue(T, arena, &instance, null) catch return Error.ResponseValidationFailed;
    return json;
}

/// A comptime-only writer that accumulates bytes into a constant string.
/// Implements the minimal surface `jsonschema.write` needs in minified mode.
const ComptimeStringWriter = struct {
    buf: []const u8 = "",

    pub fn writeAll(self: *ComptimeStringWriter, bytes: []const u8) !void {
        self.buf = self.buf ++ bytes;
    }

    pub fn writeByte(self: *ComptimeStringWriter, byte: u8) !void {
        self.buf = self.buf ++ &[_]u8{byte};
    }

    pub fn print(self: *ComptimeStringWriter, comptime fmt: []const u8, args: anytype) !void {
        self.buf = self.buf ++ std.fmt.comptimePrint(fmt, args);
    }

    pub fn splatByteAll(self: *ComptimeStringWriter, byte: u8, n: usize) !void {
        for (0..n) |_| try self.writeByte(byte);
    }
};

const TestUser = struct {
    name: []const u8,
    age: u8 = 18,

    pub const jsonschema = .{
        .fields = .{ .name = .{ .minLength = 1 } },
    };
};

test "schemaText is a comptime constant" {
    const text = comptime schemaText(TestUser);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "minLength") != null);
}

test "parseAndValidate accepts valid body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const u = try parseAndValidate(TestUser, arena,
        \\{"name":"Ada","age":42}
    , null);
    try std.testing.expectEqualStrings("Ada", u.name);
    try std.testing.expectEqual(@as(u8, 42), u.age);
}

test "parseAndValidate rejects invalid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(Error.InvalidJson, parseAndValidate(TestUser, arena, "{not json", null));
}

test "parseAndValidate reports validation field_errors with pointers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var field_errors: std.ArrayListUnmanaged(FieldError) = .empty;
    const result = parseAndValidate(TestUser, arena,
        \\{"name":""}
    , &field_errors);
    try std.testing.expectError(Error.SchemaValidationFailed, result);
    try std.testing.expect(field_errors.items.len >= 1);
}

test "parse skips schema validation but still enforces types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // minLength is skipped: an empty name parses fine without validation.
    const u = try parse(TestUser, arena,
        \\{"name":"","age":1}
    );
    try std.testing.expectEqualStrings("", u.name);
    // A type mismatch is still a parse error.
    try std.testing.expectError(Error.InvalidJson, parse(TestUser, arena,
        \\{"name":5}
    ));
}

test "cachedSchema returns a stable pointer" {
    const a = cachedSchema(TestUser);
    const b = cachedSchema(TestUser);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a.* == .object);
}

test "serializeAndValidate round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = try serializeAndValidate(TestUser, arena, .{ .name = "Ada", .age = 7 }, true);
    try std.testing.expect(std.mem.indexOf(u8, json, "Ada") != null);
}
