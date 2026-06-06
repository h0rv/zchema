//! A concurrent server: zchema owns the contracts, you own the loop. This runs a
//! fixed pool of worker threads that each accept on the shared listening socket
//! (the kernel load-balances), so concurrency is bounded and there is no
//! per-connection thread churn. Shared state must be synchronized; here an
//! atomic guards the counter.
//!
//! Requires a thread-safe Io backend. The default `init.io` is `std.Io.Threaded`,
//! which qualifies.
//! For an event loop (io_uring/kqueue), run a single-threaded reactor instead.
//!
//! Try: hey -n 10000 -c 50 -m POST http://localhost:8080/incr

const std = @import("std");
const z = @import("zchema");

const worker_count = 4;

const Count = struct {
    value: u64,
    pub const jsonschema = .{ .name = "Count" };
};

const Counter = struct {
    n: std.atomic.Value(u64) = .init(0),

    fn incr(self: *Counter) Count {
        return .{ .value = self.n.fetchAdd(1, .monotonic) + 1 };
    }

    fn read(self: *Counter) Count {
        return .{ .value = self.n.load(.monotonic) };
    }
};

fn bump(c: *Counter) !Count {
    return c.incr();
}

fn current(c: *Counter) !Count {
    return c.read();
}

const Api = z.Api(.{
    z.post("/incr", bump),
    z.get("/count", current),
});

const Server = z.App(Api, .{ .openapi = .{ .title = "Counter", .version = "1.0.0" } });

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var counter: Counter = .{};

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("counter on http://127.0.0.1:8080 with {d} workers", .{worker_count});

    var threads: [worker_count - 1]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{ io, gpa, &counter, &listener });
    worker(io, gpa, &counter, &listener); // the main thread is a worker too
    for (threads) |t| t.join();
}

fn worker(io: std.Io, gpa: std.mem.Allocator, counter: *Counter, listener: *std.Io.net.Server) void {
    while (true) {
        const stream = listener.accept(io) catch continue;
        serveConnection(io, gpa, counter, stream);
    }
}

fn serveConnection(io: std.Io, gpa: std.mem.Allocator, counter: *Counter, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &recv);
    var sw = stream.writer(io, &send);
    var http = std.http.Server.init(&sr.interface, &sw.interface);

    while (true) {
        var req = http.receiveHead() catch return;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (Server.handle(counter, arena, &req, .{}) catch return) continue;
        z.respondErrorBody(arena, &req, z.errorBody(.not_found, "No matching route.", &.{}), .{}) catch return;
    }
}
