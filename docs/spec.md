# contractz Declarative Spec

## Purpose

`contractz` is a thin typed-contract layer for Zig's standard HTTP server.

It must preserve direct use of `std.http.Server` while adding JSON-focused
request parsing, response serialization, JSON Schema validation, and OpenAPI 3.1
generation.

The design goal is not to create a full web framework. The design goal is to
make boundary contracts explicit and reusable:

- request body shape
- response body shape
- status codes
- validation behavior
- OpenAPI operation metadata

## Core Principles

1. Keep `std.http.Server.Request` available everywhere.
2. Do not own the accept loop, socket lifecycle, threading model, or server
   lifecycle.
3. JSON is enhanced. Non-JSON HTTP behavior passes through.
4. Route registration is required for OpenAPI generation.
5. Comptime reflection should infer what it can from Zig types and handler
   signatures.
6. Explicit declarations are preferred over magic.
7. Unsupported or ambiguous contract shapes should fail at comptime when
   possible.

## Non-Goals

`contractz` must not:

- replace `std.http.Server`
- hide `std.Io`, `std.Io.net`, or `std.http.Server.Request`
- provide Python-style decorators
- auto-discover every route in a package
- require code generation for the core API
- wrap every possible response type
- force HTML, text, files, streaming, redirects, or WebSockets into framework
  abstractions
- implement OpenAPI 3.0 schema down-conversion

## Layer 1: Helper Functions

Layer 1 is the migration layer for existing stdlib handlers.

Users keep their current routing and call helpers where they want JSON contracts.

```zig
if (req.head.method == .POST and contractz.pathEql(&req, "/users")) {
    const input = try contractz.jsonBody(CreateUser, arena, &req, .{});
    const user = try createUser(&store, input);
    return contractz.respondJson(User, arena, &req, .created, user, .{});
}
```

Required helpers:

```zig
pub fn body(req: *std.http.Server.Request, arena: std.mem.Allocator, opts: BodyOptions) ![]const u8;

pub fn jsonBody(
    comptime T: type,
    arena: std.mem.Allocator,
    req: *std.http.Server.Request,
    opts: BodyOptions,
) !T;

pub fn respondJson(
    comptime T: type,
    arena: std.mem.Allocator,
    req: *std.http.Server.Request,
    status: std.http.Status,
    value: T,
    opts: ResponseOptions,
) !void;
```

Layer 1 behavior:

- `body` reads the request body with a hard byte limit.
- `jsonBody` parses JSON and validates it against the schema emitted from `T`.
- `respondJson` serializes `T` and may optionally validate the serialized JSON.
- Layer 1 does not generate OpenAPI by itself.

## Layer 2: Route Table and Signature Markers

Layer 2 adds declarative route registration.

Route registration is the minimum requirement for OpenAPI generation.

```zig
const Api = contractz.Api(.{
    contractz.post("/users", createUser),
});

fn createUser(ctx: *Ctx, body: contractz.Body(CreateUser)) !contractz.Created(User) {
    return .{ .value = try ctx.store.create(body.value) };
}
```

Required route API:

```zig
pub fn get(comptime path: []const u8, comptime handler: anytype) Route;
pub fn post(comptime path: []const u8, comptime handler: anytype) Route;
pub fn put(comptime path: []const u8, comptime handler: anytype) Route;
pub fn patch(comptime path: []const u8, comptime handler: anytype) Route;
pub fn delete(comptime path: []const u8, comptime handler: anytype) Route;

pub fn Api(comptime routes: anytype) type;
```

Required marker types:

```zig
pub fn Body(comptime T: type) type;
pub fn Created(comptime T: type) type;
pub fn Status(comptime status: std.http.Status, comptime T: type) type;
```

Layer 2 inference:

- method and path come from route registration
- request body comes from `Body(T)`
- response status and schema come from `Created(T)` or `Status(status, T)`
- other handler params are passed through from the caller/context system
- raw `*std.http.Server.Request` may appear in handler params and must be
  passed through unchanged

Layer 2 OpenAPI:

- every registered route becomes one OpenAPI operation
- JSON request bodies get schemas from `jsonschema.zig`
- JSON responses get schemas from return marker types
- OpenAPI target is 3.1

## Layer 3: Explicit Request and Response Contracts

Layer 3 is the most declarative API.

It is intended for production APIs that need multiple response cases, structured
error bodies, path/query/body contracts, and complete OpenAPI output.

```zig
const CreateUserRequest = contractz.Request(.{
    .body = CreateUser,
});

const CreateUserResponse = contractz.Response(.{
    contractz.case(.created, User),
    contractz.case(.bad_request, Problem),
    contractz.case(.unprocessable_entity, ValidationProblem),
});

const Api = contractz.Api(.{
    contractz.post("/users", createUser, .{
        .request = CreateUserRequest,
        .response = CreateUserResponse,
    }),
});
```

Required contract API:

