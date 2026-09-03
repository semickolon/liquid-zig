const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Renderer = @This();

const liquid = @import("root.zig");
const Ast = @import("Ast.zig");

ast: liquid.Ast,
writer: *Io.Writer,
scratch: Allocator,

pub const Error = Allocator.Error || Io.Writer.Error || error{NotImplemented};

pub fn render(allocator: Allocator, writer: *Io.Writer, ast: liquid.Ast, context: liquid.Value) Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var r = Renderer{
        .ast = ast,
        .writer = writer,
        .scratch = arena.allocator(),
    };

    try r.renderNode(context, ast.root_node);
}

fn renderNode(self: *const Renderer, context: liquid.Value, ref: Ast.NodeRef) Error!void {
    switch (self.nodePtr(ref).*) {
        .raw => |raw| try self.writer.writeAll(raw),
        .object => |obj| try self.renderObject(context, obj),
        .tag => |tag| try self.renderTag(context, tag),
        .block => |children| for (children) |child| {
            try self.renderNode(context, child);
        },
    }
}

fn renderObject(self: *const Renderer, context: liquid.Value, obj: Ast.Object) Error!void {
    var value = try self.evalExpr(context, obj.expr);

    for (obj.filters) |filter| {
        if (std.mem.eql(u8, filter.name, "default")) {
            assert(filter.args.len > 0);
            assert(filter.args[0].name.len == 0);

            if (value.isDefaultReplaceable()) {
                value = try self.evalExpr(context, filter.args[0].value);
            }
        } else {
            return error.NotImplemented;
        }
    }

    try value.render(self.writer);
}

fn renderTag(self: *const Renderer, context: liquid.Value, tag: Ast.Tag) Error!void {
    for (tag.conditional.branches) |b| {
        const condition = try self.evalExpr(context, b.condition);
        if (condition.isTruthy() == !b.unless) {
            return try self.renderNode(context, b.block);
        }
    }

    if (tag.conditional.fallback) |fallback| {
        try self.renderNode(context, fallback);
    }
}

fn nodePtr(self: *const Renderer, ref: Ast.NodeRef) *const Ast.Node {
    return &self.ast.nodes[ref.idx];
}

fn exprPtr(self: *const Renderer, ref: Ast.ExprRef) *const Ast.Expr {
    return &self.ast.exprs[ref.idx];
}

fn evalExpr(self: *const Renderer, context: liquid.Value, ref: Ast.ExprRef) error{NotImplemented}!liquid.Value {
    return switch (self.exprPtr(ref).*) {
        .literal => |lit| lit,
        .variable => |v| context.get(v),
        .property => |f| (try self.evalExpr(context, f.parent)).get(f.name),
        .logical => |log| blk: {
            const lhs = (try self.evalExpr(context, log.lhs)).isTruthy();
            const rhs = (try self.evalExpr(context, log.rhs)).isTruthy();

            break :blk .{
                .bool = switch (log.op) {
                    .@"and" => lhs and rhs,
                    .@"or" => lhs or rhs, // TODO: optimize
                },
            };
        },
        .comparison => |comp| blk: {
            const lhs = try self.evalExpr(context, comp.lhs);
            const rhs = try self.evalExpr(context, comp.rhs);

            const result: bool = switch (comp.op) {
                .equal_equal => lhs.eql(rhs),
                .bang_equal => !lhs.eql(rhs),
                else => return error.NotImplemented,
            };

            break :blk .{ .bool = result };
        },
    };
}
