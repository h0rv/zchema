//! A users API showing registered routes, signature markers, explicit
//! contracts, OpenAPI generation, and the raw stdlib escape hatch together.
//!
//! Routes:
//!   POST   /users        create a user        (markers: Body -> Created)
//!   GET    /users        list users           (inferred 200 + body type)
//!   GET    /users/{id}    fetch one            (explicit Request/Response)
//!   PATCH  /users/{id}    update one           (path + body, explicit)
//!   DELETE /users/{id}    delete one           (explicit, 204/404)
//!   GET    /health        liveness, text/plain (raw stdlib, unregistered)
//!   GET    /openapi.json  the generated spec   (raw stdlib, unregistered)
//!   GET    /docs          Scalar docs UI       (raw stdlib, unregistered)
//!
//! Try:
//!   curl -s localhost:8080/users -d '{"name":"Ada"}' -H 'content-type: application/json'
//!   curl -s localhost:8080/users
//!   curl -s localhost:8080/users/1
//!   curl -s localhost:8080/openapi.json
//!   open  http://localhost:8080/docs

const std = @import("std");
const zchema = @import("zchema");

const Request = std.http.Server.Request;

// Data models: plain structs with optional schema metadata. No HTTP meaning.

const User = struct {
    id: u32,
    name: []const u8,

    pub const jsonschema = .{ .name = "User", .description = "A stored user." };
};

const CreateUser = struct {
    name: []const u8,

    pub const jsonschema = .{
        .name = "CreateUser",
        .fields = .{ .name = .{ .minLength = 1, .maxLength = 128 } },
    };
};

const UpdateUser = struct {
    name: []const u8,

    pub const jsonschema = .{
        .name = "UpdateUser",
        .fields = .{ .name = .{ .minLength = 1, .maxLength = 128 } },
    };
};

const IdParam = struct { id: u32 };

// Explicit contracts for the parameterized routes. These drive OpenAPI; the
// handlers below read path and body themselves so they can return 404.

const GetUserRequest = zchema.Request(.{ .path = IdParam });
const GetUserResponse = zchema.Response(.{
    zchema.case(.ok, User),
    zchema.case(.not_found, zchema.ErrorBody),
});

const UpdateUserRequest = zchema.Request(.{ .path = IdParam, .body = UpdateUser });
const UpdateUserResponse = zchema.Response(.{
    zchema.case(.ok, User),
    zchema.case(.unprocessable_entity, zchema.ErrorBody),
    zchema.case(.not_found, zchema.ErrorBody),
});

const DeleteUserRequest = zchema.Request(.{ .path = IdParam });
const DeleteUserResponse = zchema.Response(.{
    zchema.emptyCase(.no_content),
    zchema.case(.not_found, zchema.ErrorBody),
});

const Api = zchema.Api(.{
    zchema.post("/users", createUser),
    zchema.get("/users", listUsers),
    zchema.op(.GET, "/users/{id}", getUser, .{ .request = GetUserRequest, .response = GetUserResponse }),
    zchema.op(.PATCH, "/users/{id}", updateUser, .{ .request = UpdateUserRequest, .response = UpdateUserResponse }),
    zchema.op(.DELETE, "/users/{id}", deleteUser, .{ .request = DeleteUserRequest, .response = DeleteUserResponse }),
});

// App adds the spec (/openapi.json) and docs UI (/docs) on top of the routes,
// on by default. Override the paths, pick a different UI, tune Scalar, or set
// .docs = .{ .enabled = false } to turn them off. A route colliding with a
// reserved path is a compile error.
const Server = zchema.App(Api, .{
    .openapi = .{ .title = "Users API", .version = "1.0.0" },
});

