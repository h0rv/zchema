const std = @import("std");

const app = @import("app.zig");
const http = @import("http.zig");

pub fn main(init: std.process.Init) !void {
    try http.serve(init.io, init.gpa, app.Server);
}
