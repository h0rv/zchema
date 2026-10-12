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

## Optional Zio experiment

[Zio](https://github.com/lalinsky/zio) v0.19.1 is pinned as a lazy, example-only dependency. Its released `Runtime.io()` really substitutes for `std.Io`; it does not replace HTTP parsing, routes, templates, or allocators. Default Zio uses one executor, while `std.Io.Threaded` dynamically schedules workers. The two runtimes are not equivalent scheduling configurations.

```sh
zig build test -Dzio=true # run the same tests under both runtimes
zig build run-zio -Dzio=true
# From repository root: mise run test-zio / mise run ssr-zio
```

Tests cancel a blocked socket read and shut down the accept/task group during an active handler, asserting socket closure and allocator cleanup under both runtimes. An independent watchdog bounds hangs. Generic `ReadFailed`/`WriteFailed` erase concrete socket errors, so the connection owner restores `Canceled` from its reader/writer. Zchema now propagates those transport errors, including body-read failures, instead of attempting another HTTP error response. Ordinary application errors still produce HTTP 500.

For reproducible loopback measurements, see [BENCHMARKS.md](BENCHMARKS.md). The optional external load generator is written in Zig and runs identically for both servers; Bash only starts/stops processes and records results. No Python is required.

[Dusty](https://github.com/lalinsky/dusty) has its own request, response, and router types. It cannot directly replace `std.http.Server` underneath `z.App`. A Dusty integration would use zchema's server-independent `parseAndValidate`, `serializeAndValidate`, and `Spec`/`endpoint` helpers, as the existing `../byo_server/src/main.zig` example illustrates. Datastar could consume templates through a separate response adapter, but its protocol is not implemented here. No performance claims are made.

The latest stable Zig release is 0.17.0, but this checkout remains on 0.16.0: released jsonschema v0.2.0 still uses the removed `Build.args` API. Updating the compiler without compatible dependency releases does not currently build. Zt v0.2.0 and jsonschema v0.2.0 are their latest released versions. Zio v0.19.1 is also its latest release and targets Zig 0.16; its I/O vtable does not compile against 0.17. The experiment uses released compatible versions rather than tracking main or nightly.
