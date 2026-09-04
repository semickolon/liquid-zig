const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

const liquid = @import("liquid");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena_alloc);
    const json_path = args[1];

    const specs = blk: {
        const json_file = try Io.Dir.cwd().openFile(io, json_path, .{});
        defer json_file.close(io);

        const buf = try arena_alloc.alloc(u8, try json_file.length(io));
        _ = try json_file.readPositionalAll(io, buf, 0);

        const parsed = try json.parseFromSliceLeaky(json.Value, arena_alloc, buf, .{});
        break :blk parsed.array;
    };

    var pass_count: usize = 0;

    var spec_arena = std.heap.ArenaAllocator.init(arena_alloc);
    // defer spec_arena.deinit();
    const spec_alloc = spec_arena.allocator();

    for (specs.items, 0..) |spec_val, i| {
        defer _ = spec_arena.reset(.free_all);

        const spec = spec_val.object;
        const name = spec.get("name").?.string;
        const template = spec.get("template").?.string;
        const expected = spec.get("expected").?.string;

        const json_context = spec.get("environment");
        const context: liquid.Value = if (json_context) |ctx| try .initLeaky(ctx, spec_alloc) else .nil;

        std.log.debug("SPEC: {s} (#{d} / {d})", .{ name, i + 1, specs.items.len });

        const pass = testSpec(spec_alloc, template, context, expected) catch |err| switch (err) {
            error.NotImplemented => {
                // std.log.err("NotImplemented", .{});
                // continue;
                return err;
            },
            else => return err,
        };

        if (pass) {
            pass_count += 1;
        } else {
            return error.TestFail;
        }
    }

    std.log.debug("{d}/{d} tests passed.", .{ pass_count, specs.items.len });
}

fn testSpec(
    scratch: Allocator,
    template: []const u8,
    context: liquid.Value,
    expected: []const u8,
) !bool {
    const buf = try scratch.alloc(u8, 4096);
    var writer = std.Io.Writer.fixed(buf);

    const ast = try liquid.parse(scratch, template);
    try liquid.render(scratch, &writer, ast, context);

    std.log.debug("\tEXPECTED: \"{s}\"", .{expected});
    std.log.debug("\tACTUAL:   \"{s}\"", .{buf[0..writer.end]});

    const pass = std.mem.eql(u8, buf[0..writer.end], expected);

    std.log.debug("{s}", .{if (pass) "PASS" else "FAIL"});
    std.log.debug("------", .{});

    return pass;
}
