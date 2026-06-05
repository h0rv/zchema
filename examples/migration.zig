//! Migrating an existing `std.http.Server` handler to typed contracts.
//!
//! zchema does not replace your server loop or your routing. You keep both
//! and adopt JSON contracts one handler at a time. This file shows the same
//! endpoint twice: first with raw stdlib, then with the helper functions.
//!
//! Run it, then:
//!   curl -s localhost:8080/echo -d '{"name":"Ada"}' -H 'content-type: application/json'

const std = @import("std");
const zchema = @import("zchema");

const Request = std.http.Server.Request;

const Echo = struct {
    name: []const u8,

    pub const jsonschema = .{ .fields = .{ .name = .{ .minLength = 1 } } };
};

const Greeting = struct {
    message: []const u8,
};

// Before: raw stdlib. You parse, validate, and serialize JSON by hand.
fn echoStdlib(arena: std.mem.Allocator, req: *Request) !void {
    var buf: [4096]u8 = undefined;
    const reader = try req.readerExpectContinue(&buf);
    const raw = try reader.allocRemaining(arena, .limited(1 << 20));

    const parsed = std.json.parseFromSliceLeaky(Echo, arena, raw, .{}) catch {
        try req.respond("{\"error\":\"invalid json\"}", .{ .status = .bad_request });
        return;
    };
    if (parsed.name.len == 0) {
        try req.respond("{\"error\":\"name required\"}", .{ .status = .unprocessable_entity });
        return;
    }

    const greeting: Greeting = .{ .message = parsed.name };
    const out = try std.json.Stringify.valueAlloc(arena, greeting, .{});
    try req.respond(out, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

// After: the same endpoint with helpers. Validation comes from the schema
// emitted from `Echo`, and the error bodies are structured.
fn echoContractz(arena: std.mem.Allocator, req: *Request) !void {
    const input = zchema.jsonBody(Echo, arena, req, .{}) catch |err|
        return zchema.respondError(arena, req, err, .{});

    const greeting: Greeting = .{ .message = input.name };
    try zchema.respondJson(Greeting, arena, req, .ok, greeting, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.log.info("listening on http://127.0.0.1:8080 (POST /echo, /echo-stdlib)", .{});

    while (true) {
        const stream = server.accept(io) catch continue;
        serveConnection(io, gpa, stream);
    }
}

fn serveConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) void {
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

        // Your own routing stays in charge.
        if (req.head.method == .POST and zchema.pathEql(&req, "/echo")) {
            echoContractz(arena, &req) catch return;
        } else if (req.head.method == .POST and zchema.pathEql(&req, "/echo-stdlib")) {
            echoStdlib(arena, &req) catch return;
        } else {
            req.respond("not found", .{ .status = .not_found }) catch return;
        }
    }
}
