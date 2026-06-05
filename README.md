# zchema

Typed HTTP contracts for Zig's standard library.

`zchema` is a thin layer over `std.http.Server`. It adds JSON request
parsing, response serialization, JSON Schema validation, and OpenAPI 3.1
generation. It does not own the accept loop, the socket lifecycle, the threading
model, or any non-JSON behavior. `std.http.Server.Request` stays available
everywhere, so the raw stdlib path is always one call away.

Schemas and validation come from
[`h0rv/jsonschema.zig`](https://github.com/h0rv/jsonschema.zig) (Draft 2020-12).
Requires Zig 0.16.0+.

## Install

```sh
zig fetch --save "git+https://github.com/h0rv/jsonschema.zig.git#v0.1.0"
zig fetch --save "git+https://github.com/<you>/zchema.git"
```

Wire both modules into `build.zig`:

```zig
const jsonschema = b.dependency("jsonschema", .{ .target = target, .optimize = optimize });
const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zchema", zchema.module("zchema"));
```

## Migrating an existing handler

Keep your server loop and your routing. Adopt contracts where you want them. A
raw stdlib handler:

```zig
const reader = try req.readerExpectContinue(&buf);
const raw = try reader.allocRemaining(arena, .limited(1 << 20));
const input = std.json.parseFromSliceLeaky(Echo, arena, raw, .{}) catch
    return req.respond("{\"error\":\"invalid json\"}", .{ .status = .bad_request });
// ...validate by hand, serialize by hand...
```

becomes:

```zig
const input = zchema.jsonBody(Echo, arena, &req, .{}) catch |err|
    return zchema.respondError(arena, &req, err, .{});
try zchema.respondJson(Greeting, arena, &req, .ok, .{ .message = input.name }, .{});
```

`jsonBody` reads the body under a byte limit, validates it against the schema
emitted from `Echo`, then parses. `respondError` turns a zchema error into a
structured JSON body. See `examples/migration.zig`.

## Registered routes and markers

Registering routes is the minimum for OpenAPI. Markers give plain data types
HTTP meaning in the handler signature, so the request body and response status
are inferred:

```zig
const Api = zchema.Api(.{
    zchema.post("/users", createUser),
    zchema.get("/users", listUsers),
});

fn createUser(store: *Store, body: zchema.Body(CreateUser)) !zchema.Created(User) {
    return .{ .value = try store.create(body.value.name) };
}

fn listUsers(store: *Store) ![]const User {
    return store.users.items;
}
```

The optional dispatcher runs registered routes against a live request. It fills
handler arguments by type: a `*std.http.Server.Request` gets the request, a
`Body(T)` gets the parsed body, a `std.mem.Allocator` gets the per-request
arena, anything else gets your context value. Unmatched requests return `false`:

```zig
if (!try zchema.handle(Api, &store, arena, &req, .{})) {
    // No route matched. Handle it with raw stdlib.
}
```

## Explicit contracts

For path and query parameters and multiple response cases, declare contracts and
register with `op`:

```zig
const GetUserResponse = zchema.Response(.{
    zchema.case(.ok, User),
    zchema.case(.not_found, zchema.ErrorBody),
});

const Api = zchema.Api(.{
    zchema.op(.GET, "/users/{id}", getUser, .{
        .request = zchema.Request(.{ .path = struct { id: u32 } }),
        .response = GetUserResponse,
    }),
});
```

A handler that returns `void` is assumed to have responded itself, which is how
you serve multiple statuses or non-JSON bodies. `pathParam` reads a path
segment; read it before the body, since reading the body invalidates
`req.head`:

```zig
fn getUser(store: *Store, req: *std.http.Server.Request, arena: std.mem.Allocator) !void {
    const id = parseId(req) orelse return respondNotFound(arena, req);
    if (store.find(id)) |user| {
        try zchema.respondJson(User, arena, req, .ok, user, .{});
    } else {
        try respondNotFound(arena, req);
    }
}
```

See `examples/users_api.zig` for the full CRUD service.

## Data models

Models are plain structs. Schema metadata rides on an optional
`pub const jsonschema`. HTTP meaning lives in the contract wrappers, never on
the model, because models are shared across endpoints:

```zig
const CreateUser = struct {
    name: []const u8,

    pub const jsonschema = .{ .fields = .{ .name = .{ .minLength = 1 } } };
};
```

## OpenAPI 3.1

Any registered `Api` generates an OpenAPI 3.1 document:

```zig
const doc = try zchema.openApiJson(Api, allocator, .{ .title = "Users API", .version = "1.0.0" });
// or stream it: try zchema.writeOpenApi(Api, writer, .{});
```

Request bodies, response bodies, multiple response cases, and path and query
parameters all come from the registered types. Object schemas are hoisted into
`components/schemas` and referenced with `$ref`.

The document is validated against the official OpenAPI 3.1 JSON Schema in the
test suite, so it stays compliant.

## App: spec and docs on by default

`App` wraps an `Api` and serves your routes plus an OpenAPI spec endpoint
(`/openapi.json`) and a docs UI (`/docs`), both on by default:

```zig
const Server = zchema.App(Api, .{
    .openapi = .{ .title = "Users API", .version = "1.0.0" },
});

// in the request loop:
if (!try Server.handle(&store, arena, &req, .{})) {
    // not a route, the spec, or the docs page: fall through to raw stdlib.
}
```

Reserved paths are checked against your routes at comptime, so registering
`GET /docs` or `GET /openapi.json` yourself is a compile error. Override or turn
things off:

```zig
zchema.App(Api, .{
    .docs = .{
        .ui = .redoc,            // .scalar (default), .redoc, .swagger_ui, .elements
        .ui_path = "/reference", // default "/docs"
        .spec_path = "/spec.json", // default "/openapi.json"
        // .enabled = false,     // turn the spec and docs off entirely
    },
});
```

## Docs UI

Scalar is the default. Its promotional and telemetry features (AI chat, MCP,
telemetry) are off by default and configurable, and the CDN URLs are
overridable so you can pin a version or self-host:

```zig
zchema.App(Api, .{
    .docs = .{
        .scalar = .{
            .hide_models = true,
            .disable_ai = true,   // default
            .theme = "moon",
            .extra_json = "\"showSidebar\":false", // anything Scalar supports
        },
        .assets = .{ .script = "https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.25.0" },
    },
});
```

If you would rather serve the page yourself, `docsHtml`, `writeDocsHtml`, and
`respondDocs` return, stream, or send the same HTML with the same `DocsOptions`.

## Non-JSON behavior

`zchema` only touches JSON. HTML, bytes, files, redirects, streaming, and
WebSockets pass straight through to the stdlib:

```zig
try req.respond(bytes, .{
    .status = .ok,
    .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }},
});
```

## Errors

Boundary failures produce an `ErrorBody` following RFC 9457
(`application/problem+json`): `type`, `title`, `status`, `detail`, and an
`errors` array of `{pointer, message}` (JSON Pointer per field). Covered cases:
invalid JSON (400), validation failure (422), unsupported content type (415),
and body too large (413).

```json
{
  "type": "about:blank",
  "title": "Unprocessable Entity",
  "status": 422,
  "detail": "Request body failed validation.",
  "errors": [{ "pointer": "/name", "message": "unexpected property" }]
}
```

`respondError(arena, req, err, .{})` maps a caught zchema error to this body;
`errorBody(status, detail, fields)` plus `respondErrorBody` send a custom one.
Declare your own error body types as response cases when you need more.

## Develop

```sh
mise run test        # zig build test, including example compilation
mise run check       # formatting checks plus tests
zig build run        # print the demo API's OpenAPI document
zig build run-users_api
zig build run-migration
```

## License

[MIT](LICENSE)