// In-memory store. Owns the user names so they outlive the request arena.
const Store = struct {
    gpa: std.mem.Allocator,
    users: std.ArrayListUnmanaged(User) = .empty,
    next_id: u32 = 1,

    fn create(self: *Store, name: []const u8) !User {
        const user: User = .{ .id = self.next_id, .name = try self.gpa.dupe(u8, name) };
        try self.users.append(self.gpa, user);
        self.next_id += 1;
        return user;
    }

    fn find(self: *Store, id: u32) ?User {
        for (self.users.items) |u| {
            if (u.id == id) return u;
        }
        return null;
    }

    fn update(self: *Store, id: u32, name: []const u8) !?User {
        for (self.users.items) |*u| {
            if (u.id == id) {
                self.gpa.free(u.name);
                u.name = try self.gpa.dupe(u8, name);
                return u.*;
            }
        }
        return null;
    }

    fn remove(self: *Store, id: u32) bool {
        for (self.users.items, 0..) |u, i| {
            if (u.id == id) {
                self.gpa.free(u.name);
                _ = self.users.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

// Markers infer everything: Body(CreateUser) is the request, Created(User) the
// 201 response. The dispatcher parses and validates the body before this runs.
fn createUser(store: *Store, body: zchema.Body(CreateUser)) !zchema.Created(User) {
    return .{ .value = try store.create(body.value.name) };
}

// A plain return type is inferred as a 200 JSON body.
fn listUsers(store: *Store) ![]const User {
    return store.users.items;
}

// Parameterized routes take the raw request and the per-request arena (both
// injected by the dispatcher) so they can branch on 200 vs 404.
fn getUser(store: *Store, req: *Request, arena: std.mem.Allocator) !void {
    const id = parseId(req) orelse return respondNotFound(arena, req);
    if (store.find(id)) |user| {
        try zchema.respondJson(User, arena, req, .ok, user, .{});
    } else {
        try respondNotFound(arena, req);
    }
}

fn updateUser(store: *Store, req: *Request, arena: std.mem.Allocator) !void {
    // Capture the path param before reading the body: reading the body
    // invalidates req.head strings.
    const id = parseId(req) orelse return respondNotFound(arena, req);

    const input = zchema.jsonBody(UpdateUser, arena, req, .{}) catch |err|
        return zchema.respondError(arena, req, err, .{});

    if (try store.update(id, input.name)) |user| {
        try zchema.respondJson(User, arena, req, .ok, user, .{});
    } else {
        try respondNotFound(arena, req);
    }
}

fn deleteUser(store: *Store, req: *Request, arena: std.mem.Allocator) !void {
    const id = parseId(req) orelse return respondNotFound(arena, req);
    if (store.remove(id)) {
        try req.respond("", .{ .status = .no_content });
    } else {
        try respondNotFound(arena, req);
    }
}

fn parseId(req: *Request) ?u32 {
    const raw = zchema.pathParam(req, "/users/{id}", "id") orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn respondNotFound(arena: std.mem.Allocator, req: *Request) !void {
    const problem = zchema.errorBody(.not_found, "User not found.", &.{});
    try zchema.respondErrorBody(arena, req, problem, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var store: Store = .{ .gpa = gpa };

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.log.info("users API on http://127.0.0.1:8080 (spec at /openapi.json)", .{});

    while (true) {
        const stream = server.accept(io) catch continue;
        serveConnection(io, gpa, &store, stream);
    }
}

fn serveConnection(io: std.Io, gpa: std.mem.Allocator, store: *Store, stream: std.Io.net.Stream) void {
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

        handleRequest(store, arena, &req) catch return;
    }
}

fn handleRequest(store: *Store, arena: std.mem.Allocator, req: *Request) !void {
    // Routes, plus /openapi.json and /docs (both on by default via App).
    if (try Server.handle(store, arena, req, .{})) return;

    // Everything else is plain stdlib: non-JSON, fallback.
    if (req.head.method == .GET and zchema.pathEql(req, "/health")) {
        try req.respond("ok\n", .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
        return;
    }

    const problem = zchema.errorBody(.not_found, "No such route.", &.{});
    try zchema.respondErrorBody(arena, req, problem, .{});
}
