const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Renderer = @This();

const liquid = @import("root.zig");
const Ast = @import("Ast.zig");
const lib = @import("lib.zig");

ast: liquid.Ast,
scratch: Allocator,

pub const Error = Allocator.Error || Io.Writer.Error || error{NotImplemented};

const Context = struct {
    dynamic: *std.StringHashMapUnmanaged(liquid.Value),
    static: liquid.Value,

    pub fn resolve(self: Context, key: []const u8) liquid.Value {
        return self.dynamic.get(key) orelse self.static.get(key);
    }

    pub fn assign(self: Context, scratch: Allocator, key: []const u8, value: liquid.Value) Allocator.Error!void {
        try self.dynamic.put(scratch, key, value);
    }
};

pub fn render(allocator: Allocator, writer: *Io.Writer, ast: liquid.Ast, static_env: liquid.Value) Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var dynamic = std.StringHashMapUnmanaged(liquid.Value).empty;
    const context = Context{
        .dynamic = &dynamic,
        .static = static_env,
    };

    var r = Renderer{
        .ast = ast,
        .scratch = arena.allocator(),
    };

    try r.renderNode(context, writer, ast.root_node);
}

fn renderNode(self: *const Renderer, context: Context, writer: *Io.Writer, ref: Ast.NodeRef) Error!void {
    switch (self.nodePtr(ref).*) {
        .raw => |raw| try writer.writeAll(raw),
        .object => |obj| try self.renderObject(context, writer, obj),
        .tag => |tag| try self.renderTag(context, writer, tag),
        .block => |children| for (children) |child| {
            try self.renderNode(context, writer, child);
        },
    }
}

fn renderObject(self: *const Renderer, context: Context, writer: *Io.Writer, filtered_expr: Ast.FilteredExpr) Error!void {
    const value = try self.evalFilteredExpr(context, filtered_expr);
    try value.render(writer);
}

fn renderTag(self: *const Renderer, context: Context, writer: *Io.Writer, tag: Ast.Tag) Error!void {
    switch (tag) {
        .conditional => |c| {
            for (c.branches) |b| {
                const condition = try self.evalExpr(context, b.condition);
                if (condition.isTruthy() == !b.unless) {
                    return try self.renderNode(context, writer, b.block);
                }
            }

            if (c.fallback) |fallback| {
                return try self.renderNode(context, writer, fallback);
            }
        },
        .assign => |a| {
            const value = try self.evalFilteredExpr(context, a.filtered_expr);
            try context.assign(self.scratch, a.ident, value);
        },
    }
}

fn evalFilteredExpr(self: *const Renderer, context: Context, filtered_expr: Ast.FilteredExpr) !liquid.Value {
    var value = try self.evalExpr(context, filtered_expr.expr);

    for (filtered_expr.filters) |filter| {
        value = try self.applyFilter(context, filter, value);
    }

    return value;
}

fn evalExpr(self: *const Renderer, context: Context, ref: Ast.ExprRef) error{NotImplemented}!liquid.Value {
    return switch (self.exprPtr(ref).*) {
        .literal => |lit| lit,
        .variable => |v| context.resolve(v),
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

fn nodePtr(self: *const Renderer, ref: Ast.NodeRef) *const Ast.Node {
    return &self.ast.nodes[ref.idx];
}

fn exprPtr(self: *const Renderer, ref: Ast.ExprRef) *const Ast.Expr {
    return &self.ast.exprs[ref.idx];
}

fn applyFilter(self: *const Renderer, context: Context, filter: Ast.Filter, in: liquid.Value) !liquid.Value {
    inline for (comptime std.meta.declarations(Filters)) |decl| {
        const func = @field(Filters, decl.name);
        const Fn = @TypeOf(func);
        const fn_info = @typeInfo(Fn).@"fn";
        const params = fn_info.params;

        comptime assert(params[0].type.? == Allocator);
        comptime assert(params[1].type.? == liquid.Value);

        comptime var positional_args = 0;

        comptime if (params.len >= 3) {
            const args_info = @typeInfo(params[2].type.?);

            assert(std.meta.activeTag(args_info) == .array);
            assert(args_info.array.len > 0);
            assert(args_info.array.child == liquid.Value);

            positional_args = args_info.array.len;
        };

        if (std.mem.eql(u8, filter.name, decl.name)) {
            if (positional_args > 0) {
                const args = try self.makePositionalArgs(positional_args, context, filter);
                return try @call(.auto, func, .{ self.scratch, in, args });
            } else {
                return try @call(.auto, func, .{ self.scratch, in });
            }
        }
    }

    return error.NotImplemented;
}

fn makePositionalArgs(self: *const Renderer, comptime len: comptime_int, context: Context, filter: Ast.Filter) ![len]liquid.Value {
    var args = [_]liquid.Value{.nil} ** len;
    var cur: usize = 0;

    for (filter.args) |arg| {
        if (cur == len) break;
        if (arg.isPositional()) {
            args[cur] = try self.evalExpr(context, arg.value);
            cur += 1;
        }
    }

    return args;
}

const FilterInfo = struct {
    scratch: Allocator,
    input: liquid.Value,
};

inline fn safeGetTag(e: anytype, comptime tag: std.meta.Tag(@TypeOf(e))) ?@FieldType(@TypeOf(e), @tagName(tag)) {
    if (std.meta.activeTag(e) == tag) {
        return @field(e, @tagName(tag));
    }
    return null;
}

const Filters = struct {
    const R = Allocator.Error!liquid.Value;

    pub fn append(scratch: Allocator, in: liquid.Value, args: [1]liquid.Value) R {
        return switch (in) {
            .string => |src| {
                const end = safeGetTag(args[0], .string) orelse return in;
                if (end.len == 0) return in;

                const out = try std.mem.concat(scratch, u8, &.{ src, end });
                return .{ .string = out };
            },
            else => in,
        };
    }

    pub fn capitalize(scratch: Allocator, in: liquid.Value) R {
        switch (in) {
            .string => |src| {
                if (src.len == 0) return in;

                const out = try scratch.alloc(u8, src.len);
                out[0] = std.ascii.toUpper(src[0]);
                if (src.len > 1) _ = std.ascii.lowerString(out[1..], src[1..]);

                return .{ .string = out };
            },
            else => return in,
        }
    }

    pub fn default(_: Allocator, in: liquid.Value, args: [1]liquid.Value) R {
        return if (in.isDefaultReplaceable()) args[0] else in;
    }

    pub fn downcase(scratch: Allocator, in: liquid.Value) R {
        return switch (in) {
            .string => |src| .{ .string = try std.ascii.allocLowerString(scratch, src) },
            else => in,
        };
    }

    pub fn size(_: Allocator, in: liquid.Value) R {
        return switch (in) {
            inline .string, .array => |src| .{ .int = @intCast(src.len) },
            else => in,
        };
    }

    pub fn strip(_: Allocator, in: liquid.Value) R {
        return switch (in) {
            .string => |src| .{ .string = std.mem.trim(u8, src, lib.whitespace_chars) },
            else => in,
        };
    }

    pub fn upcase(scratch: Allocator, in: liquid.Value) R {
        return switch (in) {
            .string => |src| .{ .string = try std.ascii.allocUpperString(scratch, src) },
            else => in,
        };
    }
};
