//! Real loopback HTTP tests; no separate server process or external test tools.
const std = @import("std");
const app = @import("app.zig");
const http = @import("dusty");
const testing = std.testing;
const zio = @import("zio");

const Response = struct {
    bytes: []u8,
    head: []const u8,
    body: []const u8,
    status: u16,

    fn deinit(self: Response) void {
        testing.allocator.free(self.bytes);
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

fn watchdog(io: std.Io) void {
    io.sleep(.fromSeconds(10), .awake) catch return;
    @panic("loopback HTTP test exceeded its 10-second deadline");
}

fn request(target: []const u8, htmx: bool, method: []const u8) !Response {
    const raw = try std.fmt.allocPrint(
        testing.allocator,
        "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{s}\r\n",
        .{ method, target, if (htmx) "HX-Request: true\r\n" else "" },
    );
    defer testing.allocator.free(raw);
    return rawRequest(raw);
}

fn rawRequest(raw: []const u8) !Response {
    var deadline = try testing.io.concurrent(watchdog, .{testing.io});
    defer deadline.cancel(testing.io);

    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var context = try app.Context.init(testing.allocator);
    defer context.deinit(testing.allocator);

    const listeners = [_]http.Listener{.{
        .address = .{ .ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) },
    }};
    var server = app.Server.init(testing.allocator, io, .{ .listeners = &listeners }, &context);
    defer server.deinit();
    app.routes(&server);

    var task = try io.concurrent(app.Server.run, .{&server});
    defer _ = task.cancel(io) catch {};
    try server.ready.wait(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var send: [1024]u8 = undefined;
    var writer = stream.writer(io, &send);
    try writer.interface.writeAll(raw);
    try writer.interface.flush();

    var recv: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv);
    // Reading to EOF checks connection closure; testing.allocator checks cleanup.
    const bytes = try reader.interface.allocRemaining(testing.allocator, .limited(128 * 1024));
    errdefer testing.allocator.free(bytes);

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
    for ([_]bool{ false, true }) |htmx| {
        const response = try request("/?q=HTTP&category=books", htmx, "GET");
        defer response.deinit();
        try testing.expectEqual(@as(u16, 200), response.status);
        try testing.expectEqualStrings("text/html; charset=UTF-8", response.header("content-type").?);
        try testing.expectEqualStrings("HX-Request", response.header("vary").?);
        try testing.expectEqualStrings("close", response.header("connection").?);
        try testing.expectEqual(!htmx, contains(response.body, "<html"));
        try testing.expect(contains(response.body, "HTTP &amp; HTML"));
        try testing.expect(!contains(response.body, "Template inspector"));
    }
}

test "HTTP escapes query attributes and stored titles, preserving unicode" {
    const response = try request("/?q=%22%3E%3Cscript%3Ealert%289%29%3C%2Fscript%3E%26%C3%A9", false, "GET");
    defer response.deinit();
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(!contains(response.body, "<script>alert(9)</script>"));
    try testing.expect(contains(response.body, "&lt;script&gt;"));
    try testing.expect(contains(response.body, "&quot;"));
    try testing.expect(contains(response.body, "é"));

    const all = try request("/", false, "GET");
    defer all.deinit();
    try testing.expect(!contains(all.body, "<script>alert(1)</script>"));
    try testing.expect(contains(all.body, "&lt;script&gt;alert(1)&lt;/script&gt;"));
}

test "HTTP decodes values and rejects malformed enums in both representations" {
    const response = try request("/api/catalog?q=HTTP+%26+HTML&category=books", false, "GET");
    defer response.deinit();
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("close", response.header("connection").?);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try testing.expectEqualStrings("HTTP & HTML", parsed.value.array.items[0].object.get("name").?.string);

    inline for (.{ "/", "/api/catalog" }) |path| {
        for ([_]bool{ false, true }) |htmx| {
            const invalid = try request(path ++ "?category=invalid", htmx, "GET");
            defer invalid.deinit();
            try testing.expectEqual(@as(u16, 422), invalid.status);
            try testing.expect(std.mem.startsWith(u8, invalid.header("content-type").?, "application/problem+json"));
            try testing.expect(contains(invalid.body, "category"));
        }
    }

    const empty = try request("/api/catalog?q=nothing-matches", false, "GET");
    defer empty.deinit();
    try testing.expectEqualStrings("[]", empty.body);
}

test "HTTP methods and routes agree with served OpenAPI" {
    const spec = try request("/openapi.json", false, "GET");
    defer spec.deinit();
    try testing.expectEqual(@as(u16, 200), spec.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, spec.body, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try testing.expectEqual(@as(usize, 1), paths.count());
    const operation = paths.get("/api/catalog").?.object.get("get").?.object;
    try testing.expectEqual(@as(usize, 2), operation.get("parameters").?.array.items.len);
    try testing.expect(operation.get("responses").?.object.contains("200"));
    try testing.expect(operation.get("responses").?.object.contains("422"));
    const parameters = operation.get("parameters").?.array.items;
    try testing.expectEqualStrings("q", parameters[0].object.get("name").?.string);
    try testing.expectEqualStrings("category", parameters[1].object.get("name").?.string);
    try testing.expectEqualStrings("query", parameters[1].object.get("in").?.string);

    const docs = try request("/docs", false, "GET");
    defer docs.deinit();
    try testing.expectEqual(@as(u16, 200), docs.status);
    try testing.expectEqualStrings("close", docs.header("connection").?);

    const missing = try request("/missing", false, "GET");
    defer missing.deinit();
    try testing.expectEqual(@as(u16, 404), missing.status);

    const wrong = try request("/api/catalog", false, "POST");
    defer wrong.deinit();
    try testing.expectEqual(@as(u16, 404), wrong.status);

    const head = try request("/", false, "HEAD");
    defer head.deinit();
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqualStrings("", head.body);
}

test {
    _ = app;
    _ = @import("catalog");
}

const Waiting = struct {
    var started: std.Io.Event = .unset;
    var cleaned: bool = false;

    fn handle(_: *app.Context, req: *http.Request, _: *http.Response) !void {
        defer cleaned = true;
        _ = try req.arena.alloc(u8, 16 * 1024);
        started.set(req.io);
        try req.io.sleep(.fromSeconds(3600), .awake);
    }
};

test "slow handler permits another request; shutdown cancels it and releases arenas" {
    var deadline = try testing.io.concurrent(watchdog, .{testing.io});
    defer deadline.cancel(testing.io);

    const runtime = try zio.Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var context = try app.Context.init(testing.allocator);
    defer context.deinit(testing.allocator);

    const listeners = [_]http.Listener{.{
        .address = .{ .ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) },
    }};
    var server = app.Server.init(testing.allocator, io, .{
        .listeners = &listeners,
        .timeout = .{ .shutdown = .fromMilliseconds(1) },
    }, &context);
    defer server.deinit();
    app.routes(&server);
    server.router.get("/wait", Waiting.handle);
    Waiting.started = .unset;
    Waiting.cleaned = false;

    var task = try io.concurrent(app.Server.run, .{&server});
    defer _ = task.cancel(io) catch {};
    try server.ready.wait(io);

    const slow = try server.address.ip.connect(io, .{ .mode = .stream });
    defer slow.close(io);

    var send: [256]u8 = undefined;
    var writer = slow.writer(io, &send);
    try writer.interface.writeAll("GET /wait HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();
    try Waiting.started.wait(io);

    const fast = try server.address.ip.connect(io, .{ .mode = .stream });
    defer fast.close(io);
    var fast_send_buffer: [256]u8 = undefined;
    var fast_writer = fast.writer(io, &fast_send_buffer);
    try fast_writer.interface.writeAll("GET /api/catalog HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try fast_writer.interface.flush();
    var fast_receive_buffer: [4096]u8 = undefined;
    var fast_reader = fast.reader(io, &fast_receive_buffer);
    const bytes = try fast_reader.interface.allocRemaining(testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expect(contains(bytes, "200 OK"));
    try testing.expect(contains(bytes, "HTTP & HTML"));

    // A separate connection blocked in request-head reading must close too.
    const idle = try server.address.ip.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    var partial_buf: [64]u8 = undefined;
    var partial = idle.writer(io, &partial_buf);
    try partial.interface.writeAll("GET / HTTP/1.1\r\n");
    try partial.interface.flush();

    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expect(Waiting.cleaned);

    var idle_buf: [128]u8 = undefined;
    var idle_reader = idle.reader(io, &idle_buf);
    try testing.expectError(error.EndOfStream, idle_reader.interface.takeByte());

    var recv: [256]u8 = undefined;
    var reader = slow.reader(io, &recv);
    try testing.expectError(error.EndOfStream, reader.interface.takeByte());
}

test "malformed URL escapes receive 400" {
    const response = try request("/?q=%ZZ", false, "GET");
    defer response.deinit();
    try testing.expectEqual(@as(u16, 400), response.status);
}

test "one connection serves pipelined requests and closes when requested" {
    const response = try rawRequest(
        "GET /api/catalog?q=HTTP HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
            "GET /api/catalog?q=Template HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    );
    defer response.deinit();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, response.bytes, "HTTP/1.1 200"));
    try testing.expect(contains(response.bytes, "HTTP & HTML"));
    try testing.expect(contains(response.bytes, "Template inspector"));
}
