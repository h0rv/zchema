const std = @import("std");

const zio = @import("zio");

const app = @import("app.zig");
const http = @import("http.zig");

pub fn main(init: std.process.Init) !void {
    const runtime = try zio.Runtime.init(init.gpa, .{});
    defer runtime.deinit();

    try http.serve(runtime.io(), init.gpa, app.Server);
}
