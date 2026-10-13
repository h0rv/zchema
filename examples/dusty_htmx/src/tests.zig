//! Real loopback HTTP tests; no separate server process or external test tools.
const std = @import("std");
const app = @import("app.zig");
const http = @import("dusty");
const t = std.testing;
const zio = @import("zio");

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

fn watchdog(io: std.Io) void {
    io.sleep(.fromSeconds(10), .awake) catch return;
    @panic("loopback HTTP test exceeded its 10-second deadline");
}

fn request(target: []const u8, htmx: bool, method: []const u8) !Response {
    const raw = try std.fmt.allocPrint(t.allocator, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{s}\r\n", .{ method, target, if (htmx) "HX-Request: true\r\n" else "" });
    defer t.allocator.free(raw);
    return rawRequest(raw);
}

fn rawRequest(raw: []const u8) !Response {
    var deadline = try t.io.concurrent(watchdog, .{t.io});
    defer deadline.cancel(t.io);
    const runtime = try zio.Runtime.init(t.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var ctx = try app.Context.init(t.allocator);
    defer ctx.deinit(t.allocator);
    const listeners = [_]http.Listener{.{ .address = .{ .ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) } }};
    var server = app.Server.init(t.allocator, io, .{ .listeners = &listeners }, &ctx);
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
    // Reading to EOF verifies the client-requested connection closure. The server allocator is leak-checked too.
    const bytes = try reader.interface.allocRemaining(t.allocator, .limited(128 * 1024));
    errdefer t.allocator.free(bytes);

    const split = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.BadResponse;
    return .{ .bytes = bytes, .head = bytes[0..split], .body = bytes[split + 4 ..], .status = try std.fmt.parseInt(u16, bytes[9..12], 10) };
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
    try t.expect(op.get("responses").?.object.contains("422"));
    const params = op.get("parameters").?.array.items;
    try t.expectEqualStrings("q", params[0].object.get("name").?.string);
    try t.expectEqualStrings("category", params[1].object.get("name").?.string);
    try t.expectEqualStrings("query", params[1].object.get("in").?.string);
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
    var deadline = try t.io.concurrent(watchdog, .{t.io});
    defer deadline.cancel(t.io);
    const runtime = try zio.Runtime.init(t.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var ctx = try app.Context.init(t.allocator);
    defer ctx.deinit(t.allocator);
    const listeners = [_]http.Listener{.{ .address = .{ .ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) } }};
    var server = app.Server.init(t.allocator, io, .{ .listeners = &listeners, .timeout = .{ .shutdown = .fromMilliseconds(1) } }, &ctx);
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
    var send2: [256]u8 = undefined;
    var writer2 = fast.writer(io, &send2);
    try writer2.interface.writeAll("GET /api/catalog HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try writer2.interface.flush();
    var recv2: [4096]u8 = undefined;
    var reader2 = fast.reader(io, &recv2);
    const bytes = try reader2.interface.allocRemaining(t.allocator, .limited(64 * 1024));
    defer t.allocator.free(bytes);
    try t.expect(contains(bytes, "200 OK"));
    try t.expect(contains(bytes, "HTTP & HTML"));
    // A separate connection blocked in request-head reading must close too.
    const idle = try server.address.ip.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    var partial_buf: [64]u8 = undefined;
    var partial = idle.writer(io, &partial_buf);
    try partial.interface.writeAll("GET / HTTP/1.1\r\n");
    try partial.interface.flush();
    try t.expectError(error.Canceled, task.cancel(io));
    try t.expect(Waiting.cleaned);
    var idle_buf: [128]u8 = undefined;
    var idle_reader = idle.reader(io, &idle_buf);
    try t.expectError(error.EndOfStream, idle_reader.interface.takeByte());
    var recv: [256]u8 = undefined;
    var reader = slow.reader(io, &recv);
    try t.expectError(error.EndOfStream, reader.interface.takeByte());
}

test "malformed URL escapes receive 400" {
    const r = try request("/?q=%ZZ", false, "GET");
    defer r.deinit();
    try t.expectEqual(@as(u16, 400), r.status);
}

test "one connection serves pipelined requests and closes when requested" {
    const r = try rawRequest("GET /api/catalog?q=HTTP HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
        "GET /api/catalog?q=Template HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer r.deinit();
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, r.bytes, "HTTP/1.1 200"));
    try t.expect(contains(r.bytes, "HTTP & HTML"));
    try t.expect(contains(r.bytes, "Template inspector"));
}
