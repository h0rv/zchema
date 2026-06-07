//! Integration tests that use zchema the way a consumer would: emitting
//! OpenAPI, and driving real `std.http.Server.Request` values (backed by
//! in-memory readers/writers) through the dispatcher.

const std = @import("std");
const zchema = @import("zchema");
const jsonschema = @import("jsonschema");

/// The official OpenAPI 3.1 JSON Schema, vendored from
/// https://spec.openapis.org/oas/3.1/schema/2022-10-07. It is self-contained
/// (one `$dynamicRef` to a local `$dynamicAnchor`, no external `$ref`s), so the
/// jsonschema.zig validator can check our documents against it offline.
const oas31_schema = @embedFile("oas31_schema.json");

const User = struct {
    id: u32,
    name: []const u8,

    pub const jsonschema = .{ .name = "User" };
};

const CreateUser = struct {
    name: []const u8,

    pub const jsonschema = .{
        .name = "CreateUser",
        .fields = .{ .name = .{ .minLength = 1 } },
    };
};

const Store = struct {
    next_id: u32 = 1,

    fn create(self: *Store, name: []const u8) User {
        defer self.next_id += 1;
        return .{ .id = self.next_id, .name = name };
    }
};

fn createUser(ctx: *Store, body: zchema.Body(CreateUser)) !zchema.Created(User) {
    return .{ .value = ctx.create(body.value.name) };
}

fn listUsers(ctx: *Store) ![]const User {
    _ = ctx;
    return &.{};
}

const Api = zchema.Api(.{
    zchema.post("/users", createUser),
    zchema.get("/users", listUsers),
});

/// Drive `request_bytes` through the dispatcher and return the raw HTTP response.
fn runRequest(
    arena: std.mem.Allocator,
    ctx: anytype,
    request_bytes: []const u8,
) ![]const u8 {
    var in = std.Io.Reader.fixed(request_bytes);
    var out: std.Io.Writer.Allocating = .init(arena);
    var server = std.http.Server.init(&in, &out.writer);

    var req = try server.receiveHead();
    const matched = try zchema.handle(Api, ctx, arena, &req, .{});
    try std.testing.expect(matched);
    return out.written();
}

test "POST /users validates and creates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{};
    const request =
        "POST /users HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 14\r\n" ++
        "\r\n" ++
        "{\"name\":\"Ada\"}";

    const response = try runRequest(arena, &store, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "201 Created") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null);
}

test "POST /users rejects schema violations with a structured 422" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{};
    const request =
        "POST /users HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 11\r\n" ++
        "\r\n" ++
        "{\"name\":\"\"}";

    const response = try runRequest(arena, &store, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "422") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "application/problem+json") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":422") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Request body failed validation.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"pointer\"") != null);
}

test "unknown fields report a friendly 'unexpected property' message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{};
    const request =
        "POST /users HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 25\r\n" ++
        "\r\n" ++
        "{\"name\":\"Ada\",\"x\":\"oops\"}";

    const response = try runRequest(arena, &store, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "unexpected property") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "schema is false") == null);
}

test "POST /users rejects invalid JSON with a 400" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{};
    const request =
        "POST /users HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 8\r\n" ++
        "\r\n" ++
        "{not ok}";

    const response = try runRequest(arena, &store, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "400") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":400") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Request body is not valid JSON.") != null);
}

test "unmatched route returns false" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{};
    const request = "DELETE /unknown HTTP/1.1\r\n\r\n";
    var in = std.Io.Reader.fixed(request);
    var out: std.Io.Writer.Allocating = .init(arena);
    var server = std.http.Server.init(&in, &out.writer);
    var req = try server.receiveHead();

    const matched = try zchema.handle(Api, &store, arena, &req, .{});
    try std.testing.expect(!matched);
}

test "openApiJson produces a valid 3.1 document" {
    const doc = try zchema.openApiJson(Api, std.testing.allocator, .{
        .title = "Users",
        .version = "2.0.0",
    });
    defer std.testing.allocator.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.1.1", root.get("openapi").?.string);
    try std.testing.expect(root.get("paths").?.object.get("/users") != null);
}

