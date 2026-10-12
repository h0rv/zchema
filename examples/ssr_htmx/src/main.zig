const std = @import("std");
const z = @import("zchema");
const catalog = @import("catalog.zig");
const pages = @import("pages.zig");

const Api = z.Api(.{
    z.get("/api/catalog", jsonCatalog),
    z.raw(.GET, "/", htmlCatalog),
});
const Server = z.App(Api, .{ .openapi = .{ .title = "Catalog", .version = "1.0.0" } });

fn jsonCatalog(arena: std.mem.Allocator, query: z.Query(catalog.Search)) ![]const catalog.Item {
    return catalog.search(arena, query.value);
}

fn htmlCatalog(arena: std.mem.Allocator, req: *std.http.Server.Request, query: z.Query(catalog.Search)) !void {
    const found = try catalog.search(arena, query.value);
    const fragment = std.mem.eql(u8, z.header(req, "HX-Request") orelse "", "true");
    // Buffer before writing HTTP headers: a rendering failure cannot send half a page.
    var output: std.Io.Writer.Allocating = .init(arena);
    if (fragment) {
        try pages.Results.render(.{ query.value, found }, &output.writer);
    } else {
        try pages.Page.render(.{ query.value, found }, &output.writer);
    }
    try req.respond(output.written(), .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "vary", .value = "HX-Request" },
    } });
}

pub fn main(init: std.process.Init) !void {
    try serve(init.io, init.gpa);
}

// The application owns Io and sockets. Neither zchema nor zt chooses a runtime.
fn serve(io: std.Io, gpa: std.mem.Allocator) !void {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("catalog on http://127.0.0.1:8080", .{});
    while (true) {
        const stream = try listener.accept(io);
        serveConnection(io, gpa, stream);
    }
}

fn serveConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv);
    var writer = stream.writer(io, &send);
    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var req = http.receiveHead() catch return;
    // One request per connection keeps this deliberately serial demo from
    // waiting on a browser's idle keep-alive socket. Not a production server.
    req.head.keep_alive = false;
    if (Server.handle({}, arena.allocator(), &req, .{}) catch return) return;
    req.respond("Not found", .{ .status = .not_found }) catch return;
}

test "templates escape text and attributes; fragments omit document shell" {
    const a = std.testing.allocator;
    const query: catalog.Search = .{ .q = "\"<script>&'" };
    const found = try catalog.search(a, .{});
    defer a.free(found);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try pages.Page.render(.{ query, found }, &output.writer);
    const page = output.written();
    try std.testing.expect(std.mem.indexOf(u8, page, "<script>alert(1)</script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "&amp;") != null);
    var fragment: std.Io.Writer.Allocating = .init(a);
    defer fragment.deinit();
    try pages.Results.render(.{ query, found }, &fragment.writer);
    try std.testing.expect(std.mem.indexOf(u8, fragment.written(), "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, fragment.written(), "id=\"results\"") != null);
}

test "OpenAPI documents the registered JSON route and excludes raw HTML" {
    const a = std.testing.allocator;
    const bytes = try Server.openApiJson(a);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try std.testing.expectEqual(@as(usize, 1), paths.count());
    try std.testing.expect(paths.contains("/api/catalog"));
    try std.testing.expect(!paths.contains("/"));
}

test {
    _ = catalog;
}
