const std = @import("std");
const z = @import("zchema");
const catalog = @import("catalog");
const pages = @import("pages.zig");
const http = @import("http.zig");

const Api = z.Api(.{
    z.get("/api/catalog", jsonCatalog),
    z.raw(.GET, "/", htmlCatalog),
});
pub const Server = z.App(Api, .{ .openapi = .{ .title = "Catalog", .version = "1.0.0" } });

fn jsonCatalog(ctx: *http.Context, query: z.Query(catalog.Search)) ![]const catalog.Item {
    return catalog.search(ctx.arena, query.value);
}

fn htmlCatalog(ctx: *http.Context, query: z.Query(catalog.Search)) !void {
    const found = try catalog.search(ctx.arena, query.value);
    if (ctx.isHtmx()) {
        try ctx.html(pages.Results, .{ query.value, found });
    } else {
        try ctx.html(pages.Page, .{ query.value, found });
    }
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
