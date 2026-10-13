# Dusty catalog

Run from the repository root with Zig 0.16.0:

```sh
mise run dusty
```

Open http://127.0.0.1:8080. Search works as a normal GET form; with HTMX,
only the results are replaced. `/api/catalog` returns JSON, `/openapi.json`
its OpenAPI document, and `/docs` the API documentation.

This example serves the [same catalog and templates](../ssr_htmx) through
Dusty and Zio. zt escapes the HTML; zchema validates the search input and
JSON output. Dusty owns the request arenas and connection lifecycle.
OpenAPI and documentation HTML are generated once at startup.

The app passes Dusty's decoded query map to `z.decodeQuery`, with schema
validation enabled. It still registers routes and sends error responses.
`z.App` handles that wiring for std.http and is simpler for this small app. Dusty is an alternative when you want its routing,
timeouts, and connection management; it does not make zchema's std.http
handlers portable.

Run `zig build test` from this directory for the HTTP and cancellation tests.
Dependencies are pinned in `build.zig.zon`; TLS and compression are disabled.
