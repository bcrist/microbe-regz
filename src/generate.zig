//! Code generation and associated tests
const std = @import("std");
const Database = @import("Database.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");
const DataType = @import("DataType.zig");
const log = std.log.scoped(.microbe_regz);

pub fn writeRegTypes(db: Database, writer: anytype) !void {
    try writer.writeAll(
        \\// Generated by https://github.com/bcrist/microbe-regz
        \\const chip = @import("chip");
        \\const Mmio = @import("microbe").Mmio;
        \\
        \\pub const Exception = enum(u9) {
        \\    none = 0,
        \\    Reset = 1,
        \\
    );

    for (db.interrupts.items) |interrupt| {
        try writeComment(interrupt.description, writer);

        try writer.print("{s} = {},\n", .{
            std.zig.fmtId(interrupt.name),
            interrupt.index + 16,
        });

        if (interrupt.description.len > 0) try writer.writeByte('\n');
    }

    try writer.writeAll(
        \\
        \\    pub fn toInterrupt(self: Exception) ?Interrupt {
        \\        const num = @intFromEnum(self);
        \\        if (num < 16 or num >= 48) return null;
        \\        const irq: u5 = @intCast(num - 16);
        \\        return @enumFromInt(irq);
        \\    }
        \\};
        \\
        \\pub const Interrupt = enum(u5) {
        \\
    );

    for (db.interrupts.items) |interrupt| {
        if (interrupt.index >= 0) {
            try writer.print("{s} = {},\n", .{
                std.zig.fmtId(interrupt.name),
                interrupt.index,
            });
        }
    }

    try writer.writeAll(
        \\
        \\    pub fn toException(self: Interrupt) Exception {
        \\        const num: u9 = @intFromEnum(self);
        \\        return @enumFromInt(num + 16);
        \\    }
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

        try writer.print("{s}: Handler = unhandled(.{s}),\n", .{
            std.zig.fmtId(interrupt.name),
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
        if (data_type.shouldInline()) continue;

        try writer.writeByte('\n');
        try writeComment(data_type.description, writer);
        try writer.print("pub const {s} = ", .{
            std.zig.fmtId(data_type.zigName()),
        });

        try writeDataTypeImpl(group, data_type, "", import_prefix, writer);
        try writer.writeAll(";\n");
    }
}

fn writeDataTypeRef(group: PeripheralGroup, data_type: DataType, reg_types_prefix: []const u8, import_prefix: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    if (data_type.shouldInline()) {
        try writeDataTypeImpl(group, data_type, reg_types_prefix, import_prefix, writer);
    } else {
        try writer.print("{s}{s}", .{ reg_types_prefix, std.zig.fmtId(data_type.zigName()) });
    }
}

fn writeDataTypeImpl(group: PeripheralGroup, data_type: DataType, reg_types_prefix: []const u8, import_prefix: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    switch (data_type.kind) {
        .unsigned => try writer.print("u{}", .{ data_type.size_bits }),
        .signed => try writer.print("i{}", .{ data_type.size_bits }),
        .boolean => try writer.writeAll("bool"),
        .anyopaque => try writer.writeAll("anyopaque"),
        .external => |info| {
            var prefix = import_prefix;
            if (!std.mem.endsWith(u8, info.import, ".zig")) {
                prefix = "";
            }
            try writer.print("@import(\"{s}{s}\")", .{
                std.fmt.fmtSliceEscapeUpper(prefix),
                std.fmt.fmtSliceEscapeUpper(info.import),
            });
            var iter = std.mem.tokenizeScalar(u8, data_type.zigName(), '.');
            while (iter.next()) |tok| {
                try writer.print(".{s}", .{ std.zig.fmtId(tok) });
            }
        },
        .pointer => |info| {
            try writer.writeByte('*');
            if (info.allow_zero) {
                try writer.writeAll("allowzero ");
            }
            if (info.constant) {
                try writer.writeAll("const ");
            }
            try writeDataTypeRef(group, group.data_types.items[info.data_type], reg_types_prefix, import_prefix, writer);
        },
        .register => |info| {
             try writer.writeAll("Mmio(");
             try writeDataTypeRef(group, group.data_types.items[info.data_type], reg_types_prefix, import_prefix, writer);
             try writer.print(", .{s})", .{ @tagName(info.access) });
        },
        .collection => |info| {
            try writer.print("[{}]", .{ info.count });
            try writeDataTypeRef(group, group.data_types.items[info.data_type], reg_types_prefix, import_prefix, writer);
        },
        .alternative => |fields| {
            try writer.writeAll("extern union {\n");
            for (fields) |field| {
                try writeComment(field.description, writer);
                try writer.print("{s}: ", .{ std.zig.fmtId(field.name) });
                try writeDataTypeRef(group, group.data_types.items[field.data_type], reg_types_prefix, import_prefix, writer);
                try writer.writeAll(",\n");
                if (field.description.len > 0) try writer.writeByte('\n');
            }
            try writer.writeAll("}");
        },
        .structure => |fields| {
            try writer.writeAll("extern struct {\n");
            var offset_bytes: u32 = 0;
            for (fields) |field| {
                if (offset_bytes < field.offset_bytes) {
                    try writer.print("_reserved_{x}: [{}]u8 = undefined,\n", .{
                        offset_bytes,
                        field.offset_bytes - offset_bytes,
                    });
                    offset_bytes = field.offset_bytes;
                }
                try writeComment(field.description, writer);
                try writer.print("{s}: ", .{ std.zig.fmtId(field.name) });
                const field_data_type = group.data_types.items[field.data_type];
                try writeDataTypeRef(group, field_data_type, reg_types_prefix, import_prefix, writer);
                try writeDataTypeAssign(group, field_data_type, reg_types_prefix, import_prefix, field.default_value, writer);
                try writer.writeAll(",\n");
                if (field.description.len > 0) try writer.writeByte('\n');
                offset_bytes += (field_data_type.size_bits + 7) / 8;
            }
            if (offset_bytes < (data_type.size_bits + 7) / 8) {
                try writer.print("_reserved_{x}: [{}]u8 = undefined,\n", .{
                    offset_bytes,
                    (data_type.size_bits + 7) / 8 - offset_bytes,
                });
            }
            try writer.writeAll("}");
        },
        .bitpack => |fields| {
            try writer.print("packed struct (u{}) {{\n", .{ data_type.size_bits });
            var offset_bits: u32 = 0;
            for (fields) |field| {
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
                try writeDataTypeRef(group, field_data_type, reg_types_prefix, import_prefix, writer);
                try writeDataTypeAssign(group, field_data_type, reg_types_prefix, import_prefix, field.default_value, writer);
                try writer.writeAll(",\n");
                if (field.description.len > 0) try writer.writeByte('\n');
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
        .enumeration => |fields| {
            try writer.print("enum (u{}) {{\n", .{ data_type.size_bits });
            var num_fields: usize = 0;
            for (fields) |field| {
                num_fields += 1;
                try writeComment(field.description, writer);
                try writer.print("{s} = ", .{
                    std.zig.fmtId(field.name),
                });
                if (data_type.size_bits > 4) {
                    try writer.print("0x{X},\n", .{ field.value });
                } else {
                    try writer.print("{},\n", .{ field.value });
                }
                if (field.description.len > 0) try writer.writeByte('\n');
            }
            if (num_fields < (@as(u64, 1) << @intCast(data_type.size_bits))) {
                try writer.writeAll("_,\n");
            }
            try writer.writeAll("}");
        },
    }
}

fn writeDataTypeAssign(group: PeripheralGroup, data_type: DataType, reg_types_prefix: []const u8, import_prefix: []const u8, value: u64, writer: anytype) !void {
    switch (data_type.kind) {
        .unsigned => {
            if (value > 9) {
                try writer.print(" = 0x{X}", .{ value });
            } else {
                try writer.print(" = {}", .{ value });
            }
        },
        .signed => {
            try writer.print(" = {}", .{ value });
        },
        .boolean => {
            try writer.writeAll(if (value == 0) " = false" else " = true");
        },
        .enumeration => |fields| {
            for (fields) |field| {
                if (field.value == value) {
                    try writer.print(" = .{s}", .{ std.zig.fmtId(field.name) });
                    break;
                }
            } else try writer.print(" = @enumFromInt({})", .{ value });
        },
        .pointer => {
            try writer.writeAll(" = @ptrFromInt(");
            if (value > 9) {
                try writer.print("0x{X}", .{ value });
            } else {
                try writer.print("{}", .{ value });
            }
            try writer.writeByte(')');
        },
        .bitpack => {
            try writer.writeAll(" = @bitCast(");
            if (value > 9) {
                try writer.print("0x{X}", .{ value });
            } else {
                try writer.print("{}", .{ value });
            }
            try writer.writeByte(')');
        },
        .external => |info| {
            if (info.from_int) |from_int| {
                try writer.writeAll(" = ");
                if (std.mem.startsWith(u8, from_int, ".")) {
                    try writeDataTypeRef(group, data_type, reg_types_prefix, import_prefix, writer);
                }
                try writer.writeAll(from_int);
            } else {
                try writer.writeAll(" = @import(\"chip_util\").fromInt(");
                try writeDataTypeRef(group, data_type, reg_types_prefix, import_prefix, writer);
                try writer.writeAll(", ");
            }
            if (value > 9) {
                try writer.print("0x{X}", .{ value });
            } else {
                try writer.print("{}", .{ value });
            }
            try writer.writeByte(')');
        },
        .register, .collection, .alternative, .structure, .anyopaque => {},
    }
}

pub fn writePeripheralInstances(db: Database, writer: anytype) !void {
    try writer.writeAll(
        \\// Generated by https://github.com/bcrist/microbe-regz
        \\const types = @import("reg_types.zig");
        \\
        \\
    );

    for (db.groups.items) |group| {
        var types_prefix: []const u8 = undefined;
        if (group.name.len > 0) {
            types_prefix = try std.fmt.allocPrint(db.gpa, "types.{s}.", .{ std.zig.fmtId(group.name) });
        } else {
            types_prefix = try db.gpa.dupe(u8, "types.");
        }
        defer db.gpa.free(types_prefix);

        for (group.peripherals.items) |peripheral| {
            if (peripheral.deleted) continue;

            try writeComment(peripheral.description, writer);
            try writer.print("pub const {s}: *volatile ", .{ std.zig.fmtId(peripheral.name) });
            try writeDataTypeRef(group, group.data_types.items[peripheral.data_type], types_prefix, "reg_types/", writer);
            try writer.print(" = @ptrFromInt(0x{X});\n", .{ peripheral.base_address });
        }
    }
}

pub fn writeComment(comment: []const u8, writer: anytype) !void {
    if (comment.len == 0) return;

    try writer.writeByte('\n');
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
