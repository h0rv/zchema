//! Self-contained HTML pages that render an OpenAPI document with a popular
//! open-source UI. No extra Zig dependency is pulled in: each page is a small
//! HTML template that loads the chosen UI from a CDN in the browser and points
//! it at your spec URL.
//!
//! CDN URLs are overridable (pin a version, or self-host) via `DocsOptions.assets`,
//! and Scalar's noise (AI chat, MCP, telemetry, toolbar buttons) is configurable
//! via `DocsOptions.scalar`, with the promotional bits off by default.

const std = @import("std");

const Request = std.http.Server.Request;

/// Which documentation UI to render.
pub const DocsUi = enum {
    /// Scalar. Modern, clean, MIT. https://github.com/scalar/scalar
    scalar,
    /// Redoc. Three-panel reference, MIT. https://github.com/Redocly/redoc
    redoc,
    /// Swagger UI. The classic try-it-out console, Apache-2.0.
    swagger_ui,
    /// Stoplight Elements. Web components, Apache-2.0.
    elements,
};

/// Default CDN asset URLs, one set per UI. Override via `DocsOptions.assets`
/// (for example to pin a version or self-host).
pub const default_assets = struct {
    pub const scalar_script = "https://cdn.jsdelivr.net/npm/@scalar/api-reference";
    pub const redoc_script = "https://cdn.jsdelivr.net/npm/redoc@2/bundles/redoc.standalone.js";
    pub const swagger_script = "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js";
    pub const swagger_style = "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css";
    pub const elements_script = "https://unpkg.com/@stoplight/elements/web-components.min.js";
    pub const elements_style = "https://unpkg.com/@stoplight/elements/styles.min.css";
};

/// CDN/asset URL overrides. A null field uses the UI's default from
/// `default_assets`.
pub const DocsAssets = struct {
    /// Main UI script URL.
    script: ?[]const u8 = null,
    /// Stylesheet URL, for UIs that load one (Swagger UI, Elements).
    style: ?[]const u8 = null,
};

/// Scalar-specific configuration. Defaults turn off the promotional and
/// telemetry features; the documentation features stay on. Anything not modeled
/// here can be added verbatim through `extra_json`.
pub const ScalarConfig = struct {
    /// Disable the built-in AI chat ("Ask AI"). Default: off.
    disable_ai: bool = true,
    /// Disable Model Context Protocol integration. Default: off.
    disable_mcp: bool = true,
    /// Disable telemetry. Default: off.
    disable_telemetry: bool = true,
    /// Hide the "Download OpenAPI" button.
    hide_download_button: bool = false,
    /// Hide the test-request ("Send") button and the auth panel.
    hide_test_request_button: bool = false,
    /// Hide the sidebar search.
    hide_search: bool = false,
    /// Hide the Models section.
    hide_models: bool = false,
    /// Hide the "Open in API Client" button (the client.scalar.com link).
    hide_client_button: bool = false,
    /// Hide the dark mode toggle.
    hide_dark_mode_toggle: bool = false,
    /// Force dark mode on or off; null leaves it to the user/system.
    dark_mode: ?bool = null,
    /// Theme name, for example "default", "moon", "purple".
    theme: ?[]const u8 = null,
    /// Layout, for example "modern" or "classic".
    layout: ?[]const u8 = null,
    /// Extra CSS injected into the page. The only lever for the "Powered by
    /// Scalar" footer, which has no config toggle in the open-source build:
    /// `.custom_css = ".scalar-app .darklight-reference{display:none}"`.
    custom_css: ?[]const u8 = null,
    /// Raw JSON object fields appended to the configuration verbatim, without
    /// surrounding braces, for example: `"\"showSidebar\":false"`. Advanced.
    extra_json: ?[]const u8 = null,
};

/// Options for the rendered docs page.
pub const DocsOptions = struct {
    /// Page `<title>`.
    title: []const u8 = "API Reference",
    /// UI to render.
    ui: DocsUi = .scalar,
    /// URL the UI fetches the spec from. Serve your OpenAPI document there.
    spec_url: []const u8 = "/openapi.json",
    /// CDN/asset URL overrides.
    assets: DocsAssets = .{},
    /// Scalar configuration (used only when `ui == .scalar`).
    scalar: ScalarConfig = .{},
};

/// HTML content type with charset, suitable for `extra_headers`.
pub const html_content_type = "text/html; charset=utf-8";

