const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

pub const Node = parser.Node;

pub fn parse(allocator: Allocator, src: []const u8) !Node {
    const tokens = try lexer.tokenize(allocator, src);

    for (tokens) |tok| {
        tok.debug();
    }

    const root_node = try parser.parse(allocator, tokens);
    return root_node;
}
