//! Real loopback HTTP tests; no separate server process or external test tools.

const std = @import("std");

const use_zio = @import("runtime_options").use_zio;
const zio = if (use_zio) @import("zio") else struct {};

const app = @import("app.zig");
const http = @import("http.zig");

const t = std.testing;

const Response = struct {
    bytes: []u8,
    head: []const u8,
    body: []const u8,
    status: u16,

    fn deinit(self: Response) void {
        t.allocator.free(self.bytes);
    }

    fn header(self: Response, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name))
                return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }
};

fn acceptOne(io: std.Io, listener: *std.Io.net.Server) !void {
    try http.serveConnection(io, t.allocator, try listener.accept(io), app.Server);
}

fn watchdog(io: std.Io) void {
    io.sleep(.fromSeconds(10), .awake) catch return;
    @panic("loopback HTTP test exceeded its 10-second deadline");
}

fn request(target: []const u8, htmx: bool, method: []const u8) !Response {
    var deadline = try t.io.concurrent(watchdog, .{t.io});
    defer deadline.cancel(t.io);

    const runtime = if (use_zio) try zio.Runtime.init(t.allocator, .{}) else {};
    defer if (use_zio) runtime.deinit();
    const io = if (use_zio) runtime.io() else t.io;

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{});
    defer listener.deinit(io);

    var task = try io.concurrent(acceptOne, .{ io, &listener });
    defer _ = task.cancel(io) catch {};

    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var send: [1024]u8 = undefined;
    var writer = stream.writer(io, &send);
    try writer.interface.print("{s} {s} HTTP/1.1\r\nHost: localhost\r\n{s}\r\n", .{
        method, target, if (htmx) "HX-Request: true\r\n" else "",
    });
    try writer.interface.flush();

    var recv: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv);
    // Reading to actual EOF verifies connection closure despite the client not
    // requesting Connection: close. The server allocator is leak-checked too.
    const bytes = try reader.interface.allocRemaining(t.allocator, .limited(128 * 1024));
    errdefer t.allocator.free(bytes);
    try task.await(io);

    const split = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.BadResponse;
    return .{
        .bytes = bytes,
        .head = bytes[0..split],
        .body = bytes[split + 4 ..],
        .status = try std.fmt.parseInt(u16, bytes[9..12], 10),
    };
}

fn contains(bytes: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, bytes, needle) != null;
}

test "HTTP full page and HTMX fragment use the same search" {
    for ([_]bool{ false, true }) |hx| {
        const r = try request("/?q=HTTP&category=books", hx, "GET");
        defer r.deinit();
        try t.expectEqual(@as(u16, 200), r.status);
        try t.expectEqualStrings("text/html; charset=utf-8", r.header("content-type").?);
        try t.expectEqualStrings("HX-Request", r.header("vary").?);
        try t.expectEqualStrings("close", r.header("connection").?);
        try t.expectEqual(!hx, contains(r.body, "<html"));
        try t.expect(contains(r.body, "HTTP &amp; HTML"));
        try t.expect(!contains(r.body, "Template inspector"));
    }
}

test "HTTP escapes query attributes and stored titles, preserving unicode" {
    const r = try request("/?q=%22%3E%3Cscript%3Ealert%289%29%3C%2Fscript%3E%26%C3%A9", false, "GET");
    defer r.deinit();
    try t.expectEqual(@as(u16, 200), r.status);
    try t.expect(!contains(r.body, "<script>alert(9)</script>"));
    try t.expect(contains(r.body, "&lt;script&gt;"));
    try t.expect(contains(r.body, "&quot;"));
    try t.expect(contains(r.body, "é"));

    const all = try request("/", false, "GET");
    defer all.deinit();
    try t.expect(!contains(all.body, "<script>alert(1)</script>"));
    try t.expect(contains(all.body, "&lt;script&gt;alert(1)&lt;/script&gt;"));
}

test "HTTP decodes values and rejects malformed enums in both representations" {
    const r = try request("/api/catalog?q=HTTP+%26+HTML&category=books", false, "GET");
    defer r.deinit();
    try t.expectEqual(@as(u16, 200), r.status);
    try t.expectEqualStrings("close", r.header("connection").?);

    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, r.body, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try t.expectEqualStrings("HTTP & HTML", parsed.value.array.items[0].object.get("name").?.string);

    inline for (.{ "/", "/api/catalog" }) |path| {
        for ([_]bool{ false, true }) |hx| {
            const invalid = try request(path ++ "?category=invalid", hx, "GET");
            defer invalid.deinit();
            try t.expectEqual(@as(u16, 422), invalid.status);
            try t.expect(std.mem.startsWith(u8, invalid.header("content-type").?, "application/problem+json"));
            try t.expect(contains(invalid.body, "category"));
        }
    }

    const empty = try request("/api/catalog?q=nothing-matches", false, "GET");
    defer empty.deinit();
    try t.expectEqualStrings("[]", empty.body);
}

