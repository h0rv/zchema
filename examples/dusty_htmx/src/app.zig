const std = @import("std");
const http = @import("dusty");
const z = @import("zchema");
const catalog = @import("catalog");
const pages = @import("pages");

const catalog_path = "/api/catalog";
const openapi_path = "/openapi.json";

pub const Spec = z.Spec(.{
    z.endpoint(.GET, catalog_path, .{
        .query = catalog.Search,
        .responses = .{
            z.case(.ok, []const catalog.Item),
            z.case(.unprocessable_entity, z.ErrorBody),
        },
    }),
});

// Generate these once; handlers borrow them for the server's lifetime.
pub const Context = struct {
    openapi_json: []const u8,
    docs_html: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Context {
        const openapi_json = try z.openApiJson(Spec, allocator, .{
            .title = "Catalog",
            .version = "1.0.0",
        });
        errdefer allocator.free(openapi_json);

        const docs_html = try z.docsHtml(allocator, .{
            .title = "Catalog",
            .spec_url = openapi_path,
        });

        return .{
            .openapi_json = openapi_json,
            .docs_html = docs_html,
        };
    }

    pub fn deinit(self: Context, allocator: std.mem.Allocator) void {
        allocator.free(self.openapi_json);
        allocator.free(self.docs_html);
    }
};

pub const Server = http.Server(Context);

pub fn routes(server: *Server) void {
    server.router.get("/", htmlCatalog);
    server.router.get(catalog_path, jsonCatalog);
    server.router.get(openapi_path, openApi);
    server.router.get("/docs", docs);
}

fn parseSearch(req: *http.Request, res: *http.Response) !?catalog.Search {
    // Dusty has already URL-decoded the query. Select the two fields we accept
    // and turn them into JSON for zchema's server-independent validation API.
    const query_json = try std.json.Stringify.valueAlloc(req.arena, .{
        .q = req.query.get("q") orelse "",
        .category = req.query.get("category") orelse "all",
    }, .{});

    var field_errors: std.ArrayListUnmanaged(z.FieldError) = .empty;
    return z.parseAndValidate(catalog.Search, req.arena, query_json, &field_errors) catch |err| switch (err) {
        error.SchemaValidationFailed, error.InvalidJson => {
            res.status = .unprocessable_entity;
            try res.json(z.errorBody(.unprocessable_entity, "Invalid query", field_errors.items), .{});
            try res.header("Content-Type", "application/problem+json");
            return null;
        },
        else => return err,
    };
}

fn jsonCatalog(_: *Context, req: *http.Request, res: *http.Response) !void {
    const search = try parseSearch(req, res) orelse return;
    const items = try catalog.search(req.arena, search);

    res.content_type = .json;
    res.body = try z.serializeAndValidate([]const catalog.Item, req.arena, items, true);
}

fn htmlCatalog(_: *Context, req: *http.Request, res: *http.Response) !void {
    const search = try parseSearch(req, res) orelse return;
    const items = try catalog.search(req.arena, search);
    const is_htmx = std.mem.eql(u8, req.headers.get("HX-Request") orelse "", "true");

    res.content_type = .html;
    try res.header("Vary", "HX-Request");

    var writer = res.writer();
    if (is_htmx) {
        pages.Results.render(.{ search, items }, &writer.interface) catch
            return writer.err orelse error.WriteFailed;
    } else {
        pages.Page.render(.{ search, items }, &writer.interface) catch
            return writer.err orelse error.WriteFailed;
    }
    try writer.end();
}

fn openApi(ctx: *Context, _: *http.Request, res: *http.Response) !void {
    res.content_type = .json;
    res.body = ctx.openapi_json;
}

fn docs(ctx: *Context, _: *http.Request, res: *http.Response) !void {
    res.content_type = .html;
    res.body = ctx.docs_html;
}
