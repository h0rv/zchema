# SSR + HTMX catalog

A standalone example combining zchema's typed JSON routes with [zt](https://github.com/lalinsky/zt)'s build-time HTML templates. One search function and the same `Search`/`Item` types serve JSON and HTML; no framework or template-schema coupling is needed.

```sh
# Zig 0.16.0 (the repository's .mise.toml version)
cd examples/ssr_htmx
zig build test
zig build run
```

Open http://127.0.0.1:8080. Search works as an ordinary GET form without JavaScript. When the pinned HTMX CDN script loads, submitting updates only the results. Visit `/api/catalog?q=HTTP&category=books` for the same search as JSON, `/openapi.json` for its generated contract, and `/docs` for the docs UI.

| Piece | Responsibility |
| --- | --- |
| `catalog.zig` | Shared types and search; no HTTP or HTML dependencies |
| `z.get` + `z.Query(Search)` | Parse typed query parameters, serialize JSON, generate OpenAPI |
| `z.raw` | Compose an HTML route alongside JSON routes; omitted from OpenAPI |
| `pages.zt` | Type-checked presentation with default text/attribute escaping |
| `http.zig` | Own sockets and one arena per request; expose a borrowed context and HTML response helper |
| `main.zig` | Select `std.Io` and start the server |

The HTML route returns a full document normally and a results fragment for `HX-Request: true`. Both responses include `Vary: HX-Request`. Output is buffered in a request arena before writing HTTP headers. User text is never inserted as raw HTML. The catalog deliberately contains a script-looking title to exercise escaping.

The browser's `maxlength` is a convenience, not server-side validation. Zchema query markers parse types, defaults, and enums; they do not apply arbitrary JSON Schema constraints. A manually supplied invalid category returns zchema's JSON 422 response before either handler runs. HTMX leaves the previous results intact on that error. Unknown paths and unsupported methods return 404 in this example. No state-changing route is present.

## Dependencies and runtime boundaries

This package uses the repository via a relative path and pins zt to `fe662f38c5f5d493c5397342ffd9ed438af3b7c9` (0.2.0 source). Zt stays an example-only dependency; the root library and existing examples do not acquire a template compiler. The `v0.2.0` tag resolves to that exact pin. Its generated `src/pages.zig` is ignored and regenerated before both build and test. HTMX 2.0.8 is loaded from jsDelivr; the ordinary form works if that external asset is unavailable.

`zig build test` includes real TCP exchanges on ephemeral loopback ports, malformed parameters, URL decoding, full pages versus fragments, routes/OpenAPI, and connection closure. The test allocator verifies per-request memory is released. No Python or browser tooling is required.

Handlers receive a `http.Context` with a borrowed arena and `html` helper. `http.zig` creates and destroys the arena around each response; request data must not escape that scope.

The default executable uses Zig 0.16.0's `std.process.Init.io`. Zt writes to `std.Io.Writer`; zchema works with `std.http.Server.Request`. Neither chooses an I/O backend. Both executable variants use the same `std.Io.Group.concurrent` accept loop and one request per connection. Each task owns its socket and request arena. Cancellation of the accept loop cancels and joins outstanding tasks before destroying the listener/runtime. There are no connection deadlines or admission limits; this remains a small demo. The CLI does not install a graceful OS-signal handler.

## Optional Zio runtime

[Zio](https://github.com/lalinsky/zio) v0.19.1 is a lazy, example-only dependency. Enable it to run the same HTTP handlers and templates with `Runtime.io()`:

```sh
zig build test -Dzio=true # test both runtimes
zig build run-zio -Dzio=true
```

From the repository root, use `mise run test-zio` and `mise run ssr-zio`. Without `-Dzio=true`, this package uses the standard runtime and does not fetch Zio.

The tests cover blocked socket reads and cancellation during an active handler, checking socket closure and request-arena cleanup on both runtimes. The connection owner recovers `Canceled` from concrete stream errors when `ReadFailed` or `WriteFailed` erases it. Zchema propagates these transport errors without attempting another response; ordinary application errors still produce HTTP 500.

Use the repository's pinned Zig 0.16.0 toolchain. Zio v0.19.1 targets that version. The example's HTTP task group has no admission limits or connection deadlines, and the executable does not install an OS-signal handler for graceful shutdown.

For Dusty-owned request arenas and connection management, see [the Dusty + Zio example](../dusty_htmx). It reuses this catalog module and template source with zchema’s server-independent validation and OpenAPI APIs.
