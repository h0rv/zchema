# zchema

Typed, validated JSON APIs and OpenAPI 3.1 for Zig's `std.http.Server`.

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
zig fetch --save "git+https://github.com/h0rv/zchema.git"
```

Wire both modules into `build.zig`:

```zig
const jsonschema = b.dependency("jsonschema", .{ .target = target, .optimize = optimize });
const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zchema", zchema.module("zchema"));
```

The snippets below import the module under a short alias:

```zig
const z = @import("zchema");
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
const input = z.jsonBody(Echo, arena, &req, .{}) catch |err|
    return z.respondError(arena, &req, err, .{});
try z.respondJson(Greeting, arena, &req, .ok, .{ .message = input.name }, .{});
```

`jsonBody` reads the body under a byte limit, validates it against the schema
emitted from `Echo`, then parses. `respondError` turns a zchema error into a
structured JSON body. See `examples/migration.zig`.

## Registered routes and markers

The handler signature is the contract. Markers tell the dispatcher what each
parameter and the return type mean, and the same information drives OpenAPI:

- `Body(T)`: parsed and validated request body.
- `Path(T)`: path params, parsed from the `{...}` segments into `T`.
- `Query(T)`: query params, parsed into `T` (fields with a default or `?T` are optional).
- `*std.http.Server.Request`: the raw request. `std.mem.Allocator`: the per-request arena.
- Return type: `Created(T)`/`Status(code, T)` for a fixed status, a plain `T` for 200,
  or `!?T` for "200 with T, or 404".

```zig
const Api = z.Api(.{
    z.post("/users", createUser),
    z.get("/users", listUsers),
    z.get("/users/{id}", getUser),
    z.delete("/users/{id}", deleteUser),
});

fn createUser(store: *Store, body: z.Body(CreateUser)) !z.Created(User) {
    return .{ .value = try store.create(body.value.name) };
}

fn listUsers(store: *Store, page: z.Query(struct { limit: u32 = 50 })) ![]const User {
    return store.list(page.value.limit);
}

fn getUser(store: *Store, path: z.Path(struct { id: u32 })) !?User {
    return store.find(path.value.id); // null -> 404
}
```

No explicit contracts are needed for the common cases above. Path and query are
parsed before the body, so they stay valid even though reading the body
invalidates `req.head`. Invalid params return a 422 with per-field detail.

## Explicit contracts

Reach for these only when the signature cannot express it: extra response cases,
or naming a body type that is not a `Body(T)` param. Declare contracts and attach
them with `op` (or `route(...).with(...)`):

```zig
const CreateUserResponse = z.Response(.{
    z.case(.created, User),
    z.case(.unprocessable_entity, z.ErrorBody),
});

const Api = z.Api(.{
    z.op(.POST, "/users", createUser, .{ .response = CreateUserResponse }),
});
```

## Serving

`z.serve` owns the accept loop, per-connection lifecycle, and per-request
arena, with a default 404 for unmatched requests:

```zig
const Server = z.App(Api, .{ .openapi = .{ .title = "Users API", .version = "1.0.0" } });

pub fn main(init: std.process.Init) !void {
    var store: Store = .{ .gpa = init.gpa };
    try z.serve(Server, init.io, init.gpa, &store, .{ .port = 8080 });
}
```

`ServeOptions` takes `host`, `port`, an `on_not_found` override, and the dispatch
options. For full control over the socket, threading, or non-JSON behavior, skip
`serve` and call `Server.handle(ctx, arena, &req, .{})` in your own loop; it
returns `false` when nothing matched.

Non-JSON endpoints live in the same table via `z.raw`, which takes the raw
request, responds itself, and is excluded from OpenAPI:

```zig
z.raw(.GET, "/health", health) // fn health(req: *std.http.Server.Request) !void
```

See `examples/users_api.zig` for the full CRUD service in ~120 lines.

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
const doc = try z.openApiJson(Api, allocator, .{ .title = "Users API", .version = "1.0.0" });
// or stream it: try z.writeOpenApi(Api, writer, .{});
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
const Server = z.App(Api, .{
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
z.App(Api, .{
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
z.App(Api, .{
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
