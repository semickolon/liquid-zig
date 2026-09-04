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

const ControlFlow = enum { none, brk, cont };

const Context = struct {
    dynamic: *std.StringHashMapUnmanaged(liquid.Value),
    static: liquid.Value,
    for_loop: ?*const ForLoop = null,

    const ForLoop = struct {
        length: usize,
        index: usize = 0,
        hash: std.StringHashMapUnmanaged(liquid.Value) = .empty,

        fn init(scratch: Allocator, length: usize) Allocator.Error!ForLoop {
            const forloop = .{
                .length = liquid.Value{ .number = .from(length) },
                .parentloop = liquid.Value.nil, // TODO
                .index = liquid.Value{ .number = .from(1) },
                .index0 = liquid.Value{ .number = .from(0) },
                .rindex = liquid.Value{ .number = .from(length) },
                .rindex0 = liquid.Value{ .number = .from(length - 1) },
                .first = liquid.Value{ .bool = true },
                .last = liquid.Value{ .bool = length == 1 },
            };
            const forloop_fields = comptime std.meta.fieldNames(@TypeOf(forloop));

            var self = ForLoop{ .length = length };
            try self.hash.ensureTotalCapacity(scratch, forloop_fields.len);

            inline for (forloop_fields) |field_name| {
                self.hash.putAssumeCapacityNoClobber(field_name, @field(forloop, field_name));
            }

            return self;
        }

        fn resolve(self: *const ForLoop) liquid.Value {
            return .{ .hash = self.hash };
        }

        fn increment(self: *ForLoop) void {
            self.index += 1;
            self.hash.getPtr("index").?.number.int += 1;
            self.hash.getPtr("index0").?.number.int += 1;
            self.hash.getPtr("rindex").?.number.int -= 1;
            self.hash.getPtr("rindex0").?.number.int -= 1;

            if (self.index == 1)
                self.hash.getPtr("first").?.bool = false;

            if (self.index == self.length - 1)
                self.hash.getPtr("last").?.bool = true;
        }
    };

    fn resolve(self: Context, key: []const u8) liquid.Value {
        if (self.for_loop) |fl| {
            if (std.mem.eql(u8, key, "forloop"))
                return fl.resolve();
        }
        return self.dynamic.get(key) orelse self.static.get(key);
    }

    fn assign(self: Context, scratch: Allocator, key: []const u8, value: liquid.Value) Allocator.Error!void {
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

    const cf = try r.renderNode(context, writer, ast.root_node);
    assert(cf == .none);
}

fn renderNode(self: *const Renderer, context: Context, writer: *Io.Writer, ref: Ast.NodeRef) Error!ControlFlow {
    switch (self.nodePtr(ref).*) {
        .raw => |raw| try writer.writeAll(raw),
        .object => |obj| try self.renderObject(context, writer, obj),
        .tag => |tag| return try self.renderTag(context, writer, tag),
        .block => |children| for (children) |child| {
            const cf = try self.renderNode(context, writer, child);
            switch (cf) {
                .none => {},
                .brk, .cont => return cf,
            }
        },
    }
    return .none;
}

fn renderObject(self: *const Renderer, context: Context, writer: *Io.Writer, filtered_expr: Ast.FilteredExpr) Error!void {
    const value = try self.evalFilteredExpr(context, filtered_expr);
    try value.render(writer);
}

fn renderTag(self: *const Renderer, context: Context, writer: *Io.Writer, tag: Ast.Tag) Error!ControlFlow {
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
        .@"for" => |f| {
            if (try self.evalIterable(context, f.collection)) |iterable| {
                var iter_opts = Iterable.IteratorOpts{};
                iter_opts.reverse = f.opt_reversed;

                if (f.opt_offset) |expr| {
                    switch (try self.evalExpr(context, expr)) {
                        .number => |n| switch (n) {
                            .int => |offset| if (offset >= 0) {
                                iter_opts.offset = @intCast(offset);
                            } else {
                                @panic("Negative forloop offset");
                            },
                            else => unreachable,
                        },
                        else => unreachable,
                    }
                }

                if (f.opt_limit) |expr| {
                    switch (try self.evalExpr(context, expr)) {
                        .number => |n| switch (n) {
                            .int => |limit| if (limit >= 0) {
                                iter_opts.limit = @intCast(limit);
                            } else {
                                @panic("Negative forloop limit");
                            },
                            else => unreachable,
                        },
                        else => unreachable,
                    }
                }

                var iter = iterable.iterator(iter_opts);
                var forloop = try Context.ForLoop.init(self.scratch, iter.remaining);
                var context_inner = context;
                context_inner.for_loop = &forloop; // TODO nesting

                while (iter.next()) |item| : (forloop.increment()) {
                    try context_inner.assign(self.scratch, f.iter_ident, item);
                    const cf = try self.renderNode(context_inner, writer, f.body);
                    switch (cf) {
                        .none => {},
                        .brk => break,
                        .cont => continue,
                    }
                }
            } else if (f.fallback) |fb| {
                return try self.renderNode(context, writer, fb);
            }
        },
        .@"break" => return .brk,
        .@"continue" => return .cont,
    }

    return .none;
}

fn evalFilteredExpr(self: *const Renderer, context: Context, filtered_expr: Ast.FilteredExpr) !liquid.Value {
    var value = try self.evalExpr(context, filtered_expr.expr);

    for (filtered_expr.filters) |filter| {
        value = try self.applyFilter(context, filter, value);
    }

    return value;
}

