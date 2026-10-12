//! Example-local HTTP plumbing. The server owns each request arena; handlers
//! borrow it through Context. All search results and rendered bytes die after
//! the response finishes. Nothing allocated here is stored across requests.
const std = @import("std");
const z = @import("zchema");

pub const Context = struct {
    io: std.Io,
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
    try serveOn(io, gpa, &listener, App);
}

/// Both runtime variants use this exact accept/task loop and connection policy.
pub fn serveOn(io: std.Io, gpa: std.mem.Allocator, listener: *std.Io.net.Server, comptime App: type) !void {
    const Task = struct {
        fn run(task_io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream) std.Io.Cancelable!void {
            return serveConnection(task_io, allocator, stream, App);
        }
    };
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);
    while (true) {
        const stream = try listener.accept(io);
        errdefer stream.close(io);
        try tasks.concurrent(io, Task.run, .{ io, gpa, stream });
    }
}

pub fn serveConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, comptime App: type) std.Io.Cancelable!void {
    defer stream.close(io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv);
    var writer = stream.writer(io, &send);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = server.receiveHead() catch return transportError(&reader, &writer);
    // Both runtimes deliberately use one request per connection. This keeps
    // the comparison independent of keep-alive and pipelining policy.
    req.head.keep_alive = false;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: Context = .{ .io = io, .arena = arena.allocator(), .request = &req };
    if (App.handle(&ctx, ctx.arena, &req, .{}) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return transportError(&reader, &writer);
    }) return;
    req.respond("Not found", .{ .status = .not_found }) catch return transportError(&reader, &writer);
}

// std.Io.Reader/Writer erase transport errors. Recover cancellation before
// returning to the task group; swallowing it can prevent structured shutdown.
fn transportError(reader: anytype, writer: anytype) std.Io.Cancelable!void {
    if (reader.err) |err| if (err == error.Canceled) return error.Canceled;
    if (writer.err) |err| if (err == error.Canceled) return error.Canceled;
}
