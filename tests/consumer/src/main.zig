//! Minimal consumer used to verify that depending on `zchema` alone is enough:
//! it imports only `zchema`, and `jsonschema` must resolve transitively.

const std = @import("std");
const zchema = @import("zchema");

const User = struct {
    id: u32,
    name: []const u8,
};

pub fn main() void {
    const schema = zchema.schemaText(User);
    std.debug.assert(schema.len > 0);
}
