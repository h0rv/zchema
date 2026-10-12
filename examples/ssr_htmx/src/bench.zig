//! External load generator: always std.Io.Threaded, whichever server it targets.
//! CLI: catalog-bench <path> <requests> <concurrency> [htmx]
const std = @import("std");
const builtin = @import("builtin");

const Load = struct {
    io: std.Io,
    path: []const u8,
    htmx: bool,
    expected: []const u8,
    latencies: []u64,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
};

fn exchange(io: std.Io, arena: std.mem.Allocator, path: []const u8, htmx: bool) ![]const u8 {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var send: [1024]u8 = undefined;
    var writer = stream.writer(io, &send);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: localhost\r\n{s}\r\n", .{ path, if (htmx) "HX-Request: true\r\n" else "" });
    try writer.interface.flush();
    var recv: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv);
    const raw = try reader.interface.allocRemaining(arena, .limited(64 * 1024));
    if (!std.mem.startsWith(u8, raw, "HTTP/1.1 200 ")) return error.UnexpectedStatus;
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse;
    return raw[split + 4 ..];
}

fn worker(load: *Load) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    while (true) {
        const i = load.next.fetchAdd(1, .monotonic);
        if (i >= load.latencies.len) return;
        defer _ = arena.reset(.retain_capacity);
        const begin = std.Io.Timestamp.now(load.io, .awake);
        const body = exchange(load.io, arena.allocator(), load.path, load.htmx) catch {
            _ = load.failures.fetchAdd(1, .monotonic);
            load.latencies[i] = @intCast(begin.durationTo(std.Io.Timestamp.now(load.io, .awake)).nanoseconds);
            continue;
        };
        if (!std.mem.eql(u8, body, load.expected)) _ = load.failures.fetchAdd(1, .monotonic);
        load.latencies[i] = @intCast(begin.durationTo(std.Io.Timestamp.now(load.io, .awake)).nanoseconds);
    }
}

fn runLoad(load: *Load, concurrency: usize) !void {
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(load.io);
    for (0..concurrency) |_| try tasks.concurrent(load.io, worker, .{load});
    try tasks.await(load.io);
}

fn watchdog(io: std.Io) void {
    io.sleep(.fromSeconds(60), .awake) catch return;
    @panic("benchmark exceeded 60 seconds; discard this incomplete run");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4 or args.len > 5) return error.UsageExpectedPathRequestsConcurrencyAndOptionalHtmx;
    const count = try std.fmt.parseInt(usize, args[2], 10);
    const concurrency = try std.fmt.parseInt(usize, args[3], 10);
    if (count == 0 or count > 1_000_000 or concurrency == 0 or concurrency > 128) return error.InvalidLoad;
    if (args.len == 5 and !std.mem.eql(u8, args[4], "htmx")) return error.InvalidMode;
    const htmx = args.len == 5;
    var deadline = try io.concurrent(watchdog, .{io});
    defer deadline.cancel(io);
    const expected = try exchange(io, arena, args[1], htmx);
    // Warm routes, schema caches, and client/server workers at the measured concurrency.
    var load: Load = .{ .io = io, .path = args[1], .htmx = htmx, .expected = expected, .latencies = try arena.alloc(u64, 200) };
    try runLoad(&load, concurrency);
    if (load.failures.load(.monotonic) != 0) return error.WarmupFailures;
    load.next.store(0, .monotonic);
    load.latencies = try arena.alloc(u64, count);
    const begin = std.Io.Timestamp.now(io, .awake);
    try runLoad(&load, concurrency);
    const duration = begin.durationTo(std.Io.Timestamp.now(io, .awake));
    std.mem.sort(u64, load.latencies, {}, std.sort.asc(u64));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(expected, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    const failures = load.failures.load(.monotonic);
    const seconds = @as(f64, @floatFromInt(duration.nanoseconds)) / 1e9;
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try std.json.Stringify.value(.{
        .path = args[1],
        .htmx = htmx,
        .requests = count,
        .concurrency = concurrency,
        .errors = failures,
        .seconds = seconds,
        .requests_per_second = @as(f64, @floatFromInt(count - failures)) / seconds,
        .p50_us = load.latencies[(count - 1) / 2] / 1000,
        .p95_us = load.latencies[(count - 1) * 95 / 100] / 1000,
        .body_sha256 = @as([]const u8, &hex),
        .zig = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (failures != 0) return error.RequestFailures;
}
