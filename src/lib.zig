const std = @import("std");
const Allocator = std.mem.Allocator;

pub const whitespace_chars = " \n\t\r";

pub fn IndexableArrayList(comptime T: type) type {
    return struct {
        list: std.ArrayList(T) = .empty,

        const Self = @This();

        pub const Ref = struct {
            idx: usize,

            pub fn ptr(self: Ref, ial: Self) *T {
                return &ial.list.items[self.idx];
            }

            pub fn setValue(self: Ref, ial: Self, value: T) void {
                self.ptr(ial).* = value;
            }
        };

        pub fn initCapacity(allocator: Allocator, num: usize) Allocator.Error!Self {
            return .{ .list = try .initCapacity(allocator, num) };
        }

        pub fn addOne(self: *Self, allocator: Allocator) Allocator.Error!Ref {
            _ = try self.list.addOne(allocator);
            return .{ .idx = self.list.items.len - 1 };
        }

        pub fn append(self: *Self, allocator: Allocator, item: T) Allocator.Error!Ref {
            try self.list.append(allocator, item);
            return .{ .idx = self.list.items.len - 1 };
        }
    };
}
