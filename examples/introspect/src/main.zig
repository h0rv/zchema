//! Deconstruct an Api into its routes and the models on each one. The same
//! data that `openApiJson` renders is public, so you can walk it to build your
//! own artifacts: a custom spec, client codegen, a route listing, TypeScript
//! types, and so on. Run with `zig build run-introspect`.

const std = @import("std");
const z = @import("zchema");

const User = struct {
    id: u32,
    name: []const u8,
    pub const jsonschema = .{ .name = "User" };
};

const CreateUser = struct {
    name: []const u8,
    pub const jsonschema = .{ .name = "CreateUser" };
};

const Id = struct { id: u32 };

fn createUser(body: z.Body(CreateUser)) !z.Created(User) {
    return .{ .value = .{ .id = 1, .name = body.value.name } };
}
fn getUser(path: z.Path(Id)) !?User {
    _ = path;
    return null;
}

const Api = z.Api(.{
    z.post("/users", createUser),
    z.get("/users/{id}", getUser),
});

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    const w = &out.interface;

    inline for (Api.routes) |route| {
        if (route.is_raw) continue;
        const op = comptime z.operation(route);

        try w.print("{s} {s}  ({s})\n", .{ @tagName(op.method), op.path, op.operation_id });

        if (op.BodyType) |B| try w.print("  request body: {s}\n", .{comptime z.schemaName(B)});

        inline for (op.params) |p| {
            try w.print("  param: {s} in {s} (required={})\n", .{ p.name, @tagName(p.in), p.required });
        }

        inline for (op.responses) |r| {
            const code = @intFromEnum(r.status);
            if (r.Type) |T| {
                try w.print("  {d}: {s}\n", .{ code, comptime z.schemaName(T) });
            } else {
                try w.print("  {d}: (no body)\n", .{code});
            }
        }
    }

    try w.flush();
}
