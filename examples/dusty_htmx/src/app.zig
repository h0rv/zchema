const std = @import("std");
const http = @import("dusty");
const z = @import("zchema");
const catalog = @import("catalog");
const pages = @import("pages");
const catalog_path = "/api/catalog";
pub const Spec = z.Spec(.{z.endpoint(.GET, catalog_path, .{
    .query = catalog.Search,
    .responses = .{ z.case(.ok, []const catalog.Item), z.case(.unprocessable_entity, z.ErrorBody) },
})});
pub const Context = struct {
    spec: []const u8,
    docs: []const u8,
    pub fn init(a: std.mem.Allocator) !Context {
        const spec_json = try z.openApiJson(Spec, a, .{ .title = "Catalog", .version = "1.0.0" });
        errdefer a.free(spec_json);
        return .{ .spec = spec_json, .docs = try z.docsHtml(a, .{ .title = "Catalog", .spec_url = "/openapi.json" }) };
    }
    pub fn deinit(self: Context, a: std.mem.Allocator) void {
        a.free(self.spec);
        a.free(self.docs);
    }
};
pub const Server = http.Server(Context);
pub fn routes(server: *Server) void {
    server.router.get("/", htmlCatalog);
    server.router.get(catalog_path, jsonCatalog);
    server.router.get("/openapi.json", spec);
    server.router.get("/docs", docs);
}
fn query(req: *http.Request, res: *http.Response) !?catalog.Search {
    // Dusty owns URL decoding. Adapt the two string query fields to zchema's
    // server-independent JSON validation; arbitrary typed queries need coercion.
    const raw = try std.json.Stringify.valueAlloc(req.arena, .{
        .q = req.query.get("q") orelse "",
        .category = req.query.get("category") orelse "all",
    }, .{});
    var fields: std.ArrayListUnmanaged(z.FieldError) = .empty;
    return z.parseAndValidate(catalog.Search, req.arena, raw, &fields) catch |err| switch (err) {
        error.SchemaValidationFailed, error.InvalidJson => {
            res.status = .unprocessable_entity;
            res.body = try std.json.Stringify.valueAlloc(req.arena, z.errorBody(.unprocessable_entity, "Invalid query", fields.items), .{});
            try res.header("Content-Type", "application/problem+json");
            return null;
        },
        else => return err,
    };
}
fn jsonCatalog(_: *Context, req: *http.Request, res: *http.Response) !void {
    const search = try query(req, res) orelse return;
    res.body = try z.serializeAndValidate([]const catalog.Item, req.arena, try catalog.search(req.arena, search), true);
    try res.header("Content-Type", "application/json");
}
fn htmlCatalog(_: *Context, req: *http.Request, res: *http.Response) !void {
    const search = try query(req, res) orelse return;
    const found = try catalog.search(req.arena, search);
    try res.header("Content-Type", "text/html; charset=utf-8");
    try res.header("Vary", "HX-Request");
    var writer = res.writer();
    if (std.mem.eql(u8, req.headers.get("HX-Request") orelse "", "true")) {
        pages.Results.render(.{ search, found }, &writer.interface) catch return writer.err orelse error.WriteFailed;
    } else {
        pages.Page.render(.{ search, found }, &writer.interface) catch return writer.err orelse error.WriteFailed;
    }
    try writer.end();
}
fn spec(ctx: *Context, _: *http.Request, res: *http.Response) !void {
    res.body = ctx.spec;
    try res.header("Content-Type", "application/json");
}
fn docs(ctx: *Context, _: *http.Request, res: *http.Response) !void {
    res.body = ctx.docs;
    try res.header("Content-Type", "text/html; charset=utf-8");
}
