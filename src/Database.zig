const std = @import("std");
const Interrupt = @import("Interrupt.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralType = @import("PeripheralType.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");
const Register = @import("Register.zig");
const DataType = @import("DataType.zig");

const Database = @This();

arena: std.mem.Allocator,
gpa: std.mem.Allocator,
interrupts: std.ArrayListUnmanaged(Interrupt) = .{},
groups: std.ArrayListUnmanaged(PeripheralGroup) = .{},

pub fn getPeripheralGroup(self: *Database, group: PeripheralGroup) !*PeripheralGroup {
    for (self.groups.items) |*ptr| {
        if (std.mem.eql(u8, ptr.name, group.name)) {
            return ptr;
        }
    }

    const ptr = try self.groups.addOne(self.gpa);
    ptr.* = .{
        .name = try self.arena.dupe(u8, group.name),
        .description = try self.arena.dupe(u8, group.description),
        .separate_file = group.separate_file,
    };
    return ptr;
}

pub fn findOrCreatePeripheralGroup(self: *Database, name: []const u8) !*PeripheralGroup {
    for (self.groups.items) |*group| {
        if (std.mem.eql(u8, group.name, name)) {
            return group;
        }
    }
    const group = try self.groups.addOne(self.gpa);
    group.* = .{
        .name = try self.arena.dupe(u8, name),
        .description = "",
        .separate_file = true,
    };
    return group;
}

pub fn createNvic(self: *Database) !void {
    const group = try self.findOrCreatePeripheralGroup("cortex");

    const peripheral_type_id: PeripheralType.ID = @intCast(group.peripheral_types.items.len);
    const peripheral_type = try group.peripheral_types.addOne(self.gpa);
    peripheral_type.* = .{
        .name = "NVIC",
        .description = "",
    };

    var packed_fields: std.ArrayListUnmanaged(DataType.PackedField) = .{};
    for (self.interrupts.items) |interrupt| {
        if (interrupt.index < 0) continue;
        try packed_fields.append(self.gpa, .{
            .name = interrupt.name,
            .description = "",
            .offset_bits = @intCast(interrupt.index),
            .data_type = try group.getUnsignedType(self.*, 1),
            .default_value = 0,
        });
    }

    const interrupt_bitmap_type_id: DataType.ID = @intCast(group.data_types.items.len);
    const interrupt_bitmap_type = try group.data_types.addOne(self.gpa);
    interrupt_bitmap_type.* = .{
        .name = "InterruptBitmap",
        .description = "",
        .size_bits = 32,
        .kind = .{ .@"packed" = packed_fields },
    };

    try peripheral_type.registers.append(self.gpa, .{
        .name = "ISER",
        .description = "Interrupt Set Enable Register",
        .offset_bytes = 0,
        .reset_value = 0,
        .reset_mask = 0,
        .data_type = interrupt_bitmap_type_id,
        .access = .@"read-write",
    });
    try peripheral_type.registers.append(self.gpa, .{
        .name = "ICER",
        .description = "Interrupt Clear Enable Register",
        .offset_bytes = 0x80,
        .reset_value = 0,
        .reset_mask = 0,
        .data_type = interrupt_bitmap_type_id,
        .access = .@"read-write",
    });

    try peripheral_type.registers.append(self.gpa, .{
        .name = "ISPR",
        .description = "Interrupt Set Pending Register",
        .offset_bytes = 0x100,
        .reset_value = 0,
        .reset_mask = 0,
        .data_type = interrupt_bitmap_type_id,
        .access = .@"read-write",
    });
    try peripheral_type.registers.append(self.gpa, .{
        .name = "ICPR",
        .description = "Interrupt Clear Pending Register",
        .offset_bytes = 0x180,
        .reset_value = 0,
        .reset_mask = 0,
        .data_type = interrupt_bitmap_type_id,
        .access = .@"read-write",
    });

    for (0..8) |ipr| {
        var ipr_packed_fields: std.ArrayListUnmanaged(DataType.PackedField) = .{};

        const min_index: u8 = @intCast(ipr * 4);
        const end_index = min_index + 4;

        for (self.interrupts.items) |interrupt| {
            if (interrupt.index < min_index or interrupt.index >= end_index) continue;

            try ipr_packed_fields.append(self.gpa, .{
                .name = interrupt.name,
                .description = "",
                .offset_bits = @intCast((interrupt.index - min_index) * 8),
                .data_type = try group.getUnsignedType(self.*, 8),
                .default_value = 0,
            });
        }

        if (ipr_packed_fields.items.len == 0) continue;

        const ipr_type_id: DataType.ID = @intCast(group.data_types.items.len);
        const ipr_type = try group.data_types.addOne(self.gpa);
        ipr_type.* = .{
            .name = try std.fmt.allocPrint(self.arena, "NVIC_IPR{}", .{ ipr }),
            .description = "",
            .size_bits = 32,
            .kind = .{ .@"packed" = ipr_packed_fields },
        };

        try peripheral_type.registers.append(self.gpa, .{
            .name = try std.fmt.allocPrint(self.arena, "IPR{}", .{ ipr }),
            .description = "Interrupt Priority Register",
            .offset_bytes = @intCast(0x400 + 4 * ipr),
            .reset_value = 0,
            .reset_mask = 0,
            .data_type = ipr_type_id,
            .access = .@"read-write",
        });
    }

    try group.peripherals.append(self.gpa, .{
        .name = "NVIC",
        .description = "",
        .offset_bytes = 0xE000E100,
        .count = 1,
        .peripheral_type = peripheral_type_id,
    });
}

pub fn sort(self: *Database) void {
    std.sort.insertion(Interrupt, self.interrupts.items, {}, Interrupt.lessThan);
    std.sort.insertion(PeripheralGroup, self.groups.items, {}, PeripheralGroup.lessThan);

    for (self.groups.items) |*group| {
        group.sort();
    }
}

pub fn computeRefCounts(self: *Database) void {
    for (self.groups.items) |*group| {
        group.computeRefCounts();
    }
}

pub fn dedup(self: *Database) !void {
    for (self.groups.items) |*group| {
        try group.dedup(self.*);
    }
}

pub fn debug(self: Database) void {
    for (self.interrupts.items) |interrupt| {
        std.log.debug("Interrupt {}: {s} - {s}", .{ interrupt.index, interrupt.name, interrupt.description });
    }
    for (self.groups.items) |group| {
        group.debug();
    }
}
