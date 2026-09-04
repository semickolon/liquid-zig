const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @import("Tokenizer.zig").Token;
const TokenTag = std.meta.Tag(Token);
const activeTag = std.meta.activeTag;

const liquid = @import("root.zig");
const Value = liquid.Value;

const Ast = @import("Ast.zig");

const IndexableArrayList = @import("lib.zig").IndexableArrayList;

const Parser = @This();

allocator: Allocator,
scratch: Allocator,
src: []const Token,
pos: usize = 0,
nodes: IndexableArrayList(Ast.Node) = undefined,
exprs: IndexableArrayList(Ast.Expr) = undefined,

pub fn parse(allocator: Allocator, scratch: Allocator, src: []const Token) !Ast {
    var ast_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer ast_arena.deinit();
    const ast_alloc = ast_arena.allocator();

    var parser = Parser{
        .allocator = ast_alloc,
        .scratch = scratch,
        .src = src,
    };

    parser.nodes = try .initCapacity(scratch, 64);
    parser.exprs = try .initCapacity(scratch, 256);

    const root_node = try parser.parseBlock();
    return .{
        .arena = ast_arena,
        .root_node = root_node,
        .nodes = try ast_alloc.dupe(Ast.Node, parser.nodes.list.items),
        .exprs = try ast_alloc.dupe(Ast.Expr, parser.exprs.list.items),
    };
}

fn parseBlock(self: *Parser) Allocator.Error!Ast.NodeRef {
    var children = try std.ArrayList(Ast.NodeRef).initCapacity(self.scratch, 8);

    while (!self.isAtEnd()) {
        const child_ref = try self.nodes.addOne(self.scratch);

        const child_node: Ast.Node = switch (self.peek().?) {
            .raw => |raw| blk: {
                _ = self.advance();
                break :blk .{ .raw = raw };
            },
            .start_object => .{ .object = try self.parseObject() },
            .start_tag => .{ .tag = try self.parseTag() orelse break },
            else => unreachable,
        };

        child_ref.setValue(self.nodes, child_node);
        try children.append(self.scratch, child_ref);
    }

    return switch (children.items.len) {
        1 => children.items[0],
        else => try self.nodes.append(self.scratch, .{
            .block = try self.allocator.dupe(Ast.NodeRef, children.items),
        }),
    };
}

fn parseObject(self: *Parser) !Ast.FilteredExpr {
    _ = self.consume(.start_object);
    defer _ = self.consume(.end_object);
    return self.parseFilteredExpr();
}

fn parseFilteredExpr(self: *Parser) !Ast.FilteredExpr {
    const expr = try self.valueExpr();

    var filters = std.ArrayList(Ast.Filter).empty;

    while (self.match(.pipe)) |_| {
        const filter = self.consume(.identifier).identifier;
        var args = try std.ArrayList(Ast.Filter.Arg).initCapacity(self.scratch, 4);

        if (self.match(.colon)) |_| {
            args.appendAssumeCapacity(try self.parseFilterArg());

            while (self.match(.comma)) |_| {
                try args.append(self.scratch, try self.parseFilterArg());
            }
        }

        try filters.append(self.scratch, .{
            .name = filter,
            .args = try self.allocator.dupe(Ast.Filter.Arg, args.items),
        });
    }

    return .{
        .expr = expr,
        .filters = try self.allocator.dupe(Ast.Filter, filters.items),
    };
}

fn parseFilterArg(self: *Parser) !Ast.Filter.Arg {
    const name = blk: {
        const tok0 = self.peek() orelse break :blk "";
        const tok1 = self.peekNext() orelse break :blk "";

        if (activeTag(tok0) == .identifier and tok1 == .colon) {
            const s = self.consume(.identifier).identifier;
            _ = self.consume(.colon);
            break :blk s;
        }

        break :blk "";
    };

    return .{
        .name = name,
        .value = try self.valueExpr(),
    };
}

