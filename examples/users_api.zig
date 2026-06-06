//! A full users API: typed bodies, path and query params, multiple response
//! statuses, a raw non-JSON route, OpenAPI, and a docs UI. The whole server is
//! the route table plus a `main` that calls `z.serve`.
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
// Query for params (parsed and validated by the dispatcher), and the return type
// for the response. `!?User` means 200 with the user or 404.
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

// `!?void` is the conventional DELETE: 204 when removed, 404 when it was absent.
// (Return `!?User` instead for a Stripe-style 200 with the deleted record.)
fn deleteUser(store: *Store, path: z.Path(Id)) !?void {
    if (store.remove(path.value.id) != null) return {};
    return null;
}

// Raw route: non-JSON, responds itself, excluded from OpenAPI.
fn health(req: *std.http.Server.Request) !void {
    try req.respond("ok\n", .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}

pub fn main(init: std.process.Init) !void {
    var store: Store = .{ .gpa = init.gpa };
    try z.serve(Server, init.io, init.gpa, &store, .{ .port = 8080 });
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
