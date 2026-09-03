const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const liquid = @import("root.zig");
const lib = @import("lib.zig");

const Tokenizer = @This();

allocator: Allocator,
src: []const u8,
tokens: std.ArrayList(Token),
start: usize = 0,
pos: usize = 0,
raw_mode: bool = true,

pub fn tokenize(allocator: Allocator, src: []const u8) Allocator.Error![]Token {
    var t = Tokenizer{
        .allocator = allocator,
        .src = src,
        .tokens = try .initCapacity(allocator, 256),
    };
    errdefer t.tokens.deinit(allocator);

    try t.root();
    return try t.tokens.toOwnedSlice(allocator);
}

fn root(self: *Tokenizer) Allocator.Error!void {
    while (!self.isAtEnd()) {
        if (self.raw_mode) {
            try self.raw();
        } else {
            try self.nonRaw();
        }
    }

    assert(self.raw_mode);
    try self.appendRawToken(self.src[self.start..]);
}

fn raw(self: *Tokenizer) Allocator.Error!void {
    if (self.advance() != '{') return;

    const start_tok: Token = switch (self.matchAny("{%") orelse return) {
        '{' => .start_object,
        '%' => .start_tag,
        else => unreachable,
    };

    const trimmed_str = blk: {
        const raw_str = self.src[self.start .. self.pos - 2];
        if (self.match('-')) {
            break :blk std.mem.trimEnd(u8, raw_str, lib.whitespace_chars);
        } else {
            break :blk raw_str;
        }
    };

    try self.appendRawToken(trimmed_str);
    try self.appendToken(start_tok);

    self.raw_mode = false;
}

fn nonRaw(self: *Tokenizer) Allocator.Error!void {
    self.start = self.pos;

    const tok: Token = switch (self.advance().?) {
        '-' => switch (self.peek() orelse unreachable) {
            '0'...'9' => self.numberToken('-'),
            '}', '%' => |c| blk: {
                self.consume(c);
                break :blk self.endToken(c, true);
            },
            else => unreachable,
        },
        '}', '%' => |c| self.endToken(c, false),
        '|' => .pipe,
        ':' => .colon,
        ',' => .comma,
        '.' => if (self.match('.'))
            .dot_dot
        else if (isDigit(self.peek() orelse unreachable))
            self.numberToken('.')
        else
            .dot,
        '(' => .open_par,
        ')' => .close_par,
        '[' => .open_brc,
        ']' => .close_brc,
        '=' => if (self.match('=')) .equal_equal else .equal,
        '!' => blk: {
            self.consume('=');
            break :blk .bang_equal;
        },
        '<' => if (self.match('='))
            .lt_equal
        else if (self.match('>'))
            .lt_gt
        else
            .lt,
        '>' => if (self.match('=')) .gt_equal else .gt,
        '\'', '"' => |sentinel| self.stringToken(sentinel),
        '0'...'9' => |c| self.numberToken(c),
        'a'...'z', 'A'...'Z', '_' => self.identifierToken(),
        else => |c| {
            if (isWhitespace(c)) return;
            unreachable;
        },
    };

    try self.appendToken(tok);
}

fn stringToken(self: *Tokenizer, sentinel: u8) Token {
    while (self.advance()) |c| {
        if (c == sentinel) {
            const str = self.src[self.start + 1 .. self.pos - 1];
            return .{ .string = str };
        }
    }
    unreachable;
}

fn numberToken(self: *Tokenizer, first_char: u8) Token {
    var fractional = first_char == '.';

    if (!fractional) {
        if (first_char == '-') self.consumeFn(isDigit);
        self.matchWhile(isDigit);
        fractional = self.match('.');

        if (self.peek() == '.') {
            self.pos -= 1; // TODO wtf
            return .{ .int = std.fmt.parseInt(i32, self.src[self.start..self.pos], 10) catch unreachable };
        }
    }

    if (fractional) {
        self.consumeFn(isDigit);
        self.matchWhile(isDigit);

        if (self.match('.')) unreachable;
    }

    const str = self.src[self.start..self.pos];

    if (fractional) {
        return .{ .float = std.fmt.parseFloat(f32, str) catch unreachable };
    } else {
        return .{ .int = std.fmt.parseInt(i32, str, 10) catch unreachable };
    }
}

fn identifierToken(self: *Tokenizer) Token {
    self.matchWhile(isIdent);
    const ident = self.src[self.start..self.pos];
    return Token.keyword_map.get(ident) orelse .{ .identifier = ident };
}

