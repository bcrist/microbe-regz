const std = @import("std");
const Database = @import("Database.zig");
const DataType = @import("DataType.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralType = @import("PeripheralType.zig");
const Register = @import("Register.zig");
const PeripheralGroup = @This();

name: []const u8,
description: []const u8,
separate_file: bool = true,
peripherals: std.ArrayListUnmanaged(Peripheral) = .{},
peripheral_types: std.ArrayListUnmanaged(PeripheralType) = .{},
data_types: std.ArrayListUnmanaged(DataType) = .{},

unsigned_types: std.AutoHashMapUnmanaged(u32, DataType.ID) = .{},
array_types: std.AutoHashMapUnmanaged(DataType.ArrayInfo, DataType.ID) = .{},

pub fn deinit(self: *PeripheralGroup, db: Database) void {
    for (self.data_types.items) |*t| {
        switch (t.kind) {
            .@"packed" => |*a| a.deinit(db.gpa),
            .@"enum" => |*a| a.deinit(db.gpa),
            else => {},
        }
    }
    for (self.peripheral_types.items) |*t| {
        t.registers.deinit(db.gpa);
    }
    self.peripherals.deinit(db.gpa);
    self.peripheral_types.deinit(db.gpa);
    self.data_types.deinit(db.gpa);
    self.unsigned_types.deinit(db.gpa);
    self.array_types.deinit(db.gpa);
}

pub fn copyType(
    self: *PeripheralGroup,
    db: Database,
    src_group: PeripheralGroup,
    src_id: DataType.ID,
) !DataType.ID {
    var data_type = src_group.data_types.items[src_id];

    data_type.kind = switch (data_type.kind) {
        .unsigned => blk: {
            if (data_type.name.len == 0 and data_type.description.len == 0) {
                return self.getUnsignedType(db, data_type.size_bits);
            }
            break :blk .unsigned;
        },
        .@"array" => |info| blk: {
            const inner_type = try self.copyType(db, src_group, info.data_type);
            if (data_type.name.len == 0 and data_type.description.len == 0) {
                return self.getArrayType(db, inner_type, info.count);
            }
            break :blk .{ .@"array" = .{
                .count = info.count,
                .data_type = inner_type,
            }};
        },
        .@"packed" => |src_fields| blk: {
            var fields = try std.ArrayList(DataType.PackedField).initCapacity(db.gpa, src_fields.items.len);
            for (src_fields.items) |field| {
                fields.appendAssumeCapacity(.{
                    .name = field.name,
                    .description = field.description,
                    .offset_bits = field.offset_bits,
                    .data_type = try self.copyType(db, src_group, field.data_type),
                    .default_value = field.default_value,
                });
            }
            break :blk .{ .@"packed" = fields.moveToUnmanaged() };
        },
        .@"enum" => |src_fields| blk: {
            var fields = try std.ArrayList(DataType.EnumField).initCapacity(db.gpa, src_fields.items.len);
            for (src_fields.items) |field| {
                fields.appendAssumeCapacity(.{
                    .name = field.name,
                    .description = field.description,
                    .value = field.value,
                });
            }
            break :blk .{ .@"enum" = fields.moveToUnmanaged() };
        },
        .external => |import_name| .{ .external = import_name },
    };

    const id: DataType.ID = @intCast(self.data_types.items.len);
    try self.data_types.append(db.gpa, data_type);
    return id;
}

pub fn copyPeripheral(
    self: *PeripheralGroup,
    db: Database,
    src_group: PeripheralGroup,
    src: Peripheral,
    name: []const u8,
    description: []const u8,
    offset_bytes: u64,
    count: u32,
) !void {
    var peripheral = Peripheral{
        .name = name,
        .description = description,
        .offset_bytes = offset_bytes,
        .count = count,
        .peripheral_type = try self.copyPeripheralType(db, src_group, src.peripheral_type, name),
    };

    try self.peripherals.append(db.gpa, peripheral);
}

pub fn copyPeripheralType(
    self: *PeripheralGroup,
    db: Database,
    src_group: PeripheralGroup,
    src: PeripheralType.ID,
    name: []const u8,
) !PeripheralType.ID {
    const src_type = src_group.peripheral_types.items[src];
    var peripheral_type = PeripheralType{
        .name = name,
        .description = src_type.description,
    };
    for (src_type.registers.items) |register| {
        try peripheral_type.registers.append(db.gpa, .{
            .name = register.name,
            .description = register.description,
            .offset_bytes = register.offset_bytes,
            .reset_value = register.reset_value,
            .reset_mask = register.reset_mask,
            .access = register.access,
            .data_type = try self.copyType(db, src_group, register.data_type),
        });
    }

    const id: PeripheralType.ID = @intCast(self.peripheral_types.items.len);
    try self.peripheral_types.append(db.gpa, peripheral_type);
    return id;
}

pub fn sort(self: *PeripheralGroup) void {
    for (self.data_types.items) |data_type| {
        switch (data_type.kind) {
            .@"packed" => |fields| {
                std.sort.insertion(DataType.PackedField, fields.items, {}, DataType.PackedField.lessThan);
            },
            else => {},
        }
    }

    std.sort.insertion(Peripheral, self.peripherals.items, {}, Peripheral.lessThan);

    for (self.peripheral_types.items) |peripheral_type| {
        std.sort.insertion(Register, peripheral_type.registers.items, {}, Register.lessThan);
    }
}

pub fn computeRefCounts(self: *PeripheralGroup) void {
    // for (self.data_types.items) |*data_type| {
    //     data_type.ref_count = 0;
    // }
    // for (self.peripheral_types.items) |*peripheral_type| {
    //     peripheral_type.ref_count = 0;
    // }
    for (self.peripherals.items) |peripheral| {
        if (peripheral.deleted) continue;

        const type_id = peripheral.peripheral_type;
        const t = self.peripheral_types.items[type_id];
        self.peripheral_types.items[type_id].ref_count = t.ref_count + 1;
        if (t.ref_count == 0) {
            for (t.registers.items) |register| {
                self.addDataTypeRef(register.data_type);
            }
        }
    }
}

fn addDataTypeRef(self: *PeripheralGroup, id: DataType.ID) void {
    const t = self.data_types.items[id];
    self.data_types.items[id].ref_count = t.ref_count + 1;
    if (t.ref_count == 0) {
        switch (t.kind) {
            .unsigned, .@"enum", .external => {},
            .@"array" => |info| {
                self.addDataTypeRef(info.data_type);
            },
            .@"packed" => |fields| {
                for (fields.items) |field| {
                    self.addDataTypeRef(field.data_type);
                }
            },
        }
    }
}

pub fn lessThan(_: void, a: PeripheralGroup, b: PeripheralGroup) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn createEnumType(self: *PeripheralGroup, db: Database, name: []const u8, maybe_desc: ?[]const u8, bits: u32, fields: []const DataType.EnumField) !DataType.ID {
    var fields_list = try std.ArrayListUnmanaged(DataType.EnumField).initCapacity(db.gpa, fields.len);
    fields_list.appendSliceAssumeCapacity(fields);

    const id: DataType.ID = @intCast(self.data_types.items.len);
    try self.data_types.append(db.gpa, .{
        .name = try db.arena.dupe(u8, name),
        .description = if (maybe_desc) |desc| try db.arena.dupe(u8, desc) else "",
        .size_bits = bits,
        .kind = .{ .@"enum" = fields_list },
    });

    return id;
}

pub fn createPackedType(self: *PeripheralGroup, db: Database, name: []const u8, maybe_desc: ?[]const u8, bits: u32, fields: []const DataType.PackedField) !DataType.ID {
    var fields_list = try std.ArrayListUnmanaged(DataType.PackedField).initCapacity(db.gpa, fields.len);
    fields_list.appendSliceAssumeCapacity(fields);

    const id: DataType.ID = @intCast(self.data_types.items.len);
    try self.data_types.append(db.gpa, .{
        .name = try db.arena.dupe(u8, name),
        .description = if (maybe_desc) |desc| try db.arena.dupe(u8, desc) else "",
        .size_bits = bits,
        .kind = .{ .@"packed" = fields_list },
    });

    return id;
}

pub fn findType(self: *PeripheralGroup, db: Database, name: []const u8) !?DataType.ID {
    if (std.mem.startsWith(u8, name, "u")) {
        if (std.fmt.parseInt(u32, name[1..], 10)) |bits| {
            return try self.getUnsignedType(db, bits);
        } else |_| {}
    }

    var result: ?DataType.ID = null;
    for (self.data_types.items, 0..) |dt, id| {
        if (std.mem.eql(u8, dt.name, name)) {
            result = @intCast(id);
        }
    }
    return result;
}

pub fn getUnsignedType(self: *PeripheralGroup, db: Database, width: u32) !DataType.ID {
    if (self.unsigned_types.get(width)) |id| {
        return id;
    } else {
        const id: DataType.ID = @intCast(self.data_types.items.len);
        try self.data_types.append(db.gpa, .{
            .name = "",
            .description = "",
            .size_bits = width,
            .kind = .unsigned,
        });
        try self.unsigned_types.put(db.gpa, width, id);
        return id;
    }
}

pub fn getArrayType(self: *PeripheralGroup, db: Database, data_type: DataType.ID, count: u32) !DataType.ID {
    const info = DataType.ArrayInfo {
        .count = count,
        .data_type = data_type,
    };
    if (self.array_types.get(info)) |id| {
        return id;
    } else {
        const inner = self.data_types.items[data_type];
        const inner_size_bytes = (inner.size_bits + 7) / 8;

        const id: DataType.ID = @intCast(self.data_types.items.len);
        try self.data_types.append(db.gpa, .{
            .name = "",
            .description = "",
            .size_bits = inner_size_bytes * 8 * count,
            .kind = .{ .@"array" = info },
        });
        try self.array_types.put(db.gpa, info, id);
        return id;
    }
}
