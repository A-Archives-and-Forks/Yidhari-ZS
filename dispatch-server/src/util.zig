const std = @import("std");

pub const QueryIterator = struct {
    tokens: std.mem.TokenIterator(u8, .scalar),

    pub const Pair = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn iterate(query: []const u8) @This() {
        return .{ .tokens = std.mem.tokenizeScalar(u8, query, '&') };
    }

    pub fn next(self: *@This()) ?Pair {
        const entry = self.tokens.next() orelse return null;
        var pair = std.mem.tokenizeScalar(u8, entry, '=');

        return .{
            .key = pair.next() orelse return null,
            .value = pair.next() orelse return null,
        };
    }
};
