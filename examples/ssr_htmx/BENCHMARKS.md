# Optional runtime comparison

Zio can replace the `std.Io` backend without changing zchema, templates, HTTP parsing, or application handlers. These short loopback measurements demonstrate an executable comparison; they do not establish a production throughput advantage.

## Reproduce

From the repository root, after `mise install`:

```sh
mise run test-zio
mise run benchmark > results.jsonl
```

Or from this directory:

```sh
zig build test -Dzio=true
zig build benchmark -Dzio=true -Doptimize=ReleaseFast
ROUNDS=5 REQUESTS=5000 bash benchmark.sh > results.jsonl
```

Port 8080 must be free. The script starts one server at a time, alternates runtime order each round, and stops it after all six cases. Process startup and readiness probing are excluded. Every case first gets its reference response, warms up with 200 requests at the measured concurrency, then measures 5,000 requests. Both variants use the same concurrent accept loop, one arena per request, one request per TCP connection, route data, templates, and ReleaseFast build. The external client is always the same Zig executable using `std.Io.Threaded`, with concurrency 1 or 8. It includes TCP setup, HTTP parsing/rendering, body reading, and exact body comparison in latency; it does not run browser JavaScript or fetch CDN assets.

Every response must be HTTP 200 and match its case's reference body. Cross-runtime body SHA-256 values must also agree. A failed measured request remains in the latency sample and error count, and fails the run after printing its metrics. A separate 60-second watchdog aborts a hung case; discard incomplete output. Zig 0.16's threaded POSIX connect implementation panics when a per-connect timeout is requested, so the client uses the whole-case watchdog instead. Server cancellation is tested separately; the benchmark script terminates processes and does not measure graceful OS-signal shutdown.

## Recorded sample: 2026-10-12

[All 60 raw runs](benchmarks/2026-10-12.jsonl): five rounds, 300,000 measured requests, zero errors. All body hashes agree for each representation across both runtimes. Zig 0.16.0, zt v0.2.0, Zio v0.19.1, Linux 6.18.44 x86_64 in a KVM container on AMD EPYC 9V74; five visible CPUs with a four-CPU cgroup quota. The client and server share that quota. Zio's default runtime has one executor; the threaded backend dynamically schedules workers. No CPU affinity, dedicated host, or CPU/RSS measurement was used.

Throughput is the median of five runs, with the minimum–maximum in parentheses. Latencies are medians of each run's p50/p95, not pooled percentiles.

| Response | Clients | Runtime | Requests/s, median (range) | p50 µs | p95 µs |
| --- | ---: | --- | ---: | ---: | ---: |
| JSON | 1 | Threaded | 16,732 (15,516–20,356) | 53 | 107 |
| JSON | 1 | Zio | 18,903 (17,563–19,785) | 47 | 90 |
| JSON | 8 | Threaded | 42,651 (42,081–52,407) | 157 | 372 |
| JSON | 8 | Zio | 44,064 (37,818–57,384) | 193 | 257 |
| Full page | 1 | Threaded | 17,680 (14,094–19,877) | 50 | 98 |
| Full page | 1 | Zio | 20,105 (15,508–21,016) | 40 | 90 |
| Full page | 8 | Threaded | 44,021 (37,175–49,968) | 154 | 367 |
| Full page | 8 | Zio | 49,339 (45,487–55,623) | 133 | 253 |
| Fragment | 1 | Threaded | 16,951 (15,733–19,351) | 49 | 102 |
| Fragment | 1 | Zio | 20,634 (16,219–22,733) | 40 | 78 |
| Fragment | 8 | Threaded | 47,312 (40,667–58,352) | 150 | 314 |
| Fragment | 8 | Zio | 47,878 (40,911–58,643) | 149 | 260 |

The ranges overlap substantially and cases finish in fractions of a second. The measurements show that both implementations serve equivalent responses successfully; they do not isolate runtime overhead or justify choosing a production backend. Longer runs on an otherwise idle host, separate clients, resource measurements, realistic keep-alive, and an explicit admission/deadline policy are needed for that decision.
