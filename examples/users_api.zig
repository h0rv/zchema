//! A full users API. zchema owns the contracts (typed bodies, path and query
//! params, responses, validation, OpenAPI, docs); you own the server loop. This
//! file shows the simple single-threaded loop. For concurrency, see threaded.zig.
//!
//! Try:
//!   curl -s localhost:8080/users -d '{"name":"Ada"}' -H 'content-type: application/json'
//!   curl -s 'localhost:8080/users?limit=1'
//!   curl -s localhost:8080/users/1
//!   curl -s localhost:8080/health
//!   open  http://localhost:8080/docs

const std = @import("std");
const z = @import("zchema");

const User = struct {
    id: u32,
    name: []const u8,

    pub const jsonschema = .{ .name = "User", .description = "A stored user." };
};

const CreateUser = struct {
    name: []const u8,

    pub const jsonschema = .{ .name = "CreateUser", .fields = .{ .name = .{ .minLength = 1, .maxLength = 128 } } };
};

const UpdateUser = CreateUser;

const Id = struct { id: u32 };
const Page = struct { limit: u32 = 50, offset: u32 = 0 };

const Api = z.Api(.{
    z.post("/users", createUser),
    z.get("/users", listUsers),
    z.get("/users/{id}", getUser),
    z.patch("/users/{id}", updateUser),
    z.delete("/users/{id}", deleteUser),
    z.raw(.GET, "/health", health),
});

const Server = z.App(Api, .{ .openapi = .{ .title = "Users API", .version = "1.0.0" } });

// Markers carry the contract in the signature: Body for the request, Path and
// Query for params, and the return type for the response. `!?User` is 200 or 404.
fn createUser(store: *Store, body: z.Body(CreateUser)) !z.Created(User) {
    return .{ .value = try store.create(body.value.name) };
}

fn listUsers(store: *Store, page: z.Query(Page)) ![]const User {
    return store.list(page.value.offset, page.value.limit);
}

fn getUser(store: *Store, path: z.Path(Id)) !?User {
    return store.find(path.value.id);
}

fn updateUser(store: *Store, path: z.Path(Id), body: z.Body(UpdateUser)) !?User {
    return store.update(path.value.id, body.value.name);
}

// `!?void` is the conventional DELETE: 204 when removed, 404 when absent.
fn deleteUser(store: *Store, path: z.Path(Id)) !?void {
    if (store.remove(path.value.id) != null) return {};
    return null;
}

// Raw route: non-JSON, responds itself, excluded from OpenAPI.
fn health(req: *std.http.Server.Request) !void {
    try req.respond("ok\n", .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var store: Store = .{ .gpa = gpa };

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("users API on http://127.0.0.1:8080 (docs at /docs)", .{});

    while (true) {
        const stream = listener.accept(io) catch continue;
        serveConnection(io, gpa, &store, stream);
    }
}

/// Serve every request on one connection. This is the integration point: call
/// `Server.handle`, and fall back to a 404 when nothing matched.
fn serveConnection(io: std.Io, gpa: std.mem.Allocator, store: *Store, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &recv);
    var sw = stream.writer(io, &send);
    var http = std.http.Server.init(&sr.interface, &sw.interface);

    // One arena per connection, reset (not freed) between requests: keep-alive
    // requests reuse the same backing memory instead of allocating each time.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    while (true) {
        var req = http.receiveHead() catch return;
        defer _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();

        if (Server.handle(store, arena, &req, .{}) catch return) continue;
        z.respondErrorBody(arena, &req, z.errorBody(.not_found, "No matching route.", &.{}), .{}) catch return;
    }
}

// In-memory store. Owns user names so they outlive the per-request arena.
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

    fn list(self: *Store, offset: u32, limit: u32) []const User {
        const items = self.users.items;
        const start = @min(offset, items.len);
        return items[start..@min(start + limit, items.len)];
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

    fn remove(self: *Store, id: u32) ?User {
        for (self.users.items, 0..) |u, i| {
            if (u.id == id) return self.users.orderedRemove(i);
        }
        return null;
    }
};