/// Allocate the docs HTML page. Caller owns the returned slice.
pub fn docsHtml(allocator: std.mem.Allocator, opts: DocsOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeDocsHtml(&aw.writer, opts);
    return aw.toOwnedSlice();
}

/// Respond to `req` with the docs HTML page (`text/html`).
pub fn respondDocs(arena: std.mem.Allocator, req: *Request, opts: DocsOptions) !void {
    const html = try docsHtml(arena, opts);
    try req.respond(html, .{
        .extra_headers = &.{.{ .name = "content-type", .value = html_content_type }},
    });
}

/// Write the docs HTML page to `writer`.
pub fn writeDocsHtml(writer: *std.Io.Writer, opts: DocsOptions) !void {
    switch (opts.ui) {
        .scalar => try writeScalar(writer, opts),
        .redoc => try writeRedoc(writer, opts),
        .swagger_ui => try writeSwaggerUi(writer, opts),
        .elements => try writeElements(writer, opts),
    }
}

fn writeHead(writer: *std.Io.Writer, title: []const u8) !void {
    try writer.writeAll(
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1" />
        \\    <title>
    );
    try writeAttr(writer, title);
    try writer.writeAll("</title>\n");
}

fn writeScalar(writer: *std.Io.Writer, opts: DocsOptions) !void {
    try writeHead(writer, opts.title);
    try writer.writeAll(
        \\  </head>
        \\  <body>
        \\    <div id="app"></div>
        \\    <script src="
    );
    try writeAttr(writer, opts.assets.script orelse default_assets.scalar_script);
    try writer.writeAll(
        \\"></script>
        \\    <script>
        \\      Scalar.createApiReference('#app',
    );
    try writeScalarConfig(writer, opts);
    try writer.writeAll(
        \\);
        \\    </script>
        \\  </body>
        \\</html>
        \\
    );
}

fn writeScalarConfig(writer: *std.Io.Writer, opts: DocsOptions) !void {
    const c = opts.scalar;
    try writer.writeByte('{');
    var first = true;

    try keyRaw(writer, &first, "url", null);
    try std.json.Stringify.encodeJsonString(opts.spec_url, .{}, writer);

    if (c.disable_ai) try keyRaw(writer, &first, "agent", "{\"disabled\":true}");
    if (c.disable_mcp) try keyRaw(writer, &first, "mcp", "{\"disabled\":true}");
    if (c.disable_telemetry) try keyRaw(writer, &first, "telemetry", "false");
    if (c.hide_download_button) try keyRaw(writer, &first, "hideDownloadButton", "true");
    if (c.hide_test_request_button) try keyRaw(writer, &first, "hideTestRequestButton", "true");
    if (c.hide_search) try keyRaw(writer, &first, "hideSearch", "true");
    if (c.hide_models) try keyRaw(writer, &first, "hideModels", "true");
    if (c.hide_client_button) try keyRaw(writer, &first, "hideClientButton", "true");
    if (c.hide_dark_mode_toggle) try keyRaw(writer, &first, "hideDarkModeToggle", "true");
    if (c.dark_mode) |dm| try keyRaw(writer, &first, "darkMode", if (dm) "true" else "false");
    if (c.theme) |t| {
        try keyRaw(writer, &first, "theme", null);
        try std.json.Stringify.encodeJsonString(t, .{}, writer);
    }
    if (c.layout) |l| {
        try keyRaw(writer, &first, "layout", null);
        try std.json.Stringify.encodeJsonString(l, .{}, writer);
    }
    if (c.custom_css) |css| {
        try keyRaw(writer, &first, "customCss", null);
        try std.json.Stringify.encodeJsonString(css, .{}, writer);
    }
    if (c.extra_json) |extra| {
        if (extra.len > 0) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll(extra);
        }
    }
    try writer.writeByte('}');
}

/// Write `"key":` with a leading comma when needed. When `raw_value` is given it
/// is written after the colon; otherwise the caller writes the value next.
fn keyRaw(writer: *std.Io.Writer, first: *bool, key: []const u8, raw_value: ?[]const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeByte('"');
    try writer.writeAll(key);
    try writer.writeAll("\":");
    if (raw_value) |v| try writer.writeAll(v);
}

fn writeRedoc(writer: *std.Io.Writer, opts: DocsOptions) !void {
    try writeHead(writer, opts.title);
    try writer.writeAll(
        \\  </head>
        \\  <body>
        \\    <redoc spec-url="
    );
    try writeAttr(writer, opts.spec_url);
    try writer.writeAll(
        \\"></redoc>
        \\    <script src="
    );
    try writeAttr(writer, opts.assets.script orelse default_assets.redoc_script);
    try writer.writeAll(
        \\"></script>
        \\  </body>
        \\</html>
        \\
    );
}