test "HTTP methods and routes agree with served OpenAPI" {
    const spec = try request("/openapi.json", false, "GET");
    defer spec.deinit();
    try t.expectEqual(@as(u16, 200), spec.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, spec.body, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try t.expectEqual(@as(usize, 1), paths.count());
    const op = paths.get("/api/catalog").?.object.get("get").?.object;
    try t.expectEqual(@as(usize, 2), op.get("parameters").?.array.items.len);
    try t.expect(op.get("responses").?.object.contains("200"));

    const docs = try request("/docs", false, "GET");
    defer docs.deinit();
    try t.expectEqual(@as(u16, 200), docs.status);
    try t.expectEqualStrings("close", docs.header("connection").?);

    const missing = try request("/missing", false, "GET");
    defer missing.deinit();
    try t.expectEqual(@as(u16, 404), missing.status);

    const wrong = try request("/api/catalog", false, "POST");
    defer wrong.deinit();
    try t.expectEqual(@as(u16, 404), wrong.status);

    const head = try request("/", false, "HEAD");
    defer head.deinit();
    try t.expectEqual(@as(u16, 200), head.status);
    try t.expectEqualStrings("", head.body);
}

test {
    _ = app;
}

fn pendingRead(io: std.Io, stream: std.Io.net.Stream, started: *std.Io.Event, cleaned: *bool) std.Io.Cancelable!void {
    defer cleaned.* = true;
    started.set(io);
    return http.serveConnection(io, t.allocator, stream, app.Server);
}

test "canceling a pending HTTP read preserves cancellation and closes the socket" {
    var deadline = try t.io.concurrent(watchdog, .{t.io});
    defer deadline.cancel(t.io);

    const runtime = if (use_zio) try zio.Runtime.init(t.allocator, .{}) else {};
    defer if (use_zio) runtime.deinit();
    const io = if (use_zio) runtime.io() else t.io;

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{});
    defer listener.deinit(io);

    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);

    const accepted = try listener.accept(io);
    var started: std.Io.Event = .unset;
    var cleaned = false;

    var task = io.concurrent(pendingRead, .{ io, accepted, &started, &cleaned }) catch |err| {
        accepted.close(io);
        return err;
    };
    defer _ = task.cancel(io) catch {};
    try started.wait(io);

    try t.expectError(error.Canceled, task.cancel(io));
    try t.expect(cleaned);

    var buf: [128]u8 = undefined;
    var reader = client.reader(io, &buf);
    try t.expectError(error.EndOfStream, reader.interface.takeByte());
}

const WaitingHandler = struct {
    var started: std.Io.Event = .unset;

    fn run(ctx: *http.Context) !void {
        // Ensures group cancellation tears down a nonempty request arena.
        _ = try ctx.arena.alloc(u8, 16 * 1024);
        started.set(ctx.io);
        try ctx.io.sleep(.fromSeconds(3600), .awake);
    }
};

const WaitingApp = @import("zchema").App(@import("zchema").Api(.{
    @import("zchema").raw(.GET, "/wait", WaitingHandler.run),
}), .{});

fn waitingServer(io: std.Io, listener: *std.Io.net.Server) !void {
    return http.serveOn(io, t.allocator, listener, WaitingApp);
}

test "server shutdown cancels active handlers, joins tasks, and releases request arenas" {
    var deadline = try t.io.concurrent(watchdog, .{t.io});
    defer deadline.cancel(t.io);

    const runtime = if (use_zio) try zio.Runtime.init(t.allocator, .{}) else {};
    defer if (use_zio) runtime.deinit();
    const io = if (use_zio) runtime.io() else t.io;

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{});
    defer listener.deinit(io);

    WaitingHandler.started = .unset;
    var server = try io.concurrent(waitingServer, .{ io, &listener });
    defer _ = server.cancel(io) catch {};

    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);

    var send: [256]u8 = undefined;
    var writer = client.writer(io, &send);
    try writer.interface.writeAll("GET /wait HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();
    try WaitingHandler.started.wait(io);

    try t.expectError(error.Canceled, server.cancel(io));

    // A canceled handler must close without generating a misleading HTTP 500.
    var recv: [256]u8 = undefined;
    var reader = client.reader(io, &recv);
    try t.expectError(error.EndOfStream, reader.interface.takeByte());
}