fn parseTag(self: *Parser) !?Ast.Tag {
    if (self.matchTagStart("if")) {
        return try self.parseConditionalTag(false);
    } else if (self.matchTagStart("unless")) {
        return try self.parseConditionalTag(true);
    } else if (self.matchTagStart("assign")) {
        return try self.parseAssignTag();
    } else if (self.matchTagStart("for")) {
        return try self.parseForTag();
    } else if (self.matchTagStart("break")) {
        _ = self.consume(.end_tag);
        return .@"break";
    } else if (self.matchTagStart("continue")) {
        _ = self.consume(.end_tag);
        return .@"continue";
    }

    return null; // Returning null here ends the block parser (e.g., on elsif, endif)
    // TODO: panic on unrecognized keywords
}

fn matchTagStart(self: *Parser, expected: []const u8) bool {
    const cur_tok = self.peek() orelse return false;
    if (cur_tok != .start_tag) return false;

    const next_tok = self.peekNext() orelse return false;

    switch (next_tok) {
        .identifier => |actual| if (std.mem.eql(u8, actual, expected)) {
            self.pos += 2;
            return true;
        },
        else => {},
    }

    return false;
}

fn parseConditionalTag(self: *Parser, unless: bool) !Ast.Tag {
    var branches = try std.ArrayList(Ast.Tag.Branch).initCapacity(self.scratch, 4);
    branches.appendAssumeCapacity(try self.parseBranch(unless));

    while (self.matchTagStart("elsif")) {
        try branches.append(self.scratch, try self.parseBranch(false));
    }

    const else_block: ?Ast.NodeRef = if (self.matchTagStart("else")) blk: {
        _ = self.consume(.end_tag);
        break :blk try self.parseBlock();
    } else null;

    assert(self.matchTagStart(if (unless) "endunless" else "endif"));
    _ = self.consume(.end_tag);

    return .{ .conditional = .{
        .branches = try self.allocator.dupe(Ast.Tag.Branch, branches.items),
        .fallback = else_block,
    } };
}

fn parseBranch(self: *Parser, unless: bool) !Ast.Tag.Branch {
    const condition = try self.conditionExpr();
    _ = self.consume(.end_tag);
    const block = try self.parseBlock();

    return .{
        .condition = condition,
        .unless = unless,
        .block = block,
    };
}

fn parseAssignTag(self: *Parser) !Ast.Tag {
    const ident = self.consume(.identifier).identifier;
    _ = self.consume(.equal);
    const filtered_expr = try self.parseFilteredExpr();
    _ = self.consume(.end_tag);
    return .{ .assign = .{
        .ident = ident,
        .filtered_expr = filtered_expr,
    } };
}

fn matchIdentifier(self: *Parser, expected: []const u8) bool {
    const tok = self.peek() orelse return false;
    switch (tok) {
        .identifier => |actual| if (std.mem.eql(u8, actual, expected)) {
            _ = self.advance();
            return true;
        },
        else => {},
    }
    return false;
}

fn parseForTag(self: *Parser) !Ast.Tag {
    var for_loop = Ast.Tag.For{
        .iter_ident = undefined,
        .collection = undefined,
        .body = undefined,
    };

    for_loop.iter_ident = self.consume(.identifier).identifier;
    assert(self.matchIdentifier("in"));
    for_loop.collection = try self.valueExpr();

    while (self.match(.identifier)) |tok| {
        const opt = tok.identifier;

        if (std.mem.eql(u8, opt, "limit")) {
            _ = self.consume(.colon);
            for_loop.opt_limit = try self.valueExpr();
        } else if (std.mem.eql(u8, opt, "offset")) {
            _ = self.consume(.colon);
            for_loop.opt_offset = try self.valueExpr();
        } else if (std.mem.eql(u8, opt, "reversed")) {
            for_loop.opt_reversed = true;
        } else {
            unreachable;
        }
    }

    _ = self.consume(.end_tag);

    for_loop.body = try self.parseBlock();

    if (self.matchTagStart("else")) {
        _ = self.consume(.end_tag);
        for_loop.fallback = try self.parseBlock();
    }

    assert(self.matchTagStart("endfor"));
    _ = self.consume(.end_tag);

    return .{ .@"for" = for_loop };
}