fn endToken(self: *Tokenizer, first_char: u8, trim_start_next_raw: bool) Token {
    self.consume('}');

    if (trim_start_next_raw) {
        self.matchWhile(isWhitespace);
    }

    self.start = self.pos;
    self.raw_mode = true;

    return switch (first_char) {
        '}' => .end_object,
        '%' => .end_tag,
        else => unreachable,
    };
}

fn appendToken(self: *Tokenizer, tok: Token) Allocator.Error!void {
    try self.tokens.append(self.allocator, tok);
}

fn appendRawToken(self: *Tokenizer, str: []const u8) Allocator.Error!void {
    if (str.len == 0) return;
    try self.appendToken(.{ .raw = str });
}

fn advance(self: *Tokenizer) ?u8 {
    defer self.pos += 1;
    return self.peek();
}

fn peek(self: *const Tokenizer) ?u8 {
    return if (self.isAtEnd())
        null
    else
        self.src[self.pos];
}

fn isAtEnd(self: *const Tokenizer) bool {
    return self.pos >= self.src.len;
}

fn consume(self: *Tokenizer, expected: u8) void {
    assert(self.advance() == expected);
}

fn consumeFn(self: *Tokenizer, comptime predicate: fn (char: u8) bool) void {
    assert(predicate(self.advance() orelse unreachable));
}

fn match(self: *Tokenizer, expected: u8) bool {
    if (self.peek() == expected) {
        self.pos += 1;
        return true;
    }
    return false;
}

fn matchAny(self: *Tokenizer, comptime set: []const u8) ?u8 {
    const p = self.peek() orelse return null;
    inline for (set) |expected| {
        if (p == expected) {
            self.pos += 1;
            return p;
        }
    }
    return null;
}

fn matchFn(self: *Tokenizer, comptime predicate: fn (char: u8) bool) ?u8 {
    const c = self.peek() orelse return null;
    if (predicate(c)) {
        self.pos += 1;
        return c;
    }
    return null;
}

fn matchWhile(self: *Tokenizer, comptime predicate: fn (char: u8) bool) void {
    while (self.peek()) |c| {
        if (predicate(c)) {
            self.pos += 1;
        } else {
            break;
        }
    }
}

pub const Token = union(enum) {
    raw: []const u8,

    start_object,
    end_object,
    start_tag,
    end_tag,

    keyword: Keyword,
    identifier: []const u8,

    int: i32,
    float: f32,
    string: []const u8,

    pipe,
    colon,
    comma,
    dot,
    dot_dot,
    equal,
    open_par,
    close_par,
    open_brc,
    close_brc,
    comparison_op: ComparisonOp,

    const equal_equal = Token{ .comparison_op = .equal_equal };
    const bang_equal = Token{ .comparison_op = .bang_equal };
    const lt_gt = Token{ .comparison_op = .lt_gt };
    const lt = Token{ .comparison_op = .lt };
    const lt_equal = Token{ .comparison_op = .lt_equal };
    const gt = Token{ .comparison_op = .gt };
    const gt_equal = Token{ .comparison_op = .gt_equal };

    const keyword_map = std.StaticStringMap(Token).initComptime(.{
        .{ "nil", Token{ .keyword = .nil } },
        .{ "null", Token{ .keyword = .nil } },
        .{ "true", Token{ .keyword = .true } },
        .{ "false", Token{ .keyword = .false } },
        .{ "empty", Token{ .keyword = .empty } },
        .{ "blank", Token{ .keyword = .blank } },
        .{ "and", Token{ .keyword = .@"and" } },
        .{ "or", Token{ .keyword = .@"or" } },
        .{ "contains", Token{ .comparison_op = .contains } },
    });

    const Keyword = enum {
        nil,
        true,
        false,
        empty,
        blank,
        @"and",
        @"or",
    };

    pub const ComparisonOp = enum {
        equal_equal,
        bang_equal,
        lt_gt,
        lt,
        lt_equal,
        gt,
        gt_equal,
        contains,
    };

    pub fn debug(self: Token) void {
        switch (self) {
            .raw => |s| std.log.debug("\"{s}\"", .{s}),
            .identifier => |s| std.log.debug("IDENT({s})", .{s}),
            .string => |s| std.log.debug("STR({s})", .{s}),
            else => std.log.debug("{any}", .{self}),
        }
    }
};

fn isAlpha(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn isAlphaNumeric(char: u8) bool {
    return isAlpha(char) or isDigit(char);
}

fn isIdent(char: u8) bool {
    return char == '_' or char == '-' or isAlphaNumeric(char);
}

fn isWhitespace(char: u8) bool {
    inline for (lib.whitespace_chars) |wc| {
        if (char == wc) return true;
    }
    return false;
}
