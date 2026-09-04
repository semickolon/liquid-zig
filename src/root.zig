const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const activeTag = std.meta.activeTag;

const lib = @import("lib.zig");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Parser = @import("Parser.zig");
pub const Ast = @import("Ast.zig");

const Renderer = @import("Renderer.zig");

pub fn parse(allocator: Allocator, src: []const u8) !Ast {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const tokens = try Tokenizer.tokenize(scratch, src);
    // for (tokens) |tok| {
    //     tok.debug();
    // }

    const ast = try Parser.parse(allocator, scratch, tokens);
    errdefer ast.deinit();

    return ast;
}

pub const render = Renderer.render;

pub const Value = union(enum) {
    nil,
    empty,
    blank,
    bool: bool,
    number: Number,
    string: []const u8,
    array: []const Value,
    hash: std.StringHashMapUnmanaged(Value),

    pub const Allocation = struct {
        root: Value,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *const Allocation) void {
            self.arena.deinit();
        }
    };

    pub fn init(json_value: std.json.Value, gpa: Allocator) Allocator.Error!Allocation {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        return .{
            .root = try .initLeaky(json_value, arena.allocator()),
            .arena = arena,
        };
    }

    pub fn initLeaky(json_value: std.json.Value, allocator: Allocator) Allocator.Error!Value {
        return switch (json_value) {
            .null => .nil,
            .bool => |b| .{ .bool = b },
            inline .integer, .float => |n| .{ .number = .from(n) },
            .number_string => @panic("Not implemented"),
            .string => |s| .{ .string = s },
            .array => |a| blk: {
                const values = try allocator.alloc(Value, a.items.len);

                for (a.items, 0..) |item, i| {
                    values[i] = try Value.initLeaky(item, allocator);
                }

                break :blk .{ .array = values };
            },
            .object => |h| blk: {
                var hash = std.StringHashMapUnmanaged(Value).empty;
                try hash.ensureTotalCapacity(allocator, @intCast(h.entries.len));

                var iter = h.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const value = try Value.initLeaky(entry.value_ptr.*, allocator);
                    hash.putAssumeCapacityNoClobber(key, value);
                }

                break :blk .{ .hash = hash };
            },
        };
    }

    pub fn isTruthy(self: *const Value) bool {
        return switch (self.*) {
            .nil => false,
            .bool => |b| b,
            else => true,
        };
    }

    pub fn isEmpty(self: *const Value) bool {
        return switch (self.*) {
            .empty => true,
            .blank => @panic("Not implemented"),
            .string => |s| s.len == 0,
            .array => |a| a.len == 0,
            .hash => |h| h.size == 0,
            else => false,
        };
    }

    pub fn isBlank(self: *const Value) bool {
        return switch (self.*) {
            .nil, .empty, .blank => true,
            .bool => |b| !b,
            .string => |s| isWhitespaceOnly(s),
            .array => |a| a.len == 0,
            .hash => |h| h.size == 0,
            else => false,
        };
    }

    pub fn isDefaultReplaceable(self: *const Value) bool {
        return switch (self.*) {
            .nil => true,
            .bool => |b| !b,
            .string => |s| s.len == 0,
            .array => |a| a.len == 0,
            .hash => |h| h.size == 0,
            else => false,
        };
    }

    pub fn eql(self: Value, other: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            if (self == .empty) {
                return other.isEmpty();
            } else if (self == .blank) {
                return other.isBlank();
            } else if (other == .empty) {
                return self.isEmpty();
            } else if (other == .blank) {
                return self.isBlank();
            } else {
                return false;
            }
        }

        return switch (self) {
            .nil, .empty, .blank => true,
            .bool => |b| b == other.bool,
            .number => |n| n.eql(other.number),
            .string => |s| std.mem.eql(u8, s, other.string),
            .array => @panic("Not implemented"),
            .hash => @panic("Not implemnented"),
        };
    }

    pub fn lessThan(self: Value, other: Value) bool {
        return switch (self) {
            .number => |a| switch (other) {
                .number => |b| a.lessThan(b),
                else => @panic("Not implemented"),
            },
            else => @panic("Not implemented"),
        };
    }

    pub fn greaterThan(self: Value, other: Value) bool {
        return switch (self) {
            .number => |a| switch (other) {
                .number => |b| a.greaterThan(b),
                else => @panic("Not implemented"),
            },
            else => @panic("Not implemented"),
        };
    }

    pub fn contains(self: Value, other: Value) bool {
        const what = switch (other) {
            .string => |str| str,
            else => return false,
        };

        switch (self) {
            .string => |str| return std.mem.find(u8, str, what) != null,
            .array => |array| for (array) |item| {
                switch (item) {
                    .string => |str| if (std.mem.eql(u8, str, what)) return true,
                    else => {},
                }
            },
            else => {},
        }

        return false;
    }

    pub fn get(self: *const Value, property: []const u8) Value {
        switch (self.*) {
            .nil => return .nil,
            .array => |a| {
                if (std.mem.eql(u8, property, "size")) {
                    return .{ .number = .from(a.len) };
                }
                @panic("Not implemented");
            },
            .hash => |h| {
                return h.get(property) orelse .nil;
            },
            else => @panic("Not implemented"),
        }
    }

    pub fn render(self: *const Value, writer: *Io.Writer) !void {
        switch (self.*) {
            .nil, .empty, .blank => {},
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .number => |num| switch (num) {
                .int => |n| try writer.printInt(n, 10, .lower, .{}),
                .float => |n| try writer.printFloat(n, .{}),
            },
            .string => |s| try writer.writeAll(s),
            .array => |a| for (a) |item| try item.render(writer),
            .hash => @panic("Not implemented"),
        }
    }
};

pub const Number = union(enum) {
    int: i32,
    float: f32,

    const CompareOp = enum { eql, lt, gt, lt_eql, gt_eql };

    pub fn from(value: anytype) Number {
        return switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => .{ .int = @intCast(value) },
            .float, .comptime_float => .{ .float = @floatCast(value) },
            else => @panic("Invalid type for Number"),
        };
    }

    fn compare(self: Number, other: Number, op: CompareOp) bool {
        if (activeTag(self) == .float or activeTag(other) == .float) {
            const a = self.asFloat();
            const b = other.asFloat();

            return switch (op) {
                .eql => a == b,
                .lt => a < b,
                .gt => a > b,
                .lt_eql => a <= b,
                .gt_eql => a >= b,
            };
        } else { // both ints
            const a = self.int;
            const b = other.int;

            return switch (op) {
                .eql => a == b,
                .lt => a < b,
                .gt => a > b,
                .lt_eql => a <= b,
                .gt_eql => a >= b,
            };
        }
    }

    pub fn asFloat(self: Number) f32 {
        return switch (self) {
            .int => |n| @floatFromInt(n),
            .float => |n| n,
        };
    }

    pub fn eql(self: Number, other: Number) bool {
        return self.compare(other, .eql);
    }

    pub fn lessThan(self: Number, other: Number) bool {
        return self.compare(other, .lt);
    }

    pub fn greaterThan(self: Number, other: Number) bool {
        return self.compare(other, .gt);
    }

    pub fn lessThanOrEql(self: Number, other: Number) bool {
        return self.compare(other, .lt_eql);
    }

    pub fn greaterThanOrEql(self: Number, other: Number) bool {
        return self.compare(other, .gt_eql);
    }
};

fn isWhitespaceOnly(str: []const u8) bool {
    return str.len == 0 or std.mem.trimEnd(u8, str, lib.whitespace_chars).len == 0;
}