fn writeSwaggerUi(writer: *std.Io.Writer, opts: DocsOptions) !void {
    try writeHead(writer, opts.title);
    try writer.writeAll("    <link rel=\"stylesheet\" href=\"");
    try writeAttr(writer, opts.assets.style orelse default_assets.swagger_style);
    try writer.writeAll(
        \\" />
        \\  </head>
        \\  <body>
        \\    <div id="swagger-ui"></div>
        \\    <script src="
    );
    try writeAttr(writer, opts.assets.script orelse default_assets.swagger_script);
    try writer.writeAll(
        \\"></script>
        \\    <script>
        \\      window.onload = function () {
        \\        window.ui = SwaggerUIBundle({ url:
    );
    try std.json.Stringify.encodeJsonString(opts.spec_url, .{}, writer);
    try writer.writeAll(
        \\, dom_id: "#swagger-ui" });
        \\      };
        \\    </script>
        \\  </body>
        \\</html>
        \\
    );
}

fn writeElements(writer: *std.Io.Writer, opts: DocsOptions) !void {
    try writeHead(writer, opts.title);
    try writer.writeAll("    <link rel=\"stylesheet\" href=\"");
    try writeAttr(writer, opts.assets.style orelse default_assets.elements_style);
    try writer.writeAll(
        \\" />
        \\    <script src="
    );
    try writeAttr(writer, opts.assets.script orelse default_assets.elements_script);
    try writer.writeAll(
        \\"></script>
        \\  </head>
        \\  <body>
        \\    <elements-api apiDescriptionUrl="
    );
    try writeAttr(writer, opts.spec_url);
    try writer.writeAll(
        \\" router="hash" layout="sidebar"></elements-api>
        \\  </body>
        \\</html>
        \\
    );
}

/// Escape a value for an HTML attribute or text node (double-quoted context).
fn writeAttr(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(c),
    };
}

test "each UI renders a page referencing the spec URL and its CDN" {
    const a = std.testing.allocator;
    const cases = [_]struct { ui: DocsUi, marker: []const u8 }{
        .{ .ui = .scalar, .marker = "@scalar/api-reference" },
        .{ .ui = .redoc, .marker = "redoc.standalone.js" },
        .{ .ui = .swagger_ui, .marker = "swagger-ui-bundle.js" },
        .{ .ui = .elements, .marker = "@stoplight/elements" },
    };
    for (cases) |c| {
        const html = try docsHtml(a, .{ .ui = c.ui, .spec_url = "/openapi.json", .title = "Demo" });
        defer a.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, "<!doctype html>") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "/openapi.json") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, c.marker) != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "<title>Demo</title>") != null);
    }
}

test "scalar config turns off noise by default and is overridable" {
    const a = std.testing.allocator;

    const default_page = try docsHtml(a, .{ .ui = .scalar });
    defer a.free(default_page);
    try std.testing.expect(std.mem.indexOf(u8, default_page, "\"agent\":{\"disabled\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_page, "\"mcp\":{\"disabled\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_page, "\"telemetry\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_page, "hideModels") == null);

    const tuned = try docsHtml(a, .{ .ui = .scalar, .scalar = .{
        .disable_ai = false,
        .hide_models = true,
        .theme = "moon",
        .extra_json = "\"showSidebar\":false",
    } });
    defer a.free(tuned);
    try std.testing.expect(std.mem.indexOf(u8, tuned, "agent") == null);
    try std.testing.expect(std.mem.indexOf(u8, tuned, "\"hideModels\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, tuned, "\"theme\":\"moon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tuned, "\"showSidebar\":false") != null);
}

test "asset overrides replace the CDN url" {
    const a = std.testing.allocator;
    const html = try docsHtml(a, .{ .ui = .scalar, .assets = .{ .script = "/vendor/scalar.js" } });
    defer a.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "/vendor/scalar.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "cdn.jsdelivr.net") == null);
}

test "docs page escapes the title and spec url" {
    const a = std.testing.allocator;
    const html = try docsHtml(a, .{ .ui = .redoc, .title = "A & B <x>", .spec_url = "/spec?q=\"x\"" });
    defer a.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "A &amp; B &lt;x&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<x>") == null);
}
