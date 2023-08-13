//! Code generation and associated tests
const std = @import("std");
const Database = @import("Database.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");
const DataType = @import("DataType.zig");
const log = std.log.scoped(.microbe_regz);

pub fn writeRegTypes(db: Database, writer: anytype) !void {
    try writer.writeAll(
        \\const chip = @import("chip");
        \\const Mmio = @import("microbe").Mmio;
        \\
        \\pub const InterruptType = enum(i8) {
        \\
    );

    for (db.interrupts.items) |interrupt| {
        try writeComment(interrupt.description, writer);

        try writer.print("{s} = {},\n", .{
            std.zig.fmtId(interrupt.name),
            interrupt.index,
        });
    }

    try writer.writeAll(
        \\};
        \\
        \\pub const VectorTable = extern struct {
        \\    const Handler = chip.interrupts.Handler;
        \\    const unhandled = chip.interrupts.unhandled;
        \\
        \\    initial_stack_pointer: *const fn () callconv(.C) void,
        \\    Reset: Handler,
        \\
    );

    var index: i32 = -14;
    for (db.interrupts.items) |interrupt| {
        while (index < interrupt.index) : (index += 1) {
            try writer.print("_reserved_{x}: u32 = 0,\n", .{ (index + 16) * 4 });
        }

        if (index > interrupt.index) {
            log.warn("skipping interrupt: {s}", .{ interrupt.name });
            continue;
        }

        try writer.print("{s}: Handler = unhandled,\n", .{
            std.zig.fmtId(interrupt.name),
        });

        index += 1;
    }

    try writer.writeAll("};\n");

    for (db.groups.items) |group| {
        try writer.writeByte('\n');
        try writeComment(group.description, writer);
        if (group.name.len == 0) {
            try writePeripheralGroupTypes(group, writer, "reg_types/");
        } else if (group.separate_file) {
            try writer.print("pub const {s} = @import(\"reg_types/{s}.zig\");\n", .{
                std.zig.fmtId(group.name),
                std.fmt.fmtSliceEscapeUpper(group.name),
            });
        } else {
            try writer.print("pub const {s} = struct {{\n", .{
                std.zig.fmtId(group.name),
            });
            try writePeripheralGroupTypes(group, writer, "reg_types/");
            try writer.writeAll("};\n");
        }
    }
}

pub fn writePeripheralGroupTypes(group: PeripheralGroup, writer: anytype, import_prefix: []const u8) !void {
    for (group.data_types.items) |data_type| {
        if (data_type.ref_count <= 1 or data_type.name.len == 0) continue;

        try writer.writeByte('\n');
        try writeComment(data_type.description, writer);
        try writer.print("pub const {s} = ", .{
            std.zig.fmtId(data_type.name),
        });

        try writeDataTypeImpl(group, data_type, import_prefix, writer);
        try writer.writeAll(";\n");
    }

    for (group.peripheral_types.items) |peripheral_type| {
        if (peripheral_type.ref_count == 0) continue;

        try writer.writeByte('\n');
        try writeComment(peripheral_type.description, writer);
        try writer.print("pub const {s} = extern struct {{\n", .{
            std.zig.fmtId(peripheral_type.name),
        });

        var offset_bytes: u32 = 0;
        for (peripheral_type.registers.items) |register| {
            if (register.offset_bytes > offset_bytes) {
                try writer.print("_reserved_{x}: [{}]u8 = undefined,\n", .{
                    offset_bytes,
                    register.offset_bytes - offset_bytes,
                });
                offset_bytes = register.offset_bytes;
            }

            try writeComment(register.description, writer);
            try writer.print("{s}: Mmio(", .{ std.zig.fmtId(register.name) });

            const data_type = group.data_types.items[register.data_type];
            try writeDataTypeRef(group, data_type, import_prefix, writer);
            try writer.writeAll(switch (register.access) {
                .@"read-write" => ", .rw),\n",
                .@"read-only" => ", .r),\n",
                .@"write-only" => ", .w),\n",
            });

            offset_bytes += (data_type.size_bits + 7) / 8;
        }

        try writer.writeAll("};\n");
    }
}

fn writeDataTypeRef(group: PeripheralGroup, data_type: DataType, import_prefix: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    if (data_type.name.len > 0 and data_type.ref_count > 1) {
        try writer.print("{s}", .{ std.zig.fmtId(data_type.name) });
    } else {
        try writeDataTypeImpl(group, data_type, import_prefix, writer);
    }
}

fn writeDataTypeImpl(group: PeripheralGroup, data_type: DataType, import_prefix: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    switch (data_type.kind) {
        .unsigned => try writer.print("u{}", .{ data_type.size_bits }),
        .@"array" => |array_info| {
            try writer.print("[{}]", .{ array_info.count });
            try writeDataTypeRef(group, group.data_types.items[array_info.data_type], import_prefix, writer);
        },
        .@"packed" => |fields| {
            try writer.print("packed struct (u{}) {{\n", .{ data_type.size_bits });
            var offset_bits: u32 = 0;
            for (fields.items) |field| {
                if (field.deleted) continue;

                if (offset_bits < field.offset_bits) {
                    try writer.print("_reserved_{x}: u{} = 0,\n", .{
                        offset_bits,
                        field.offset_bits - offset_bits,
                    });
                    offset_bits = field.offset_bits;
                }
                try writeComment(field.description, writer);
                try writer.print("{s}: ", .{ std.zig.fmtId(field.name) });
                const field_data_type = group.data_types.items[field.data_type];
                try writeDataTypeRef(group, field_data_type, import_prefix, writer);
                try writer.writeAll(" = ");
                try writeDataTypeValue(field_data_type, field.default_value, writer);
                try writer.writeAll(",\n");
                offset_bits += field_data_type.size_bits;
            }
            if (offset_bits < data_type.size_bits) {
                try writer.print("_reserved_{x}: u{} = 0,\n", .{
                    offset_bits,
                    data_type.size_bits - offset_bits,
                });
            }
            try writer.writeAll("}");
        },
        .@"enum" => |fields| {
            try writer.print("enum (u{}) {{\n", .{ data_type.size_bits });
            var num_fields: usize = 0;
            for (fields.items) |field| {
                if (field.deleted) continue;

                num_fields += 1;
                try writeComment(field.description, writer);
                try writer.print("{s} = 0x{X},\n", .{
                    std.zig.fmtId(field.name),
                    field.value,
                });
            }
            if (num_fields < (@as(u64, 1) << @intCast(data_type.size_bits))) {
                try writer.writeAll("_,\n");
            }
            try writer.writeAll("}");
        },
        .external => |import| {
            try writer.print("@import(\"{s}{s}\").{s}", .{
                std.fmt.fmtSliceEscapeUpper(import_prefix),
                std.fmt.fmtSliceEscapeUpper(import),
                std.zig.fmtId(data_type.name),
            });
        },
    }
}

fn writeDataTypeValue(data_type: DataType, value: u64, writer: anytype) !void {
    switch (data_type.kind) {
        .unsigned => {
            if (value > 9) {
                try writer.print("0x{X}", .{ value });
            } else {
                try writer.print("{}", .{ value });
            }
        },
        .@"enum" => |fields| {
            for (fields.items) |field| {
                if (field.value == value) {
                    try writer.print(".{s}", .{ std.zig.fmtId(field.name) });
                    break;
                }
            } else try writer.print("@enumFromInt({})", .{ value });
        },
        else => {
            try writer.print("@bitCast(0x{X})", .{ value });
        },
    }
}

pub fn writePeripheralInstances(db: Database, writer: anytype) !void {
    try writer.writeAll("const types = @import(\"reg_types.zig\");\n\n");

    for (db.groups.items) |group| {
        for (group.peripherals.items) |peripheral| {
            if (peripheral.deleted) continue;

            var buf: [32]u8 = undefined;
            const array_count = if (peripheral.count > 1) try std.fmt.bufPrint(&buf, "[{}]", .{ peripheral.count }) else "";

            try writeComment(peripheral.description, writer);
            try writer.print("pub const {s} = @as(*volatile {s}types.", .{
                std.zig.fmtId(peripheral.name),
                array_count,
            });

            if (group.name.len > 0) {
                try writer.print("{s}.", .{ std.zig.fmtId(group.name) });
            }

            const peripheral_type = group.peripheral_types.items[peripheral.peripheral_type];

            try writer.print("{s}, @ptrFromInt(0x{X}));\n", .{
                std.zig.fmtId(peripheral_type.name),
                peripheral.offset_bytes,
            });
        }
    }
}

pub fn writeComment(comment: []const u8, writer: anytype) !void {
    if (comment.len == 0) return;

    // try writer.writeByte('\n');
    var lf_it = std.mem.tokenizeSequence(u8, comment, "\\n");
    while (lf_it.next()) |line| {
        try writer.writeAll("/// ");

        var first_token = true;
        var tok_it = std.mem.tokenizeAny(u8, line, "\n\r \t");
        while (tok_it.next()) |token| {
            if (first_token) first_token = false else try writer.writeByte(' ');
            try writer.writeAll(token);
        }

        try writer.writeByte('\n');
    }
}
