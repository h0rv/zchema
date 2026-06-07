//! OpenAPI 3.1 generation from a registered `Api`.
//!
//! Each registered route becomes one operation. Request and response schemas
//! come straight from `jsonschema.zig`'s comptime emitter. Object-like types
//! without internal `$defs` are hoisted into `components/schemas` and referenced
//! with `$ref`; recursive or scalar schemas are inlined at the use site.

const std = @import("std");
const jsonschema = @import("jsonschema");

const routes_mod = @import("routes.zig");
const validation = @import("validation.zig");
const Route = routes_mod.Route;
const Operation = routes_mod.Operation;

/// Document-level OpenAPI options.
pub const OpenApiOptions = struct {
    title: []const u8 = "API",
    version: []const u8 = "0.0.0",
    description: ?[]const u8 = null,
    /// OpenAPI version string. Defaults to 3.1.1, the latest 3.1 patch.
    openapi_version: []const u8 = "3.1.1",
};

/// Allocate the OpenAPI document for `ApiT` as a JSON string. Caller owns it.
pub fn openApiJson(comptime ApiT: type, allocator: std.mem.Allocator, opts: OpenApiOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeOpenApi(ApiT, &aw.writer, opts);
    return aw.toOwnedSlice();
}

/// Write the OpenAPI document for `ApiT` to `writer`.
pub fn writeOpenApi(comptime ApiT: type, writer: *std.Io.Writer, opts: OpenApiOptions) !void {
    comptime assertApi(ApiT);
    const ops = comptime operations(ApiT);

    try writer.writeAll("{\"openapi\":");
    try writeString(writer, opts.openapi_version);

    // info
    try writer.writeAll(",\"info\":{\"title\":");
    try writeString(writer, opts.title);
    try writer.writeAll(",\"version\":");
    try writeString(writer, opts.version);
    if (opts.description) |d| {
        try writer.writeAll(",\"description\":");
        try writeString(writer, d);
    }
    try writer.writeAll("}");

    // paths
    try writer.writeAll(",\"paths\":{");
    const paths = comptime distinctPaths(ops);
    inline for (paths, 0..) |path, pi| {
        if (pi != 0) try writer.writeByte(',');
        try writeString(writer, path);
        try writer.writeAll(":{");
        var first_method = true;
        inline for (ops) |o| {
            if (comptime std.mem.eql(u8, o.path, path)) {
                if (!first_method) try writer.writeByte(',');
                first_method = false;
                try writeOperation(writer, o);
            }
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("}");

    // components/schemas
    const comps = comptime componentList(ops);
    if (comps.len > 0) {
        try writer.writeAll(",\"components\":{\"schemas\":{");
        inline for (comps, 0..) |c, ci| {
            if (ci != 0) try writer.writeByte(',');
            try writeString(writer, c.name);
            try writer.writeByte(':');
            try writer.writeAll(c.text);
        }
        try writer.writeAll("}}");
    }

    try writer.writeAll("}");
}

fn writeOperation(writer: *std.Io.Writer, comptime o: Operation) !void {
    try writeString(writer, comptime routes_mod.lowerMethod(o.method));
    try writer.writeAll(":{\"operationId\":");
    try writeString(writer, o.operation_id);

    // parameters
    if (o.params.len > 0) {
        try writer.writeAll(",\"parameters\":[");
        inline for (o.params, 0..) |p, i| {
            if (i != 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try writeString(writer, p.name);
            try writer.writeAll(",\"in\":");
            try writeString(writer, @tagName(p.in));
            try writer.print(",\"required\":{},\"schema\":", .{p.required});
            try writeSchema(writer, p.Type);
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }

    // requestBody
    if (o.BodyType) |B| {
        try writer.writeAll(",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":");
        try writeSchema(writer, B);
        try writer.writeAll("}}}");
    }

    // responses
    try writer.writeAll(",\"responses\":{");
    inline for (o.responses, 0..) |r, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"{d}\":{{\"description\":", .{@intFromEnum(r.status)});
        try writeString(writer, comptime statusPhrase(r.status));
        if (r.Type) |T| {
            try writer.writeAll(",\"content\":{\"application/json\":{\"schema\":");
            try writeSchema(writer, T);
            try writer.writeAll("}}");
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("}}");
}

/// Write a `$ref` to a hoisted component, or inline the schema.
fn writeSchema(writer: *std.Io.Writer, comptime T: type) !void {
    if (comptime useComponent(T)) {
        try writer.writeAll("{\"$ref\":\"#/components/schemas/");
        try writer.writeAll(comptime validation.schemaName(T));
        try writer.writeAll("\"}");
    } else {
        try writer.writeAll(comptime validation.componentSchemaText(T));
    }
}

/// The component schema text for `T`. Recursive schemas carry their own `$defs`
/// with internal `#/$defs/...` references; those resolve against the document
/// root unless the schema declares an `$id`, so one is injected for them.
fn componentText(comptime T: type) []const u8 {
    comptime {
        const text = validation.componentSchemaText(T);
        const has_defs = std.mem.indexOf(u8, text, "\"$defs\"") != null;
        const has_id = std.mem.indexOf(u8, text, "\"$id\"") != null;
        if (!has_defs or has_id or text.len == 0 or text[0] != '{') return text;
        return "{\"$id\":\"" ++ validation.schemaName(T) ++ "\"," ++ text[1..];
    }
}

fn writeString(writer: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, writer);
}

fn statusPhrase(comptime status: std.http.Status) []const u8 {
    return status.phrase() orelse "";
}

// --- comptime analysis ------------------------------------------------------

fn assertApi(comptime ApiT: type) void {
    if (!@hasDecl(ApiT, "routes") and !@hasDecl(ApiT, "operations"))
        @compileError("openApiJson expects a zchema.Api (routes) or zchema.Spec (operations) type");
}

fn operations(comptime ApiT: type) []const Operation {
    // A Spec carries operations directly; an Api reflects them from routes.
    if (@hasDecl(ApiT, "operations")) return &ApiT.operations;

    var list: []const Operation = &.{};
    inline for (ApiT.routes) |r| {
        if (r.is_raw) continue; // raw routes are not JSON; not documented
        list = list ++ [_]Operation{routes_mod.operation(r)};
    }
    return list;
}

fn distinctPaths(comptime ops: []const Operation) []const []const u8 {
    var list: []const []const u8 = &.{};
    outer: for (ops) |o| {
        for (list) |p| {
            if (std.mem.eql(u8, p, o.path)) continue :outer;
        }
        list = list ++ [_][]const u8{o.path};
    }
    return list;
}

const Component = struct { name: []const u8, text: []const u8 };

/// True when `T` should be hoisted into `components/schemas` rather than inlined.
/// Object and union schemas are hoisted and referenced with `$ref`; scalars,
/// arrays, and slices are inlined at the use site.
fn useComponent(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => true,
        else => false,
    };
}

fn collectType(comptime T: type, list: *[]const Component) void {
    if (!useComponent(T)) return;
    const name = validation.schemaName(T);
    const text = componentText(T);
    for (list.*) |c| {
        if (std.mem.eql(u8, c.name, name)) {
            if (!std.mem.eql(u8, c.text, text))
                @compileError("two distinct types share the schema name '" ++ name ++ "'; set a unique jsonschema .name");
            return;
        }
    }
    list.* = list.* ++ [_]Component{.{ .name = name, .text = text }};
}

fn componentList(comptime ops: []const Operation) []const Component {
    var list: []const Component = &.{};
    for (ops) |o| {
        if (o.BodyType) |B| collectType(B, &list);
        for (o.responses) |r| {
            if (r.Type) |T| collectType(T, &list);
        }
    }
    return list;
}

// --- tests ------------------------------------------------------------------

const markers = @import("markers.zig");
const contract = @import("contract.zig");

const User = struct {
    id: u32,
    name: []const u8,
    pub const jsonschema = .{ .name = "User" };
};
const CreateUser = struct {
    name: []const u8,
    pub const jsonschema = .{ .name = "CreateUser", .fields = .{ .name = .{ .minLength = 1 } } };
};

fn createUser(body: markers.Body(CreateUser)) !markers.Created(User) {
    return .{ .value = .{ .id = 1, .name = body.value.name } };
}

fn listUsers() ![]const User {
    return &.{};
}

test "openApiJson emits 3.1 document with operations and components" {
    const Api = routes_mod.Api(.{
        routes_mod.post("/users", createUser),
        routes_mod.get("/users", listUsers),
    });

    const json = try openApiJson(Api, std.testing.allocator, .{ .title = "Users", .version = "1.0.0" });
    defer std.testing.allocator.free(json);

    // Valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"openapi\":\"3.1.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"/users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"post\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"operationId\":\"post_users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"201\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "#/components/schemas/CreateUser") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "#/components/schemas/User") != null);
}

test "openApiJson includes multiple response cases and parameters" {
    const Problem = struct {
        message: []const u8,
        pub const jsonschema = .{ .name = "Problem" };
    };
    const Req = contract.Request(.{ .body = CreateUser, .path = struct { id: u32 } });
    const Resp = contract.Response(.{
        contract.case(.created, User),
        contract.case(.bad_request, Problem),
        contract.emptyCase(.no_content),
    });
    const Api = routes_mod.Api(.{
        routes_mod.op(.PUT, "/users/{id}", createUser, .{ .request = Req, .response = Resp }),
    });

    const json = try openApiJson(Api, std.testing.allocator, .{});
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"/users/{id}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"in\":\"path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"400\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"204\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "#/components/schemas/Problem") != null);
}

test "recursive response schema is hoisted with a self-contained $id" {
    const Node = struct {
        name: []const u8,
        children: []const @This(),
        pub const jsonschema = .{ .name = "Node" };
    };
    const Tree = struct {
        fn root() !Node {
            return .{ .name = "", .children = &.{} };
        }
    };
    const Api = routes_mod.Api(.{routes_mod.get("/tree", Tree.root)});

    const json = try openApiJson(Api, std.testing.allocator, .{});
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const node = parsed.value.object.get("components").?.object.get("schemas").?.object.get("Node").?.object;
    // Recursion uses $defs, and the component carries an $id so the internal
    // "#/$defs/Node" references resolve within the component itself.
    try std.testing.expect(node.get("$defs") != null);
    try std.testing.expectEqualStrings("Node", node.get("$id").?.string);
}
