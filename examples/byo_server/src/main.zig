//! Bring your own framework. zchema does not own routing here: you declare the
//! OpenAPI contract with `endpoint`/`Spec` (no dispatcher, no markers), validate
//! request bodies with `parseAndValidate`, serialize responses with
//! `serializeAndValidate`, and serve the generated spec and docs yourself.
//!
//! This uses `std.http.Server` with a hand-rolled router to stand in for "your
//! framework". With http.zig the calls are identical: take request bytes from
//! `req.body()` instead of `z.body`, and write `res.body` instead of `req.respond`.
//!
//! Try:
//!   curl -s localhost:8080/tasks -d '{"title":"ship it"}' -H 'content-type: application/json'
//!   curl -s localhost:8080/tasks
//!   curl -s localhost:8080/openapi.json
//!   open  http://localhost:8080/docs

const std = @import("std");
const z = @import("zchema");

const Task = struct {
    id: u32,
    title: []const u8,
    done: bool,

    pub const jsonschema = .{ .name = "Task" };
};

const CreateTask = struct {
    title: []const u8,

    pub const jsonschema = .{ .name = "CreateTask", .fields = .{ .title = .{ .minLength = 1, .maxLength = 200 } } };
};

// The OpenAPI contract, declared without handlers or the dispatcher. This is the
// single source of truth for the generated spec.
const Spec = z.Spec(.{
    z.endpoint(.POST, "/tasks", .{
        .body = CreateTask,
        .responses = .{ z.case(.created, Task), z.case(.unprocessable_entity, z.ErrorBody) },
        .summary = "Create a task",
        .tags = &.{"tasks"},
    }),
    z.endpoint(.GET, "/tasks", .{
        .responses = .{z.case(.ok, []const Task)},
        .summary = "List tasks",
        .tags = &.{"tasks"},
    }),
});

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // The spec and docs are constant, so render them once at startup.
    const spec_json = try z.openApiJson(Spec, gpa, .{ .title = "Tasks API", .version = "1.0.0" });
    const docs_html = try z.docsHtml(gpa, .{ .title = "Tasks API", .spec_url = "/openapi.json" });

    var store: Store = .{ .gpa = gpa };

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("tasks API on http://127.0.0.1:8080 (docs at /docs)", .{});

    while (true) {
        const stream = listener.accept(io) catch continue;
        serveConnection(io, gpa, &store, spec_json, docs_html, stream);
    }
}

fn serveConnection(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *Store,
    spec_json: []const u8,
    docs_html: []const u8,
    stream: std.Io.net.Stream,
) void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &recv);
    var sw = stream.writer(io, &send);
    var http = std.http.Server.init(&sr.interface, &sw.interface);

    // One arena per connection, reset between requests.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    while (true) {
        var req = http.receiveHead() catch return;
        defer _ = arena_state.reset(.retain_capacity);
        route(store, spec_json, docs_html, arena_state.allocator(), &req) catch return;
    }
}

// Your framework's router. zchema is not involved in matching.
fn route(store: *Store, spec_json: []const u8, docs_html: []const u8, arena: std.mem.Allocator, req: *std.http.Server.Request) !void {
    const m = req.head.method;
    if (m == .POST and z.pathEql(req, "/tasks")) return createTask(store, arena, req);
    if (m == .GET and z.pathEql(req, "/tasks")) return listTasks(store, arena, req);
    if (m == .GET and z.pathEql(req, "/openapi.json")) return z.respondJsonRaw(arena, req, .ok, spec_json, .{});
    if (m == .GET and z.pathEql(req, "/docs"))
        return req.respond(docs_html, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} });
    return z.respondErrorBody(arena, req, z.errorBody(.not_found, "No such route.", &.{}), .{});
}

fn createTask(store: *Store, arena: std.mem.Allocator, req: *std.http.Server.Request) !void {
    // With http.zig: `const raw = req.body() orelse "";`
    const raw = z.body(req, arena, .{}) catch |e| return z.respondError(arena, req, e, .{});

    var errs: std.ArrayListUnmanaged(z.FieldError) = .empty;
    const input = z.parseAndValidate(CreateTask, arena, raw, &errs) catch |e| {
        if (e == error.SchemaValidationFailed)
            return z.respondErrorBody(arena, req, z.errorBody(.unprocessable_entity, "Validation failed.", errs.items), .{});
        return z.respondError(arena, req, e, .{});
    };

    const task = try store.create(input.title);
    try z.respondJson(Task, arena, req, .created, task, .{});
}

fn listTasks(store: *Store, arena: std.mem.Allocator, req: *std.http.Server.Request) !void {
    // serializeAndValidate returns JSON bytes; with http.zig set `res.body` to them.
    const json = try z.serializeAndValidate([]const Task, arena, store.tasks.items, false);
    try z.respondJsonRaw(arena, req, .ok, json, .{});
}

const Store = struct {
    gpa: std.mem.Allocator,
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    next_id: u32 = 1,

    fn create(self: *Store, title: []const u8) !Task {
        const task: Task = .{ .id = self.next_id, .title = try self.gpa.dupe(u8, title), .done = false };
        try self.tasks.append(self.gpa, task);
        self.next_id += 1;
        return task;
    }
};
