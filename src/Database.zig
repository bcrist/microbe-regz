arena: std.mem.Allocator,
gpa: std.mem.Allocator,
interrupts: std.ArrayListUnmanaged(Interrupt) = .{},
groups: std.ArrayListUnmanaged(Peripheral_Group) = .{},

pub fn find_peripheral_group(self: *Database, name: []const u8) !*Peripheral_Group {
    for (self.groups.items) |*group| {
        if (std.mem.eql(u8, group.name, name)) {
            return group;
        }
    }
    return error.Peripheral_Group_Missing;
}

pub fn find_or_create_peripheral_group(self: *Database, name: []const u8) !*Peripheral_Group {
    for (self.groups.items) |*group| {
        if (std.mem.eql(u8, group.name, name)) {
            return group;
        }
    }
    const group = try self.groups.addOne(self.gpa);
    group.* = .{
        .arena = self.arena,
        .gpa = self.gpa,
        .name = try self.arena.dupe(u8, name),
        .description = "",
        .separate_file = true,
    };
    return group;
}

pub fn create_nvic(self: *Database) !void {
    const group = try self.find_or_create_peripheral_group("cortex");

    var packed_fields = std.ArrayList(Data_Type.Packed_Field).init(self.gpa);
    defer packed_fields.deinit();

    for (self.interrupts.items) |interrupt| {
        if (interrupt.index < 0) continue;
        try packed_fields.append(.{
            .name = interrupt.name,
            .offset_bits = @intCast(interrupt.index),
            .data_type = try group.get_or_create_bool(),
            .default_value = 0,
        });
    }

    const interrupt_bitmap = try group.get_or_create_type(.{
        .name = "Interrupt_Bitmap",
        .size_bits = 32,
        .kind = .{ .bitpack = packed_fields.items },
    }, .{ .dupe_strings = false });

    const interrupt_bitmap_register = try group.get_or_create_register_type(interrupt_bitmap, .rw);
    const u8_type = try group.get_or_create_unsigned(8);

    var ipr_packed_fields = std.ArrayList(Data_Type.Packed_Field).init(self.gpa);
    defer ipr_packed_fields.deinit();

    var ipr: [8]Data_Type.Struct_Field = undefined;
    for (&ipr, 0..) |*reg, n| {
        ipr_packed_fields.clearRetainingCapacity();

        const min_index: u8 = @intCast(n * 4);
        const end_index = min_index + 4;
        for (self.interrupts.items) |interrupt| {
            if (interrupt.index < min_index or interrupt.index >= end_index) continue;
            try ipr_packed_fields.append(.{
                .name = interrupt.name,
                .offset_bits = @intCast((interrupt.index - min_index) * 8),
                .default_value = 0,
                .data_type = u8_type,
            });
        }

        const ipr_packed_type = try group.get_or_create_type(.{
            .size_bits = 32,
            .kind = .{ .bitpack = ipr_packed_fields.items },
        }, .{});

        reg.* = .{
            .name = try std.fmt.allocPrint(self.arena, "interrupt_priority_{}", .{ n }),
            .offset_bytes = @intCast(0x400 + 4 * n),
            .default_value = 0,
            .data_type = try group.get_or_create_register_type(ipr_packed_type, .rw),
        };
    }

    const nvic_data_type = try group.get_or_create_type(.{
        .name = "NVIC",
        .size_bits = 0,
        .kind = .{ .structure = &.{
            .{
                .name = "interrupt_set_enable",
                .description = "a.k.a. ISER",
                .offset_bytes = 0,
                .default_value = 0,
                .data_type = interrupt_bitmap_register,
            },
            .{
                .name = "interrupt_clear_enable",
                .description = "a.k.a. ICER",
                .offset_bytes = 0x80,
                .default_value = 0,
                .data_type = interrupt_bitmap_register,
            },
            .{
                .name = "interrupt_set_pending",
                .description = "a.k.a. ISPR",
                .offset_bytes = 0x100,
                .default_value = 0,
                .data_type = interrupt_bitmap_register,
            },
            .{
                .name = "interrupt_clear_pending",
                .description = "a.k.a. ICPR",
                .offset_bytes = 0x180,
                .default_value = 0,
                .data_type = interrupt_bitmap_register,
            },
            ipr[0],
            ipr[1],
            ipr[2],
            ipr[3],
            ipr[4],
            ipr[5],
            ipr[6],
            ipr[7],
        }},
    }, .{ .dupe_strings = false });

    _ = try group.create_peripheral("NVIC", 0xE000E100, nvic_data_type);
}

pub fn sort(self: *Database) void {
    std.sort.insertion(Interrupt, self.interrupts.items, {}, Interrupt.less_than);
    std.sort.insertion(Peripheral_Group, self.groups.items, {}, Peripheral_Group.less_than);

    for (self.groups.items) |group| {
        std.sort.insertion(Peripheral, group.peripherals.items, {}, Peripheral.less_than);
    }
}

pub fn compute_ref_counts(self: *Database) void {
    for (self.groups.items) |*group| {
        group.compute_ref_counts();
    }
}

pub fn assign_names(self: *Database) !void {
    for (self.groups.items) |*group| {
        try group.assign_names();
    }
}

const Database = @This();
const Interrupt = @import("Interrupt.zig");
const Peripheral = @import("Peripheral.zig");
const Peripheral_Group = @import("Peripheral_Group.zig");
const Data_Type = @import("Data_Type.zig");
const std = @import("std");
