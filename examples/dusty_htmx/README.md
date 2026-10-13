# Dusty + Zio catalog

The same catalog and HTMX form as `../ssr_htmx`, served by Dusty with Zio. Both examples share the catalog types, search function, and zt template source. Dusty owns request arenas, sockets, connection tasks, and response buffering; handlers borrow `req.arena` without creating or freeing a request arena.

From the repository root:

```sh
mise install
mise run check
mise run dusty
```

Or run this example directly with Zig 0.16.0:

```sh
cd examples/dusty_htmx
zig build test
zig build run
```

Open http://127.0.0.1:8080. The GET form works without JavaScript; HTMX replaces the results when available. `/api/catalog` serves JSON, `/openapi.json` serves its contract, and `/docs` serves the documentation UI.

## Application responsibilities

| Work | Owner |
| --- | --- |
| Request arenas, sockets, concurrent connections, keep-alive, deadlines, shutdown | Dusty |
| I/O runtime | Zio, explicitly injected into Dusty's module |
| Search types and application logic | Shared catalog module |
| Escaped HTML and attribute rendering | Shared zt templates, written directly to `res.writer()` |
| Query and response validation, OpenAPI generation | Zchema's server-independent APIs |
| Route registration and query-to-schema adaptation | Application |

Dusty does not remove every string operation. `req.query` supplies decoded string slices; this example adapts its two fields to a JSON object for `parseAndValidate`. JSON response bytes are allocated in `req.arena` by `serializeAndValidate`, with validation enabled. HTML goes straight to Dusty's buffered writer. No per-request `free` or arena reset is required in the handlers. OpenAPI and docs are generated once at startup and freed after the server stops.

`z.App` and `z.Query` use std.http request types, so this example uses a handler-free `Spec` and registers Dusty routes explicitly. The API path constant is shared by the Spec and router, and tests check the served contract. Numeric, boolean, or repeated query parameters would require an explicit coercion policy beyond this two-field adapter.

For a basic app, `z.App` has less contract wiring. Dusty is useful when the application needs its HTTP lifecycle policies without maintaining a custom accept loop, request arenas, and cancellation plumbing. The core zchema library acquires no Dusty or Zio dependency.

## Dependencies and behavior

This package pins Dusty v0.4.0, Zio v0.19.1, and zt v0.2.0 on Zig 0.16.0. The catalog is a local dependency on `../ssr_htmx`; build from a repository checkout. Dusty's vendored llhttp parser links libc. TLS and compression are compiled out for this localhost example.

The server uses Dusty's defaults: keep-alive and pipelining, a 10,000-connection limit, 30-second request timeout, 60-second idle timeout, and 30-second shutdown budget. The CLI does not install an OS-signal handler; structured shutdown is tested by canceling `Server.run`. TLS, compression, admission saturation, and production load behavior are outside these tests.

`zig build test` covers real loopback HTTP, full pages and fragments, escaping, malformed input, validated JSON responses, OpenAPI parameter names and 200/422 responses, HEAD and missing routes, pipelining, concurrent requests, and cancellation of an active handler and incomplete request head. Allocator checks verify cleanup. The shutdown test intentionally uses a short drain budget to exercise forced cancellation.
