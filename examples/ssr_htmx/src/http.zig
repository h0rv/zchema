//! Example-local HTTP plumbing. The server owns each request arena; handlers
//! borrow it through Context. All search results and rendered bytes die after
//! the response finishes. Nothing allocated here is stored across requests.
const std = @import("std");
const z = @import("zchema");

pub const Context = struct {
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,

    pub fn isHtmx(self: *const Context) bool {
        return std.mem.eql(u8, z.header(self.request, "HX-Request") orelse "", "true");
    }

    pub fn html(self: *Context, comptime Template: type, args: Template.Args) !void {
        var output: std.Io.Writer.Allocating = .init(self.arena);
        try Template.render(args, &output.writer);
        try self.request.respond(output.written(), .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "vary", .value = "HX-Request" },
        } });
    }
};

pub fn serve(io: std.Io, gpa: std.mem.Allocator, comptime App: type) !void {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("catalog on http://127.0.0.1:8080", .{});
    while (true) {
        const stream = try listener.accept(io);
        serveConnection(io, gpa, stream, App);
    }
}

pub fn serveConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, comptime App: type) void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv);
    var writer = stream.writer(io, &send);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = server.receiveHead() catch return;
    // Deliberately one request per connection: no idle keep-alive wait in this
    // serial demo. The transport experiment can replace this loop separately.
    req.head.keep_alive = false;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: Context = .{ .arena = arena.allocator(), .request = &req };
    if (App.handle(&ctx, ctx.arena, &req, .{}) catch return) return;
    req.respond("Not found", .{ .status = .not_found }) catch return;
}
