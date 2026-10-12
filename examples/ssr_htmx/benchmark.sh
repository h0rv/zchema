#!/usr/bin/env bash
# Run after: zig build benchmark -Dzio=true -Doptimize=ReleaseFast
# Each JSON line is one measured run. No Python, curl, or external load tool.
set -euo pipefail
cd "$(dirname "$0")"
server_pid=
stop_server() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=
    fi
}
trap stop_server EXIT
for ((round=1; round<=${ROUNDS:-5}; round++)); do
    if ((round % 2)); then order="std zio"; else order="zio std"; fi
    for backend in $order; do
        exe=./zig-out/bin/ssr-htmx
        if [[ "$backend" == zio ]]; then exe=./zig-out/bin/ssr-htmx-zio; fi
        "$exe" >&2 &
        server_pid=$!
        # Probe outside measured runs, allowing startup up to five seconds.
        ready=false
        for ((attempt=0; attempt<50; attempt++)); do
            kill -0 "$server_pid"
            if (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then ready=true; break; fi
            sleep 0.1
        done
        if [[ "$ready" != true ]]; then echo "Server did not start" >&2; exit 1; fi
        for concurrency in 1 8; do
            for representation in json page fragment; do
                target='/?q=HTTP&category=books'
                args=()
                if [[ "$representation" == json ]]; then target='/api/catalog?q=HTTP&category=books'; fi
                if [[ "$representation" == fragment ]]; then args=(htmx); fi
                status=0
                result=$(./zig-out/bin/catalog-bench "$target" "${REQUESTS:-5000}" "$concurrency" "${args[@]}") || status=$?
                if [[ -z "$result" ]]; then echo "Benchmark produced no complete metrics" >&2; exit 1; fi
                printf '{"runtime":"%s","round":%s,"metrics":%s}\n' "$backend" "$round" "$result"
                if ((status)); then exit "$status"; fi
            done
        done
        stop_server
    done
done