fn valueExpr(self: *Parser) !Ast.ExprRef {
    const root_expr_ref = try self.exprs.addOne(self.scratch);
    const tok = self.advance() orelse unreachable;

    const root_expr: Ast.Expr = switch (tok) {
        .int => |n| .{ .literal = .{ .int = n } },
        .float => |n| .{ .literal = .{ .float = n } },
        .string => |s| .{ .literal = .{ .string = s } },
        .keyword => |kw| switch (kw) {
            .nil => .{ .literal = .nil },
            .true => .{ .literal = .{ .bool = true } },
            .false => .{ .literal = .{ .bool = false } },
            .empty => .{ .literal = .empty },
            .blank => .{ .literal = .blank },
            else => unreachable,
        },
        .open_par => blk: {
            const start = try self.valueExpr();
            _ = self.consume(.dot_dot);
            const end = try self.valueExpr();
            _ = self.consume(.close_par);

            break :blk .{ .range = .{
                .start = start,
                .end = end,
            } };
        },
        .identifier => |ident| blk: {
            var head = Ast.Expr{ .variable = ident };

            while (!self.isAtEnd()) {
                if (self.matchAny(&.{ .dot, .open_brc })) |start_tok| {
                    const name = self.consume(.identifier).identifier;
                    const parent = try self.exprs.append(self.scratch, head);

                    head = .{ .property = .{
                        .parent = parent,
                        .name = name,
                    } };

                    switch (start_tok) {
                        .dot => {},
                        .open_brc => _ = self.consume(.close_brc),
                        else => unreachable,
                    }
                } else {
                    break;
                }
            }

            break :blk head;
        },
        else => unreachable,
    };

    root_expr_ref.setValue(self.exprs, root_expr);
    return root_expr_ref;
}

fn conditionExpr(self: *Parser) !Ast.ExprRef {
    var head = try self.comparisonExpr();

    if (self.peek()) |tok| {
        switch (tok) {
            .keyword => |kw| if (kw == .@"and" or kw == .@"or") {
                _ = self.advance();
                const expr_ref = try self.exprs.addOne(self.scratch);

                expr_ref.ptr(self.exprs).* = .{ .logical = .{
                    .op = switch (kw) {
                        .@"and" => .@"and",
                        .@"or" => .@"or",
                        else => unreachable,
                    },
                    .lhs = head,
                    .rhs = try self.conditionExpr(),
                } };

                head = expr_ref;
            },
            else => {},
        }
    }

    return head;
}

fn comparisonExpr(self: *Parser) !Ast.ExprRef {
    var head = try self.valueExpr();

    if (self.match(.comparison_op)) |tok| {
        const expr_ref = try self.exprs.addOne(self.scratch);

        expr_ref.ptr(self.exprs).* = .{ .comparison = .{
            .op = tok.comparison_op,
            .lhs = head,
            .rhs = try self.valueExpr(),
        } };

        head = expr_ref;
    }

    return head;
}

fn parseExpression(self: *Parser) !Ast.ExprRef {
    var root_expr_ref = try self.exprs.addOne(self.scratch);

    if (self.match(.identifier)) |tok| {
        root_expr_ref.setValue(self.exprs, .{ .variable = tok.identifier });

        while (self.match(.dot)) |_| {
            const field_name = self.match(.identifier).?.identifier;

            const expr = try self.exprs.addOne(self.scratch);
            expr.setValue(
                self.exprs,
                .{ .property = .{ .parent = root_expr_ref, .name = field_name } },
            );

            root_expr_ref = expr;
        }

        return root_expr_ref;
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

fn matchAny(self: *Parser, comptime tags: []const TokenTag) ?Token {
    const tok = self.peek() orelse return null;
    const tok_tag = activeTag(tok);

    inline for (tags) |tag| {
        if (tok_tag == tag) {
            self.pos += 1;
            return tok;
        }
    }

    return null;
}

fn advance(self: *Parser) ?Token {
    defer self.pos += 1;
    return self.peek();
}

fn consume(self: *Parser, tag: TokenTag) Token {
    const tok = self.advance() orelse unreachable;
    assert(activeTag(tok) == tag);
    return tok;
}

fn peek(self: *const Parser) ?Token {
    return if (self.isAtEnd())
        null
    else
        self.src[self.pos];
}

fn peekNext(self: *const Parser) ?Token {
    return if (self.pos + 1 >= self.src.len)
        null
    else
        self.src[self.pos + 1];
}

fn isAtEnd(self: *const Parser) bool {
    return self.pos >= self.src.len;
}
