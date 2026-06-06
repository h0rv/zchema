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
zig fetch --save "git+https://github.com/h0rv/zchema.git"
```

Wire the module into `build.zig`:

```zig
const zchema = b.dependency("zchema", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zchema", zchema.module("zchema"));
```

`jsonschema` is pulled in automatically as a transitive dependency of
`zchema`, so you do not need to fetch or wire it yourself.

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
structured JSON body. These helpers work inside any existing handler; you do not
need to register routes to use them.

## Registered routes and markers

The handler signature is the contract. Markers tell the dispatcher what each
parameter and the return type mean, and the same information drives OpenAPI:

- `Body(T)`: parsed and validated request body.
- `Path(T)`: path params, parsed from the `{...}` segments into `T`.
- `Query(T)`: query params, parsed into `T` (fields with a default or `?T` are optional).
- `Header("name")`: one request header (case-insensitive) as `value: ?[]const u8`;
  the name is in the type, so it is also documented as an OpenAPI header parameter.
  For dynamic or case-sensitive lookups use `z.header(req, name)` /
  `z.headerWith(req, name, .sensitive)` on a `*Request`.
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

zchema owns the contracts, not the server. You run `std.http.Server` and call
`Server.handle` per request; it returns `false` when nothing matched, so you stay
in control of the loop, threading, and socket lifecycle:

```zig
const Server = z.App(Api, .{ .openapi = .{ .title = "Users API", .version = "1.0.0" } });

fn serveConnection(io: std.Io, gpa: std.mem.Allocator, ctx: *Ctx, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &recv);
    var sw = stream.writer(io, &send);
    var http = std.http.Server.init(&sr.interface, &sw.interface);
    while (true) {
        var req = http.receiveHead() catch return;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (Server.handle(ctx, arena, &req, .{}) catch return) continue;
        z.respondErrorBody(arena, &req, z.errorBody(.not_found, "No matching route.", &.{}), .{}) catch return;
    }
}
```

`examples/users_api.zig` is the full single-threaded version; `examples/threaded.zig`
runs a fixed pool of worker threads accepting on a shared socket (the default
`init.io` is `std.Io.Threaded`, which is safe to share across threads). For an
event loop, drive `handle` from a single-threaded io_uring/kqueue reactor.

Non-JSON endpoints live in the same table via `z.raw`, which takes the raw
request, responds itself, and is excluded from OpenAPI:

```zig
z.raw(.GET, "/health", health) // fn health(req: *std.http.Server.Request) !void
```

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

## Use with other servers (http.zig, etc.)

The validation and schema layers do not depend on `std.http`; they work on raw
bytes and Zig types. So even if you serve with another library such as
[http.zig](https://github.com/karlseguin/http.zig), you can still validate
requests and responses against your types:

```zig
// request: validate raw body bytes into a typed value
const input = try z.parseAndValidate(CreateUser, req.arena, req.body() orelse "", null);

// response: serialize (and optionally validate) a value to JSON bytes
res.body = try z.serializeAndValidate(User, res.arena, user, false);
res.content_type = .JSON;

// schemas for your own OpenAPI assembly
const schema = z.schemaText(CreateUser);
```

What does not carry over: the dispatcher, the markers, and `App` are tied to
`std.http.Server.Request` and assume zchema owns routing. http.zig has its own
router and request/response types, so pairing two routers is not worth it.
Auto-OpenAPI (`z.openApiJson`) reads a zchema `Api` route table, so full spec
generation stays with zchema's router; with another server you assemble the
document from `schemaText`/`schemaName` yourself.

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
