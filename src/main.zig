const std = @import("std");
const sx = @import("sx-reader");
const Database = @import("Database.zig");
const regzon = @import("regzon.zig");
const generate = @import("generate.zig");
const modify = @import("modify.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var db: Database = .{
        .gpa = gpa.allocator(),
        .arena = arena.allocator(),
    };

    {
        var temp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer temp_arena.deinit();

        const json = try std.fs.cwd().readFileAlloc(temp_arena.allocator(), "device.json", 100_000_000);
        try regzon.loadDatabase(temp_arena.allocator(), &db, json, null);

        _ = temp_arena.reset(.retain_capacity);

        var sx_file = try std.fs.cwd().openFile("device.sx", .{});
        defer sx_file.close();
        const file_reader = sx_file.reader();
        var sx_reader = sx.reader(temp_arena.allocator(), file_reader);
        modify.parseAndApplySx(&db, @TypeOf(file_reader), &sx_reader) catch |e| {
            if (e == error.SExpressionSyntaxError) {
                var stderr = std.io.getStdErr().writer();
                try stderr.writeAll("Syntax error in type overrides file:\n");
                var ctx = try sx_reader.getNextTokenContext();
                try ctx.printForFile(&sx_file, stderr, 120);
            }
            return e;
        };
    }

    try db.createNvic();

    // TODO: Consolidate duplicate types
    db.computeRefCounts();
    db.sort();

    var temp = std.ArrayList(u8).init(gpa.allocator());
    try generate.writeRegTypes(db, temp.writer());
    try writeZigFile(gpa.allocator(), "reg_types.zig", &temp);

    try generate.writePeripheralInstances(db, temp.writer());
    try writeZigFile(gpa.allocator(), "peripherals.zig", &temp);

    for (db.groups.items) |group| {
        if (group.separate_file and group.name.len > 0) {
            const filename = try std.fmt.allocPrint(gpa.allocator(), "reg_types/{s}.zig", .{ std.fmt.fmtSliceEscapeUpper(group.name) });
            defer gpa.allocator().free(filename);
            try temp.writer().writeAll(
                \\const Mmio = @import("microbe").Mmio;
                \\
            );
            try generate.writePeripheralGroupTypes(group, temp.writer(), "");
            try writeZigFile(gpa.allocator(), filename, &temp);
        }
    }
}

fn writeZigFile(gpa: std.mem.Allocator, path: []const u8, source: *std.ArrayList(u8)) !void {
    try source.append(0);
    const source_nz = source.items[0 .. source.items.len - 1];
    const source_z: [:0]const u8 = @ptrCast(source_nz);
    var ast = try std.zig.Ast.parse(gpa, source_z, .zig);
    defer ast.deinit(gpa);

    var maybe_text: ?[]const u8 = null;
    defer if (maybe_text) |t| gpa.free(t);

    const text = if(ast.errors.len == 0) try ast.render(gpa) else source_nz;

    var af = try std.fs.cwd().atomicFile(path, .{});
    defer af.deinit();
    try af.file.writer().writeAll(text);
    try af.finish();

    source.clearRetainingCapacity();
}
