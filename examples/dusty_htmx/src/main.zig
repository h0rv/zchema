const std = @import("std");
const zio = @import("zio");
const app = @import("app.zig");
pub fn main(init: std.process.Init) !void {
    const runtime = try zio.Runtime.init(init.gpa, .{});
    defer runtime.deinit();
    var ctx = try app.Context.init(init.gpa);
    defer ctx.deinit(init.gpa);
    var server = app.Server.init(init.gpa, runtime.io(), .{}, &ctx);
    defer server.deinit();
    app.routes(&server);
    std.log.info("catalog on http://127.0.0.1:8080", .{});
    try server.run();
}
