const std = @import("std");
const Allocator = std.mem.Allocator;

const liquid = @import("root.zig");
const Value = liquid.Value;

const Token = @import("Tokenizer.zig").Token;
const IndexableArrayList = @import("lib.zig").IndexableArrayList;

const Ast = @This();

arena: std.heap.ArenaAllocator,
root_node: NodeRef,
nodes: []const Node,
exprs: []const Expr,

pub fn deinit(self: *const Ast) void {
    self.arena.deinit();
}

pub const NodeRef = IndexableArrayList(Node).Ref;
pub const ExprRef = IndexableArrayList(Expr).Ref;

pub const Node = union(enum) {
    block: []const NodeRef,
    raw: []const u8,
    object: FilteredExpr,
    tag: Tag,
};

pub const FilteredExpr = struct {
    expr: ExprRef,
    filters: []const Filter,
};

pub const Filter = struct {
    name: []const u8,
    args: []const Arg,

    pub const Arg = struct {
        name: []const u8,
        value: ExprRef,

        pub fn isPositional(self: Arg) bool {
            return self.name.len == 0;
        }
    };
};

pub const Tag = union(enum) {
    conditional: Conditional,
    assign: Assign,

    pub const Conditional = struct {
        branches: []const Branch,
        fallback: ?NodeRef = null,
    };

    pub const Assign = struct {
        ident: []const u8,
        filtered_expr: FilteredExpr,
    };

    pub const Branch = struct {
        condition: ExprRef,
        unless: bool,
        block: NodeRef,
    };
};

pub const Expr = union(enum) {
    literal: Value,
    variable: []const u8,
    property: struct {
        parent: ExprRef,
        name: []const u8,
    },
    logical: struct {
        op: enum { @"and", @"or" },
        lhs: ExprRef,
        rhs: ExprRef,
    },
    comparison: struct {
        op: Token.ComparisonOp,
        lhs: ExprRef,
        rhs: ExprRef,
    },
};