```zig
pub fn Request(comptime spec: anytype) type;
pub fn case(comptime status: std.http.Status, comptime T: type) ResponseCase;
pub fn Response(comptime cases: anytype) type;
```

Initial `Request` spec fields:

```zig
.{
    .path = PathParams,   // optional
    .query = QueryParams, // optional
    .body = BodyType,     // optional
}
```

Initial `Response` behavior:

- cases map status codes to response body types
- body types are JSON by default
- error responses are ordinary Zig structs with schemas
- multiple response statuses are represented in OpenAPI

## Base Model Equivalent

Zig does not have superclasses or inheritance.

The equivalent of Pydantic/FastAPI base models is:

- plain Zig structs for data
- `pub const jsonschema = .{ ... }` for schema metadata
- generic contract wrappers for HTTP meaning
- comptime validation of required declarations

Example model:

```zig
const CreateUser = struct {
    name: []const u8,

    pub const jsonschema = .{
        .fields = .{
            .name = .{ .minLength = 1 },
        },
    };
};
```

Example HTTP contract:

```zig
const CreateUserResponse = contractz.Response(.{
    contractz.case(.created, User),
    contractz.case(.unprocessable_entity, ValidationProblem),
});
```

Do not put route method/path metadata on reusable data models. Models are often
used by multiple endpoints.

## JSON Validation Semantics

For full JSON Schema validation:

1. read the request body with a byte limit
2. parse the body as `std.json.Value`
3. validate with `jsonschema.Validator`
4. parse into `T` only after validation succeeds

`jsonschema.validateValue` may be used as a convenience path, but it is not a
full JSON Schema validator. The full validator over `std.json.Value` should be
used for boundary validation.

Response validation should serialize to JSON, parse or otherwise inspect the
serialized value, and validate against the response schema when enabled.

## Non-JSON HTTP Behavior

`contractz` enhances JSON only.

Everything else should pass through to stdlib APIs:

- HTML
- text
- bytes
- blobs
- files
- redirects
- streaming
- WebSockets
- custom headers
- custom transfer behavior

Example:

```zig
fn download(req: *std.http.Server.Request) !void {
    try req.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
        },
    });
}
```

`contractz` may provide tiny convenience helpers, but those helpers must not
limit or replace raw stdlib behavior.

## OpenAPI Generation

OpenAPI generation requires Layer 2 or Layer 3 route registration.

Required API:

```zig
pub fn openApiJson(comptime Api: type, allocator: std.mem.Allocator, opts: OpenApiOptions) ![]u8;
pub fn writeOpenApi(comptime Api: type, writer: *std.Io.Writer, opts: OpenApiOptions) !void;
```

OpenAPI rules:

- generate OpenAPI 3.1
- use JSON Schema emitted from Zig types
- include request bodies from `Body(T)` or `Request(.{ .body = T })`
- include response bodies from return markers or `Response(...)`
- include multiple error responses for Layer 3 contracts
- avoid OpenAPI 3.0 unless a later down-conversion layer is explicitly added

The implementation should precompute as much as possible at comptime:

- route method/path metadata
- handler signature analysis
- request/response contract shapes
- schema names and schema emission plans

Runtime can still allocate the final JSON document unless a later API provides
fully static output.

## Stdlib Integration Requirements

The following stdlib surfaces must remain usable by applications:

- `std.Io`
- `std.Io.net`
- `std.http.Server`
- `std.http.Server.Request`
- `Request.respond`
- `Request.respondStreaming`
- `Request.respondWebSocket`
- `Request.readerExpectContinue`
- `Request.readerExpectNone`
- `Request.iterateHeaders`

Handlers should be allowed to accept `*std.http.Server.Request` directly.

`contractz` must not assume it owns:

- socket accept loop
- connection lifetime
- concurrency model
- request dispatch outside registered routes
- all response serialization

## Error Handling

Default JSON error behavior should produce structured JSON bodies for:

- invalid JSON
- schema validation failure
- unsupported content type
- body too large

Layer 3 should allow applications to declare their own error response body
types.

Validation errors should preserve JSON Pointer paths from `jsonschema.Validator`
where available.

## Expected Implementation Order

1. Implement Layer 1 helpers.
2. Implement response/request validation for JSON only.
3. Implement Layer 2 route table and marker signature reflection.
4. Implement OpenAPI 3.1 generation from Layer 2.
5. Implement Layer 3 request/response contracts.
6. Add multi-response OpenAPI generation.
7. Add optional convenience helpers, without reducing stdlib pass-through.

## Success Criteria

The first useful version should allow:

```zig
const Api = contractz.Api(.{
    contractz.post("/users", createUser),
});

fn createUser(ctx: *Ctx, body: contractz.Body(CreateUser)) !contractz.Created(User) {
    return .{ .value = try ctx.store.create(body.value) };
}
```

and should provide:

- request JSON validation
- response JSON validation
- OpenAPI 3.1 generation
- raw stdlib HTTP escape hatch
- no dependency on a custom server lifecycle

