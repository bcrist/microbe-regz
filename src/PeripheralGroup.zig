const std = @import("std");
const Database = @import("Database.zig");
const DataType = @import("DataType.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralType = @import("PeripheralType.zig");
const Register = @import("Register.zig");
const PeripheralGroup = @This();

name: []const u8,
description: []const u8 = "",
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

pub fn lessThan(_: void, a: PeripheralGroup, b: PeripheralGroup) bool {
    return std.mem.lessThan(u8, a.name, b.name);
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


const DedupDataTypeContext = struct {
    group: *PeripheralGroup,

    pub fn hash(ctx: DedupDataTypeContext, a: DataType) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(a.name);
        h.update(a.description);
        h.update(std.mem.asBytes(&a.size_bits));

        const tag = std.meta.activeTag(a.kind);
        h.update(std.mem.asBytes(&tag));

        switch (a.kind) {
            .unsigned => {},
            .@"array" => |info| {
                h.update(std.mem.asBytes(&info.count));
                const dt_hash = ctx.hash(ctx.group.data_types.items[info.data_type]);
                h.update(std.mem.asBytes(&dt_hash));
            },
            .@"packed" => |fields| for (fields.items) |f| {
                if (f.deleted) continue;
                h.update(f.name);
                h.update(f.description);
                h.update(std.mem.asBytes(&f.offset_bits));
                h.update(std.mem.asBytes(&f.default_value));
                const dt_hash = ctx.hash(ctx.group.data_types.items[f.data_type]);
                h.update(std.mem.asBytes(&dt_hash));
            },
            .@"enum" => |fields| for (fields.items) |f| {
                if (f.deleted) continue;
                h.update(f.name);
                h.update(f.description);
                h.update(std.mem.asBytes(&f.value));
            },
            .external => |import| h.update(import),
        }

        return h.final();
    }
    pub fn eql(ctx: DedupDataTypeContext, a: DataType, b: DataType) bool {
        if (a.size_bits != b.size_bits) return false;
        if (!std.mem.eql(u8, a.name, b.name)) return false;
        if (!std.mem.eql(u8, a.description, b.description)) return false;

        if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
        switch (a.kind) {
            .unsigned => {},
            .@"array" => |a_info| {
                const b_info = b.kind.@"array";
                if (a_info.count != b_info.count) return false;

                const at = ctx.group.data_types.items[a_info.data_type];
                const bt = ctx.group.data_types.items[b_info.data_type];
                if (!ctx.eql(at, bt)) return false;
            },
            .@"packed" => |fields_list| {
                const a_fields = fields_list.items;
                const b_fields = b.kind.@"packed".items;

                var ai: usize = 0;
                var bi: usize = 0;
                outer: while (ai < a_fields.len and bi < b_fields.len) {
                    while (a_fields[ai].deleted) {
                        ai += 1;
                        if (ai >= a_fields.len) break :outer;
                    }
                    while (b_fields[bi].deleted) {
                        bi += 1;
                        if (bi >= b_fields.len) break :outer;
                    }

                    const af = a_fields[ai];
                    const bf = b_fields[bi];

                    if (af.offset_bits != bf.offset_bits) return false;
                    if (af.default_value != bf.default_value) return false;
                    if (!std.mem.eql(u8, af.name, bf.name)) return false;
                    if (!std.mem.eql(u8, af.description, bf.description)) return false;

                    const at = ctx.group.data_types.items[af.data_type];
                    const bt = ctx.group.data_types.items[bf.data_type];
                    if (!ctx.eql(at, bt)) return false;

                    ai += 1;
                    bi += 1;
                }
                if (ai != a_fields.len or bi != b_fields.len) return false;
            },
            .@"enum" => |fields_list| {
                const a_fields = fields_list.items;
                const b_fields = b.kind.@"enum".items;

                var ai: usize = 0;
                var bi: usize = 0;
                outer: while (ai < a_fields.len and bi < b_fields.len) {
                    while (a_fields[ai].deleted) {
                        ai += 1;
                        if (ai >= a_fields.len) break :outer;
                    }
                    while (b_fields[bi].deleted) {
                        bi += 1;
                        if (bi >= b_fields.len) break :outer;
                    }

                    const af = a_fields[ai];
                    const bf = b_fields[bi];

                    if (af.value != bf.value) return false;
                    if (!std.mem.eql(u8, af.name, bf.name)) return false;
                    if (!std.mem.eql(u8, af.description, bf.description)) return false;

                    ai += 1;
                    bi += 1;
                }
                if (ai != a_fields.len or bi != b_fields.len) return false;
            },
            .external => |a_import| {
                const b_import = b.kind.external;
                if (!std.mem.eql(u8, a_import, b_import)) return false;
            },
        }
        return true;
    }
};

const DedupPeripheralTypeContext = struct {
    pub fn hash(_: DedupPeripheralTypeContext, a: PeripheralType) u64 {
        var h = std.hash.Wyhash.init(0);
        // h.update(a.name);
        // h.update(a.description);

        for (a.registers.items) |reg| {
            h.update(reg.name);
            h.update(reg.description);
            h.update(std.mem.asBytes(&reg.offset_bytes));
            h.update(std.mem.asBytes(&reg.reset_value));
            h.update(std.mem.asBytes(&reg.reset_mask));
            h.update(std.mem.asBytes(&reg.access));

            // Data types will be deduped before peripheral types, so we don't need to recurse through the type definition
            h.update(std.mem.asBytes(&reg.data_type));
        }

        return h.final();
    }
    pub fn eql(_: DedupPeripheralTypeContext, a: PeripheralType, b: PeripheralType) bool {
        // if (!std.mem.eql(u8, a.name, b.name)) return false;
        // if (!std.mem.eql(u8, a.description, b.description)) return false;

        if (a.registers.items.len != b.registers.items.len) return false;
        for (a.registers.items, b.registers.items) |ar, br| {
            if (ar.offset_bytes != br.offset_bytes) return false;
            if (ar.data_type != br.data_type) return false;
            if (ar.reset_value != br.reset_value) return false;
            if (ar.reset_mask != br.reset_mask) return false;
            if (ar.access != br.access) return false;
            if (!std.mem.eql(u8, ar.name, br.name)) return false;
            if (!std.mem.eql(u8, ar.description, br.description)) return false;
        }
        return true;
    }
};

pub fn dedup(self: *PeripheralGroup, db: Database) !void {
    std.log.debug("Deduplicating peripheral group {s}", .{ self.name });

    var data_types = std.HashMap(DataType, DataType.ID, DedupDataTypeContext, std.hash_map.default_max_load_percentage).initContext(db.gpa, .{ .group = self });
    defer data_types.deinit();

    var data_types_remap = std.AutoHashMap(DataType.ID, DataType.ID).init(db.gpa);
    defer data_types_remap.deinit();

    for (self.data_types.items, 0..) |data_type, id_usize| {
        const id: DataType.ID = @intCast(id_usize);

        var result = try data_types.getOrPut(data_type);
        if (result.found_existing) {
            try data_types_remap.put(id, result.value_ptr.*);
        } else {
            result.value_ptr.* = id;
        }
    }

    for (self.data_types.items, 0..) |data_type, id_usize| {
        const id: DataType.ID = @intCast(id_usize);
        switch (data_type.kind) {
            .@"array" => |info| {
                if (data_types_remap.get(info.data_type)) |dt| {
                    std.log.debug("Deduplicating array data type {} -> {}", .{ info.data_type, dt });
                    self.data_types.items[id].kind.@"array".data_type = dt;
                }
            },
            .@"packed" => for (self.data_types.items[id].kind.@"packed".items) |*field| {
                if (data_types_remap.get(field.data_type)) |dt| {
                    std.log.debug("Deduplicating packed field type {} -> {}", .{ field.data_type, dt });
                    field.data_type = dt;
                }
            },
            else => {},
        }
    }

    var peripheral_types = std.HashMap(PeripheralType, PeripheralType.ID, DedupPeripheralTypeContext, std.hash_map.default_max_load_percentage).init(db.gpa);
    defer peripheral_types.deinit();

    var peripheral_types_remap = std.AutoHashMap(PeripheralType.ID, PeripheralType.ID).init(db.gpa);
    defer peripheral_types_remap.deinit();

    for (self.peripheral_types.items, 0..) |peripheral_type, id_usize| {
        const id: PeripheralType.ID = @intCast(id_usize);

        for (peripheral_type.registers.items) |*register| {
            if (data_types_remap.get(register.data_type)) |dt| {
                std.log.debug("Deduplicating register type {} -> {}", .{ register.data_type, dt });
                register.data_type = dt;
            }
        }

        var result = try peripheral_types.getOrPut(peripheral_type);
        if (result.found_existing) {
            try peripheral_types_remap.put(id, result.value_ptr.*);
        } else {
            result.value_ptr.* = id;
        }
    }

    for (self.peripherals.items) |*peripheral| {
        if (peripheral_types_remap.get(peripheral.peripheral_type)) |pt| {
            peripheral.peripheral_type = pt;
        }
    }
}

pub fn debug(self: PeripheralGroup) void {
    const prefix = if (self.separate_file) "(separate file) " else "";
    std.log.debug("Peripheral Group: {s}{s} - {s}", .{ prefix, self.name, self.description });

    // for (self.data_types.items, 0..) |dt, id| {
    //     dt.debug(@intCast(id), self.name);
    // }

    for (self.peripherals.items) |peripheral| {
        const peripheral_type = self.peripheral_types.items[peripheral.peripheral_type];

        std.log.debug("{s}.{s} ({})", .{ self.name, peripheral.name, peripheral.peripheral_type });

        for (peripheral_type.registers.items) |register| {

            const data_type = self.data_types.items[register.data_type];
            if (data_type.name.len == 0) {
                std.log.debug("{s}.{s}.{s}: {s} {} ({})", .{
                    self.name,
                    peripheral.name,
                    register.name,
                    @tagName(data_type.kind),
                    data_type.size_bits,
                    register.data_type,
                });
            } else {
                std.log.debug("{s}.{s}.{s}: {s} ({})", .{
                    self.name,
                    peripheral.name,
                    register.name,
                    data_type.name,
                    register.data_type,
                });
            }

            switch (data_type.kind) {
                .@"packed" => |fields| for (fields.items) |f| {
                    const field_data_type = self.data_types.items[f.data_type];
                    if (field_data_type.name.len == 0) {
                        std.log.debug("{s}.{s}.{s}.{s}: {s} {} ({})", .{
                            self.name,
                            peripheral.name,
                            register.name,
                            f.name,
                            @tagName(field_data_type.kind),
                            data_type.size_bits,
                            f.data_type,
                        });
                    } else {
                        std.log.debug("{s}.{s}.{s}.{s}: {s} ({})", .{
                            self.name,
                            peripheral.name,
                            register.name,
                            f.name,
                            field_data_type.name,
                            f.data_type,
                        });
                    }
                },
                else => {},
            }

        }

    }

}
