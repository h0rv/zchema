const std = @import("std");

pub const Category = enum { all, books, tools };

pub const Search = struct { q: []const u8 = "", category: Category = .all };

pub const Item = struct {
    name: []const u8,
    category: Category,

    pub const jsonschema = .{ .name = "CatalogItem" };
};

const items = [_]Item{
    .{ .name = "Programming Zig", .category = .books },
    .{ .name = "HTTP & HTML", .category = .books },
    .{ .name = "The <script>alert(1)</script> handbook", .category = .books },
    .{ .name = "Template inspector", .category = .tools },
};

// Both representations call the same application function. No HTTP or HTML here.
pub fn search(arena: std.mem.Allocator, query: Search) ![]const Item {
    var matches: std.ArrayList(Item) = .empty;
    errdefer matches.deinit(arena);

    for (items) |item| {
        if (query.category != .all and query.category != item.category) continue;
        if (std.ascii.indexOfIgnoreCase(item.name, query.q) == null) continue;
        try matches.append(arena, item);
    }

    return matches.toOwnedSlice(arena);
}

test "search combines category and case-insensitive text" {
    const found = try search(std.testing.allocator, .{ .q = "http", .category = .books });
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("HTTP & HTML", found[0].name);

    const empty = try search(std.testing.allocator, .{ .q = "http", .category = .tools });
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
