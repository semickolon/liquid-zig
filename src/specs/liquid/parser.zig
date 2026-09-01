const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @import("lexer.zig").Token;
const TokenTag = std.meta.Tag(Token);
const activeTag = std.meta.activeTag;

const json = std.json;

pub fn parse(allocator: Allocator, src: []const Token) !Node {
    var parser = Parser{ .src = src, .allocator = allocator };
    return try parser.parse();
}

const Parser = struct {
    src: []const Token,
    allocator: std.mem.Allocator,

    pos: usize = 0,

    const Result = struct {
        root_node: *const Node,
        nodes: []const Node,
        branches: []const Node,
    };

    fn parse(self: *Parser) !Node {
        return try self.parseNode();
    }

    fn parseNode(self: *Parser) !Node {
        var children = try std.ArrayList(Node).initCapacity(self.allocator, 32);
        defer children.deinit(self.allocator);

        while (!self.isAtEnd()) {
            if (self.match(.literal)) |tok| {
                try children.append(self.allocator, .{ .literal = tok.literal });
            } else if (self.match(.start_object)) |_| {
                const object = try self.parseObject();
                try children.append(self.allocator, .{ .object = object });
            } else if (self.match(.start_tag)) |_| {
                const tag = try self.parseTag();
                try children.append(self.allocator, .{ .tag = tag });
            } else {
                unreachable;
            }
        }

        if (children.items.len > 1) {
            return .{ .seq = try children.toOwnedSlice(self.allocator) };
        } else {
            return children.items[0];
        }
    }

    fn parseObject(self: *Parser) !Node.Object {
        var object: Node.Object = undefined;
        object.expr = try self.parseExpression();

        if (self.match(.end_object)) |_| {
            return object;
        }

        unreachable;
    }

    fn parseTag(self: *Parser) !Node.Tag {
        const kw = self.match(.keyword).?.keyword;

        switch (kw) {
            .@"if" => {
                const branches = try std.ArrayList(Node.Expression).initCapacity(self.allocator, 2);
                try branches.appendAssumeCapacity(try self.parseExpression());

                assert(self.advance().? == .end_tag);
            },
            else => unreachable,
        }
    }

    fn parseExpression(self: *Parser) !Node.Expression {
        var root_expr = try self.allocator.create(Node.Expression);
        defer self.allocator.destroy(root_expr);

        if (self.match(.identifier)) |tok| {
            root_expr.* = .{ .variable = tok.identifier };

            while (self.match(.dot)) |_| {
                const field_name = self.match(.identifier).?.identifier;

                const expr = try self.allocator.create(Node.Expression);
                expr.* = .{ .field = .{ .parent = root_expr, .name = field_name } };

                root_expr = expr;
            }

            return root_expr.*;
        }

        unreachable;
    }

    fn match(self: *Parser, tag: TokenTag) ?Token {
        const tok = self.peek() orelse return null;
        if (activeTag(tok) == tag) {
            self.pos += 1;
            return tok;
        }
        return null;
    }

    fn advance(self: *Parser) ?Token {
        defer self.pos += 1;
        return self.peek();
    }

    fn peek(self: *const Parser) ?Token {
        return if (self.isAtEnd())
            null
        else
            self.src[self.pos];
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.pos >= self.src.len;
    }
};

pub const Node = union(enum) {
    seq: []const Node,
    literal: []const u8,
    object: Object,
    tag: Tag,

    pub const Identifier = []const u8;

    pub const Object = struct {
        expr: Expression,
    };

    pub const Tag = struct {
        conditional: Conditional,

        pub const Conditional = struct {
            branches: []const Branch,
            fallback: ?*const Node = null,
        };
    };

    pub const Expression = union(enum) {
        variable: Identifier,
        field: struct {
            parent: *const Expression,
            name: Identifier,
        },

        fn eval(self: Expression, context: json.ObjectMap) std.json.Value {
            return switch (self) {
                .variable => |v| context.get(v) orelse unreachable,
                .field => |f| f.parent.eval(context).object.get(f.name) orelse unreachable,
            };
        }
    };

    pub fn render(self: Node, context: json.ObjectMap, writer: *Io.Writer) !void {
        switch (self) {
            .literal => |lit| try writer.writeAll(lit),
            .object => |obj| try writer.writeAll(obj.expr.eval(context).string),
            .tag => unreachable,
            .seq => |children| for (children) |child| {
                try child.render(context, writer);
            },
        }
    }

    pub fn debug(self: Node, tab: usize) void {
        //std.json.parseFromSliceLeaky(comptime T: type, allocator: Allocator, s: []const u8, options: ParseOptions)
        switch (self) {
            .seq => |children| {
                std.log.debug("[{d}] SEQ ({d})", .{ tab, children.len });
                for (children) |child|
                    child.debug(tab + 1);
            },
            .object => |obj| {
                std.log.debug("[{d}] {any}", .{ tab, obj.expr });
            },
            .literal => |lit| {
                std.log.debug("[{d}] LIT ({s})", .{ tab, lit });
            },
            else => unreachable,
        }
    }
};

pub const Branch = struct {
    condition: Node.Expression,
    node: *const Node,
};
