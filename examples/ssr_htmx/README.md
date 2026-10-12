# SSR + HTMX catalog

A standalone example combining zchema's typed JSON routes with [zt](https://github.com/lalinsky/zt)'s build-time HTML templates. One search function and the same `Search`/`Item` types serve JSON and HTML; no framework or template-schema coupling is needed.

```sh
# Zig 0.16.0 (the repository's .mise.toml version)
cd examples/ssr_htmx
zig build test
zig build run
# In another terminal:
python3 test_http.py
```

Open http://127.0.0.1:8080. Search works as an ordinary GET form without JavaScript. When the pinned HTMX CDN script loads, submitting updates only the results. Visit `/api/catalog?q=HTTP&category=books` for the same search as JSON, `/openapi.json` for its generated contract, and `/docs` for the docs UI.

| Piece | Responsibility |
| --- | --- |
| `catalog.zig` | Shared types and search; no HTTP or HTML dependencies |
| `z.get` + `z.Query(Search)` | Parse typed query parameters, serialize JSON, generate OpenAPI |
| `z.raw` | Compose an HTML route alongside JSON routes; omitted from OpenAPI |
| `pages.zt` | Type-checked presentation with default text/attribute escaping |
| `serve(io, allocator)` | Own sockets, HTTP connections, and the runtime choice |

The HTML route returns a full document normally and a results fragment for `HX-Request: true`. Both responses include `Vary: HX-Request`. Output is buffered in a request arena before writing HTTP headers. User text is never inserted as raw HTML. The catalog deliberately contains a script-looking title to exercise escaping.

The browser's `maxlength` is a convenience, not server-side validation. Zchema query markers parse types, defaults, and enums; they do not apply arbitrary JSON Schema constraints. A manually supplied invalid category returns zchema's JSON 422 response before either handler runs. HTMX leaves the previous results intact on that error. Unknown paths and unsupported methods return 404 in this example. No state-changing route is present.

## Dependencies and runtime boundaries

This package uses the repository via a relative path and pins zt to `fe662f38c5f5d493c5397342ffd9ed438af3b7c9` (0.2.0 source). Zt stays an example-only dependency; the root library and existing examples do not acquire a template compiler. Its generated `src/pages.zig` is ignored and regenerated before both build and test. HTMX 2.0.8 is loaded from jsDelivr; the ordinary form works if that external asset is unavailable.

The executable uses Zig 0.16.0's `std.process.Init.io`. Zt writes to `std.Io.Writer`; zchema works with `std.http.Server.Request`. Neither chooses an I/O backend. This intentionally serial demo handles one request per connection and closes it, avoiding an idle keep-alive connection monopolizing the loop. It has no connection deadlines or production concurrency policy.

[Zio](https://github.com/lalinsky/zio) implements `std.Io`, so it belongs at the `serve` boundary. Its current main branch requires Zig 0.17; Zig 0.16 users need the project's 0.19.x line or `zig-0.16` branch. This example does not include or test zio. Runtime substitution also needs cancellation/shutdown verification: zchema currently translates handler errors to HTTP 500, and generic writer failures may hide underlying transport cancellation.

[Dusty](https://github.com/lalinsky/dusty) has its own request, response, and router types. It cannot directly replace `std.http.Server` underneath `z.App`. A Dusty integration would use zchema's server-independent `parseAndValidate`, `serializeAndValidate`, and `Spec`/`endpoint` helpers, as the existing `byo_server.zig` example illustrates. Datastar could consume templates through a separate response adapter, but its protocol is not implemented here. No performance claims are made.
