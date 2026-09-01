const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const json_path = args[1];

    const specs: json.Array = blk: {
        const json_file = try Io.Dir.cwd().openFile(io, json_path, .{});
        defer json_file.close(io);

        const buf = try arena.alloc(u8, try json_file.length(io));
        _ = try json_file.readPositionalAll(io, buf, 0);

        const parsed = try json.parseFromSliceLeaky(json.Value, arena, buf, .{});
        break :blk parsed.array;
    };

    for (specs.items) |spec_val| {
        const spec = spec_val.object;
        const name = spec.get("name").?.string;
        const template = spec.get("template").?.string;
        const context = spec.get("environment").?.object;
        const expected = spec.get("expected").?.string;

        try testSpec(arena, name, template, context, expected);
    }
}

fn testSpec(
    allocator: Allocator,
    name: []const u8,
    template: []const u8,
    context: json.ObjectMap,
    expected: []const u8,
) !void {
    std.log.debug("SPEC: {s}", .{name});

    const root_node = try @import("./liquid/root.zig").parse(allocator, template);

    const buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);

    var writer = std.Io.Writer.fixed(buf);

    try root_node.render(context, &writer);

    _ = expected;
}
