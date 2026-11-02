# Dusty catalog

Use Zig 0.17.0 and run from the repository root:

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
Dusty v0.5.0 and zt v0.2.1 both test Zig 0.17.0 in upstream CI. Zio is pinned
to `57f8fa82e27c1c4cf8808efba7999332216e8658` on its Zig 0.17 `main` branch.
Its v0.19.x release tags target Zig 0.16 and cannot be substituted for that pin.