test "schemaText is available to consumers" {
    const text = zchema.schemaText(CreateUser);
    try std.testing.expect(std.mem.indexOf(u8, text, "minLength") != null);
}

test "generated document is a compliant OpenAPI 3.1 document" {
    const gpa = std.testing.allocator;

    const doc = try zchema.openApiJson(Api, gpa, .{ .title = "Users", .version = "1.0.0" });
    defer gpa.free(doc);

    const schema = try std.json.parseFromSlice(std.json.Value, gpa, oas31_schema, .{});
    defer schema.deinit();
    const instance = try std.json.parseFromSlice(std.json.Value, gpa, doc, .{});
    defer instance.deinit();

    var v = try jsonschema.Validator.init(gpa, .{});
    defer v.deinit();
    try v.setRootSchema(&schema.value);

    var errors: std.ArrayListUnmanaged(jsonschema.ValidationError) = .empty;
    const ok = try v.validate(&instance.value, &errors);
    if (!ok) {
        for (errors.items) |e| std.debug.print("OAS violation at {s}: {s}\n", .{ e.instance_path, e.message });
    }
    try std.testing.expect(ok);
}

// --- Path / Query / optional-return / raw routes ----------------------------

const Item = struct {
    id: u32,
    name: []const u8,
    pub const jsonschema = .{ .name = "Item" };
};

var items_buf = [_]Item{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" } };

fn getItem(p: zchema.Path(struct { id: u32 })) !?Item {
    for (items_buf) |it| {
        if (it.id == p.value.id) return it;
    }
    return null;
}

fn listItems(q: zchema.Query(struct { limit: u32 = 10 })) ![]const Item {
    return items_buf[0..@min(q.value.limit, items_buf.len)];
}

fn ping(req: *std.http.Server.Request) !void {
    try req.respond("pong", .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}

const Token = struct {
    token: []const u8,
    pub const jsonschema = .{ .name = "Token" };
};

fn whoami(auth: zchema.Header("x-token")) !Token {
    return .{ .token = auth.value orelse "anonymous" };
}

const Api2 = zchema.Api(.{
    zchema.get("/items/{id}", getItem),
    zchema.get("/items", listItems),
    zchema.get("/whoami", whoami),
    zchema.raw(.GET, "/ping", ping),
});

fn run2(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var in = std.Io.Reader.fixed(bytes);
    var out: std.Io.Writer.Allocating = .init(arena);
    var server = std.http.Server.init(&in, &out.writer);
    var req = try server.receiveHead();
    _ = try zchema.handle(Api2, {}, arena, &req, .{});
    return out.written();
}

test "typed path param resolves and optional return gives 200/404" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ok = try run2(arena, "GET /items/1 HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, ok, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "\"name\":\"a\"") != null);

    const missing = try run2(arena, "GET /items/999 HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, missing, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "application/problem+json") != null);
}

test "invalid path param yields 422 parameter error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run2(arena, "GET /items/abc HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, resp, "422") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Request parameters failed validation.") != null);
}

test "typed query param applies and validates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const one = try run2(arena, "GET /items?limit=1 HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, one, "\"name\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"name\":\"b\"") == null);

    const bad = try run2(arena, "GET /items?limit=nope HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, bad, "422") != null);
}

test "raw route serves non-JSON and is absent from OpenAPI" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run2(arena, "GET /ping HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, resp, "pong") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "text/plain") != null);

    const doc = try zchema.openApiJson(Api2, std.testing.allocator, .{});
    defer std.testing.allocator.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/ping") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/items/{id}") != null);
}