fn evalExpr(self: *const Renderer, context: Context, ref: Ast.ExprRef) Error!liquid.Value {
    return self.evalExprInner(context, self.exprPtr(ref).*);
}

fn evalExprInner(self: *const Renderer, context: Context, expr: Ast.Expr) Error!liquid.Value {
    return switch (expr) {
        .literal => |lit| lit,
        .variable => |v| context.resolve(v),
        .property => |f| (try self.evalExpr(context, f.parent)).get(f.name),
        .logical => |log| .{
            .bool = blk: {
                const lhs = (try self.evalExpr(context, log.lhs)).isTruthy();
                switch (log.op) {
                    .@"and" => if (!lhs) break :blk false,
                    .@"or" => if (lhs) break :blk true,
                }

                const rhs = (try self.evalExpr(context, log.rhs)).isTruthy();
                break :blk rhs;
            },
        },
        .comparison => |comp| blk: {
            const lhs = try self.evalExpr(context, comp.lhs);
            const rhs = try self.evalExpr(context, comp.rhs);

            const result: bool = switch (comp.op) {
                .equal_equal => lhs.eql(rhs),
                .bang_equal, .lt_gt => !lhs.eql(rhs),
                .lt => lhs.lessThan(rhs),
                .gt => lhs.greaterThan(rhs),
                .lt_equal => lhs.lessThan(rhs) or lhs.eql(rhs),
                .gt_equal => lhs.greaterThan(rhs) or lhs.eql(rhs),
                .contains => lhs.contains(rhs),
            };

            break :blk .{ .bool = result };
        },
        .range => blk: {
            const iterable = (try self.evalIterableInner(context, expr)).?;
            const values = try iterable.allocSlice(self.scratch);
            break :blk .{ .array = values };
        },
    };
}

fn evalIterable(self: *const Renderer, context: Context, ref: Ast.ExprRef) Error!?Iterable {
    return self.evalIterableInner(context, self.exprPtr(ref).*);
}

// Returns null if evaluated value is either non-iterable or a zero-size iterable
fn evalIterableInner(self: *const Renderer, context: Context, expr: Ast.Expr) Error!?Iterable {
    switch (expr) {
        .range => |r| {
            const start = (try self.evalExpr(context, r.start)).number.int;
            const end = (try self.evalExpr(context, r.end)).number.int;

            if (start > end) {
                @panic("Range start is greater than range end");
            }
            // Apparently, ranges can never be zero-size
            return .{ .range = .{
                .start = start,
                .count = @intCast(end - start + 1),
            } };
        },
        else => switch (try self.evalExprInner(context, expr)) {
            .array => |a| {
                if (a.len == 0) return null;
                return .{ .array = a };
            },
            else => return null,
        },
    }
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
        const fn_info = @typeInfo(@TypeOf(func)).@"fn";
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

        if (std.mem.eql(u8, filter.name, decl.name)) { // TODO: try StaticStringMap?
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
            inline .string, .array => |src| .{ .number = .from(src.len) },
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

const Iterable = union(enum) {
    array: []const liquid.Value,
    range: struct {
        start: i32,
        count: u32,
    },

    const Iterator = struct {
        iterable: *const Iterable,
        idx: usize,
        remaining: usize,
        reverse: bool,

        fn next(self: *Iterator) ?liquid.Value {
            if (self.remaining == 0) return null;

            defer {
                if (self.reverse) {
                    // This is wrapping because at the end of the iterable, idx=0 will decrement
                    // and we don't care about the wrap because it would be remaining == 0
                    self.idx -%= 1;
                } else {
                    // Doesn't really need to wrap, but for consistency with above
                    self.idx +%= 1;
                }
                self.remaining -= 1;
            }

            return switch (self.iterable.*) {
                .array => |a| a[self.idx],
                .range => |r| .{ .number = .{ .int = r.start + @as(i32, @intCast(self.idx)) } },
            };
        }
    };

    const IteratorOpts = struct {
        limit: usize = 0,
        offset: usize = 0,
        reverse: bool = false,
    };

    fn size(self: *const Iterable) usize {
        return switch (self.*) {
            .array => |a| a.len,
            .range => |r| r.count,
        };
    }

    fn iterator(self: *const Iterable, opts: IteratorOpts) Iterator {
        const total_size = self.size();
        const size_minus_offset = total_size - opts.offset;

        const iter_size = if (opts.limit == 0)
            size_minus_offset
        else
            @min(opts.limit, size_minus_offset);

        const start_idx = if (opts.reverse)
            total_size - opts.offset - 1
        else
            opts.offset;

        return .{
            .iterable = self,
            .idx = start_idx,
            .remaining = iter_size,
            .reverse = opts.reverse,
        };
    }

    // Allocates ranges only. Arrays are returned by reference.
    fn allocSlice(self: *const Iterable, allocator: Allocator) Allocator.Error![]const liquid.Value {
        return switch (self.*) {
            .array => |a| a,
            .range => |r| blk: {
                const values = try allocator.alloc(liquid.Value, r.count);
                var cur = r.start;

                for (0..r.count) |i| {
                    values[i] = .{ .number = .from(cur) };
                    cur += 1;
                }

                break :blk values;
            },
        };
    }
};
