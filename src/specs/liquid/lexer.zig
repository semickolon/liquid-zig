const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

pub fn tokenize(allocator: Allocator, src: []const u8) ![]Token {
    var lexer = Lexer{ .src = src, .allocator = allocator };
    return try lexer.tokenize();
}

const Lexer = struct {
    src: []const u8,
    allocator: std.mem.Allocator,

    tokens: std.ArrayList(Token) = undefined,
    pos: usize = 0,

    pub fn tokenize(self: *Lexer) ![]Token {
        self.tokens = try std.ArrayList(Token).initCapacity(self.allocator, 512);
        errdefer self.tokens.deinit(self.allocator);

        var literal_mode = true;
        var literal_start: usize = 0;

        while (!self.isAtEnd()) {
            if (literal_mode) {
                const c = self.advance();

                if (c == '{') {
                    const start_tok: Token = switch (self.matchAny("{%") orelse continue) {
                        '{' => .start_object,
                        '%' => .start_tag,
                        else => unreachable,
                    };

                    const lit = self.src[literal_start .. self.pos - 2];
                    try self.appendLiteral(lit);
                    try self.appendToken(start_tok);

                    literal_mode = false;
                }

                continue;
            }

            if (self.matchAny("}%")) |c| {
                const end_tok: Token = switch (c) {
                    '}' => .end_object,
                    '%' => .end_tag,
                    else => unreachable,
                };

                assert(self.match('}'));
                try self.appendToken(end_tok);

                literal_mode = true;
                literal_start = self.pos;
            } else if (self.match('.')) {
                try self.appendToken(.dot);
            } else if (self.matchNumber()) |tok| {
                try self.appendToken(tok);
            } else if (self.matchIdentifier()) |ident| blk: {
                inline for (comptime std.meta.fieldNames(Token.Keyword)) |kw| {
                    if (std.mem.eql(u8, ident, kw)) {
                        try self.appendToken(.{ .keyword = @field(Token.Keyword, kw) });
                        break :blk;
                    }
                }

                try self.appendToken(.{ .identifier = ident });
            } else if (self.matchString()) |str| {
                try self.appendToken(.{ .string = str });
            } else if (self.matchWhile(isWhitespace)) |_| {
                // just consume
            } else if (self.matchSeq("==")) {
                try self.appendToken(.{ .logical_op = .equal });
            } else if (self.matchSeq("<=")) {
                try self.appendToken(.{ .logical_op = .less_than_or_equal });
            } else if (self.matchSeq(">=")) {
                try self.appendToken(.{ .logical_op = .greater_than_or_equal });
            } else if (self.match('<')) {
                try self.appendToken(.{ .logical_op = .less_than });
            } else if (self.match('>')) {
                try self.appendToken(.{ .logical_op = .greater_than });
            } else {
                std.log.err("err at pos {d}", .{self.pos});
                unreachable;
            }
        }

        assert(literal_mode);
        try self.appendLiteral(self.src[literal_start..]);

        return try self.tokens.toOwnedSlice(self.allocator);
    }

    fn appendToken(self: *Lexer, tok: Token) !void {
        try self.tokens.append(self.allocator, tok);
    }

    fn appendLiteral(self: *Lexer, lit: []const u8) !void {
        if (lit.len == 0) return;
        try self.tokens.append(self.allocator, .{ .literal = lit });
    }

    fn advance(self: *Lexer) ?u8 {
        defer self.pos += 1;
        return self.peek();
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.peek() == expected) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn matchAny(self: *Lexer, comptime set: []const u8) ?u8 {
        const p = self.peek() orelse return null;
        inline for (set) |expected| {
            if (p == expected) {
                self.pos += 1;
                return p;
            }
        }
        return null;
    }

    fn matchSeq(self: *Lexer, comptime expected: []const u8) bool {
        const end = self.pos + expected.len;
        const is_match = end <= self.src.len and std.mem.eql(u8, self.src[self.pos..end], expected);
        if (is_match) self.pos = end;
        return is_match;
    }

    fn matchFn(self: *Lexer, comptime predicate: fn (char: u8) bool) ?u8 {
        const c = self.peek() orelse return null;
        if (predicate(c)) {
            self.pos += 1;
            return c;
        }
        return null;
    }

    fn matchWhile(self: *Lexer, comptime predicate: fn (char: u8) bool) ?[]const u8 {
        const start = self.pos;

        while (!self.isAtEnd()) {
            _ = self.matchFn(predicate) orelse break;
        }

        if (start == self.pos) {
            return null;
        } else {
            return self.src[start..self.pos];
        }
    }

    fn matchNumber(self: *Lexer) ?Token {
        const start = self.pos;
        _ = self.matchFn(isDigit) orelse return null;

        var is_float = false;

        while (!self.isAtEnd()) {
            if (self.match('.')) {
                assert(!is_float);
                is_float = true;
            } else if (self.matchFn(isDigit)) |_| {
                // just consume
            } else if (self.match('_') or self.matchFn(isAlpha) != null) {
                std.log.err("invalid int", .{});
                unreachable;
            } else {
                break;
            }
        }

        const lit = self.src[start..self.pos];

        if (is_float) {
            return .{ .float = std.fmt.parseFloat(f32, lit) catch unreachable };
        } else {
            return .{ .int = std.fmt.parseInt(i32, lit, 10) catch unreachable };
        }
    }

    fn matchIdentifier(self: *Lexer) ?[]const u8 {
        const start = self.pos;
        _ = self.matchFn(isIdentStart) orelse return null;
        _ = self.matchWhile(isIdent);
        return self.src[start..self.pos];
    }

    fn matchString(self: *Lexer) ?[]const u8 {
        const sentinel = self.matchAny("'\"") orelse return null;
        const start = self.pos;

        while (self.advance()) |c| {
            if (c == sentinel) {
                return self.src[start .. self.pos - 1];
            }
        }

        unreachable;
    }

    fn peek(self: *const Lexer) ?u8 {
        return if (self.isAtEnd())
            null
        else
            self.src[self.pos];
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.pos >= self.src.len;
    }
};

pub const Token = union(enum) {
    literal: []const u8,
    start_object: void,
    end_object: void,
    start_tag: void,
    end_tag: void,
    keyword: Keyword,
    identifier: []const u8,
    dot: void,
    int: i32,
    float: f32,
    string: []const u8,
    logical_op: LogicalOp,

    const Keyword = enum {
        empty,
        true,
        false,
        @"if",
        elsif,
        @"else",
        endif,
        unless,
        endunless,
        @"for",
        in,
        endfor,
    };

    const LogicalOp = enum {
        equal,
        greater_than,
        less_than,
        greater_than_or_equal,
        less_than_or_equal,
    };

    pub fn debug(self: Token) void {
        switch (self) {
            .literal => |s| std.log.debug("\"{s}\"", .{s}),
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

fn isIdentStart(char: u8) bool {
    return char == '_' or isAlpha(char);
}

fn isIdent(char: u8) bool {
    return char == '_' or isAlphaNumeric(char);
}

fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\n' or char == '\t';
}
