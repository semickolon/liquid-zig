const std = @import("std");
const Io = std.Io;

const Yaml = @import("yaml").Yaml;

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    const allocator = init.arena.allocator();

    var yaml = Yaml{ .source = @embedFile("specs/blank-and-empty.yml") };
    defer yaml.deinit(init.gpa);

    try yaml.load(init.gpa);
    std.log.debug("yaml: {d}", .{yaml.docs.items.len});

    const template =
        \\<span>{{message.dog}}</span>
        // \\{% for name in names %}
        // \\    <li>Hello, {{ name }}!</li>
        // \\{% endfor %}
        // \\{% if hello %}
        // \\    <p>{{ hello }}</p>
        // \\{% endif %}
    ;

    const tokens = try lexer.tokenize(template, allocator);
    for (tokens) |tok| {
        tok.debug();
    }

    std.log.debug("---", .{});

    const root_node = try parser.parse(tokens, allocator);

    const json_raw =
        \\{ "message": {"dog":"Hello world!"} }
    ;

    const json: std.json.Value = (try std.json.parseFromSlice(std.json.Value, allocator, json_raw, .{})).value;

    try root_node.render(json.object, stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!
}