test "Spec builds a compliant OpenAPI document with no handlers" {
    const gpa = std.testing.allocator;

    const ApiSpec = zchema.Spec(.{
        zchema.endpoint(.POST, "/items", .{
            .body = Item,
            .responses = .{ zchema.case(.created, Item), zchema.case(.bad_request, zchema.ErrorBody) },
        }),
        zchema.endpoint(.GET, "/items/{id}", .{
            .path = struct { id: u32 },
            .query = struct { verbose: bool = false },
            .responses = .{ zchema.case(.ok, Item), zchema.case(.not_found, zchema.ErrorBody) },
        }),
    });

    const doc = try zchema.openApiJson(ApiSpec, gpa, .{ .title = "Items", .version = "1.0.0" });
    defer gpa.free(doc);

    const schema = try std.json.parseFromSlice(std.json.Value, gpa, oas31_schema, .{});
    defer schema.deinit();
    const instance = try std.json.parseFromSlice(std.json.Value, gpa, doc, .{});
    defer instance.deinit();

    var v = try jsonschema.Validator.init(gpa, .{});
    defer v.deinit();
    try v.setRootSchema(&schema.value);
    try std.testing.expect(try v.validate(&instance.value, null));

    try std.testing.expect(std.mem.indexOf(u8, doc, "\"/items/{id}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"in\":\"query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "#/components/schemas/Item") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"400\"") != null);
}

test "HEAD falls back to the matching GET route, body omitted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = try run2(arena, "HEAD /items/1 HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "content-length:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"a\"") == null); // body omitted

    // Disabled: HEAD no longer matches the GET route.
    var in = std.Io.Reader.fixed("HEAD /items/1 HTTP/1.1\r\n\r\n");
    var out: std.Io.Writer.Allocating = .init(arena);
    var server = std.http.Server.init(&in, &out.writer);
    var req = try server.receiveHead();
    const matched = try zchema.handle(Api2, {}, arena, &req, .{ .head_fallback = false });
    try std.testing.expect(!matched);
}

test "Header marker injects the request header, case-insensitive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const with = try run2(arena, "GET /whoami HTTP/1.1\r\nX-Token: secret\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, with, "\"token\":\"secret\"") != null);

    const without = try run2(arena, "GET /whoami HTTP/1.1\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, without, "\"token\":\"anonymous\"") != null);

    const doc = try zchema.openApiJson(Api2, std.testing.allocator, .{});
    defer std.testing.allocator.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"in\":\"header\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "x-token") != null);
}

test "operation and document metadata are emitted and stay OAS-compliant" {
    const gpa = std.testing.allocator;

    const ApiSpec = zchema.Spec(.{
        zchema.endpoint(.GET, "/items/{id}", .{
            .path = struct { id: u32 },
            .responses = .{zchema.case(.ok, Item)},
            .summary = "Fetch an item",
            .description = "Returns one item by id.",
            .tags = &.{"items"},
            .deprecated = true,
        }),
    });

    const doc = try zchema.openApiJson(ApiSpec, gpa, .{
        .title = "Items",
        .version = "1.0.0",
        .servers = &.{.{ .url = "https://api.example.com", .description = "prod" }},
        .tags = &.{.{ .name = "items", .description = "Item ops" }},
        .security_schemes = &.{
            .{ .api_key = .{ .name = "ApiKeyAuth", .field = "X-API-Key", .in = .header } },
            .{ .http = .{ .name = "BearerAuth", .scheme = "bearer", .bearer_format = "JWT" } },
        },
        .security = &.{"BearerAuth"},
    });
    defer gpa.free(doc);

    const schema = try std.json.parseFromSlice(std.json.Value, gpa, oas31_schema, .{});
    defer schema.deinit();
    const instance = try std.json.parseFromSlice(std.json.Value, gpa, doc, .{});
    defer instance.deinit();
    var v = try jsonschema.Validator.init(gpa, .{});
    defer v.deinit();
    try v.setRootSchema(&schema.value);
    try std.testing.expect(try v.validate(&instance.value, null));

    try std.testing.expect(std.mem.indexOf(u8, doc, "\"summary\":\"Fetch an item\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"deprecated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"tags\":[\"items\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"servers\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"securitySchemes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"type\":\"apiKey\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"bearerFormat\":\"JWT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"security\":[{\"BearerAuth\":[]}]") != null);
}
