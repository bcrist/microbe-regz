const std = @import("std");
const Database = @import("Database.zig");
const Register = @import("Register.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralType = @import("PeripheralType.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");
const DataType = @import("DataType.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const json = std.json;
const log = std.log.scoped(.microbe_regz);

pub fn loadDatabase(temp: std.mem.Allocator, db: *Database, text: []const u8, maybe_device_name: ?[]const u8) !void {
    var root = try json.parseFromSliceLeaky(json.Value, temp, text, .{});

    var types_group = PeripheralGroup{
        .name = "",
        .separate_file = false,
    };
    defer types_group.deinit(db.*);

    if (root.object.get("types")) |types_value| {
        const types = try getObject(types_value);
        if (types.get("peripherals")) |peripherals_value| {
            const peripherals = try getObject(peripherals_value);
            for (peripherals.keys(), peripherals.values()) |name, peripheral| {
                try loadPeripheralType(db.*, &types_group, name, try getObject(peripheral));
            }
        }
    }

    var instances_group = try db.getPeripheralGroup(.{
        .name = "",
    });

    if (root.object.get("devices")) |devices_value| {
        const devices = try getObject(devices_value);
        for (devices.keys(), devices.values(), 0..) |name, device_value, i| {
            if (maybe_device_name) |device_name| {
                if (!std.mem.eql(u8, device_name, name)) continue;
            } else if (i != 0) continue;

            const device = try getObject(device_value);
            if (device.get("children")) |children_value| {
                const children = try getObject(children_value);

                if (children.get("interrupts")) |interrupts| {
                    try loadInterrupts(db, try getObject(interrupts));
                }

                if (children.get("peripheral_instances")) |instances| {
                    try loadPeripheralInstances(db.*, types_group, instances_group, try getObject(instances));
                }
            }
        }
    }
}

fn loadPeripheralType(
    db: Database,
    group: *PeripheralGroup,
    name: []const u8,
    peripheral_json: json.ObjectMap,
) !void {
    if (peripheral_json.get("size")) |_| {
        log.warn("Peripheral {s} has unhandled size attribute", .{ name });
    }

    const peripheral_type_id: PeripheralType.ID = @intCast(group.peripheral_types.items.len);
    const peripheral_type = try group.peripheral_types.addOne(db.gpa);
    peripheral_type.* = .{
        .name = try db.arena.dupe(u8, name),
    };

    if (peripheral_json.get("children")) |peripheral_children_value| {
        const peripheral_children = try getObject(peripheral_children_value);

        if (peripheral_children.get("register_groups")) |register_groups_value| {
            const register_groups = try getObject(register_groups_value);
            for (register_groups.values()) |register_group_value| {
                const register_group = try getObject(register_group_value);
                if (register_group.get("children")) |children_value| {
                    const children = try getObject(children_value);
                    if (children.get("registers")) |registers| {
                        try loadRegisters(db, group, peripheral_type, try getObject(registers));
                    }
                }
            }
        }

        if (peripheral_children.get("registers")) |registers| {
            try loadRegisters(db, group, peripheral_type, try getObject(registers));
        }
    }

    try group.peripherals.append(db.gpa, .{
        .name = peripheral_type.name,
        .offset_bytes = 0,
        .count = 0,
        .peripheral_type = peripheral_type_id,
    });
}

fn loadRegisters(
    db: Database,
    group: *PeripheralGroup,
    peripheral_type: *PeripheralType,
    registers: json.ObjectMap,
) !void {
    for (registers.keys(), registers.values()) |name, register_value| {
        const register = try getObject(register_value);
        const size_bits = (try getIntegerFromObject(register, u32, "size")) orelse return error.NoRegisterSize;
        const maybe_count = try getIntegerFromObject(register, u32, "count");
        const maybe_offset = try getIntegerFromObject(register, u32, "offset");
        const maybe_reset_mask = try getIntegerFromObject(register, u64, "reset_mask");
        const maybe_reset_value = try getIntegerFromObject(register, u64, "reset_value");
        const maybe_access_str = try getStringFromObject(register, "access");

        const reset_mask = maybe_reset_mask orelse 0xFFFF_FFFF_FFFF_FFFF;
        const reset_value = maybe_reset_value orelse 0;
        const default_value = reset_mask & reset_value;

        var maybe_data_type: ?DataType.ID = null;
        if (register.get("children")) |children_value| {
            const children = try getObject(children_value);
            if (children.get("fields")) |fields| {
                maybe_data_type = try loadPackedDataType(db, group, size_bits, default_value, try getObject(fields));
            }
        }

        var data_type = maybe_data_type orelse try group.getUnsignedType(db, size_bits);

        if (maybe_count) |count| if (count > 1) {
            data_type = try group.getArrayType(db, data_type, count);
        };

        try peripheral_type.registers.append(db.gpa, .{
            .name = try db.arena.dupe(u8, name),
            .offset_bytes = maybe_offset orelse 0,
            .reset_value = maybe_reset_value orelse 0,
            .reset_mask = maybe_reset_mask orelse 0,
            .data_type = data_type,
            .access = if (maybe_access_str) |str|
                std.meta.stringToEnum(Register.AccessPolicy, str) orelse return error.InvalidAccessPolicy
            else .@"read-write",
        });
    }
}

fn loadPackedDataType(
    db: Database,
    group: *PeripheralGroup,
    register_size_bits: u32,
    register_default_value: u64,
    fields: json.ObjectMap
) !DataType.ID {
    var packed_fields: std.ArrayListUnmanaged(DataType.PackedField) = .{};

    for (fields.keys(), fields.values()) |name, field_value| {
        const field = try getObject(field_value);
        const offset_bits = (try getIntegerFromObject(field, u32, "offset")) orelse 0;
        const size_bits = (try getIntegerFromObject(field, u32, "size")) orelse return error.NoFieldSize;
        if (field.get("count")) |_| {
            return error.FieldArrayUnsupported; // TODO unroll this to individual numbered fields
        }

        if (fields.count() == 1 and offset_bits == 0 and size_bits == register_size_bits) {
            if (field.get("enum")) |enum_value| {
                return loadEnumDataType(db, group, size_bits, try getObject(enum_value));
            } else {
                const id: DataType.ID = @intCast(group.data_types.items.len);
                try group.data_types.append(db.gpa, .{
                    .name = try db.arena.dupe(u8, name),
                    .size_bits = size_bits,
                    .kind = .unsigned,
                });
                return id;
            }
        }

        const data_type = if (field.get("enum")) |enum_value|
            try loadEnumDataType(db, group, size_bits, try getObject(enum_value))
        else try group.getUnsignedType(db, size_bits);

        var default_value: u64 = 0;
        if (offset_bits < 64) {
            default_value = register_default_value >> @intCast(offset_bits);
            if (size_bits < 64) {
                default_value &= (@as(u64, 1) << @intCast(size_bits)) - 1;
            }
        }

        try packed_fields.append(db.gpa, .{
            .name = try db.arena.dupe(u8, name),
            .offset_bits = offset_bits,
            .data_type = data_type,
            .default_value = default_value,
        });
    }

    const type_id: DataType.ID = @intCast(group.data_types.items.len);
    try group.data_types.append(db.gpa, .{
        .name = "",
        .size_bits = register_size_bits,
        .kind = .{ .@"packed" = packed_fields },
    });
    return type_id;
}

fn loadEnumDataType(
    db: Database,
    group: *PeripheralGroup,
    field_size_bits: u32,
    enum_value: std.json.ObjectMap
) !DataType.ID {
    const size_bits = (try getIntegerFromObject(enum_value, u32, "size")) orelse field_size_bits;

    const type_id = try group.createEnumType(db, "", null, size_bits, &.{});
    var enum_fields = &group.data_types.items[type_id].kind.@"enum";

    if (enum_value.get("children")) |children_value| {
        const children = try getObject(children_value);
        if (children.get("enum_fields")) |fields_value| {
            const fields = try getObject(fields_value);
            for (fields.keys(), fields.values(), 0..) |name, enum_field_value, i| {
                _ = i;
                const enum_field = try getObject(enum_field_value);
                const value = (try getIntegerFromObject(enum_field, u32, "value")) orelse return error.NoEnumValue;
                try enum_fields.append(db.gpa, .{
                    .name = try db.arena.dupe(u8, name),
                    .value = value,
                });
            }
        }
    }

    return type_id;
}

fn loadInterrupts(db: *Database, interrupts: json.ObjectMap) !void {
    for (interrupts.keys(), interrupts.values()) |name, interrupt_value| {
        const interrupt = try getObject(interrupt_value);
        const index = (try getIntegerFromObject(interrupt, i32, "index")) orelse return error.MissingInterruptIndex;

        try db.interrupts.append(db.gpa, .{
            .name = try db.arena.dupe(u8, name),
            .index = index,
        });
    }
}

fn loadPeripheralInstances(db: Database, types: PeripheralGroup, group: *PeripheralGroup, instances: std.json.ObjectMap) !void {
    for (instances.keys(), instances.values()) |name, instance_value| {
        const instance = try getObject(instance_value);
        const offset_bytes = try getIntegerFromObject(instance, u32, "offset") orelse 0;
        const count = try getIntegerFromObject(instance, u32, "count") orelse 1;

        const type_ref = (try getStringFromObject(instance, "type")) orelse return error.MissingInstanceType;

        if (std.mem.startsWith(u8, type_ref, "types.peripherals.")) {
            const peripheral_name = type_ref[18..];
            for (types.peripherals.items) |p| {
                if (std.mem.eql(u8, peripheral_name, p.name)) {
                    const safe_name = try db.arena.dupe(u8, name);
                    try group.copyPeripheral(db, types, p, safe_name, "", offset_bytes, count);
                    break;
                }
            } else {
                return error.InvalidInstanceType;
            }
        } else {
            return error.InvalidInstanceType;
        }
    }
}

fn getObject(val: json.Value) !json.ObjectMap {
    return switch (val) {
        .object => |obj| obj,
        else => return error.NotJsonObject,
    };
}

// TODO: handle edge cases
fn getIntegerFromObject(obj: json.ObjectMap, comptime T: type, key: []const u8) !?T {
    return switch (obj.get(key) orelse return null) {
        .integer => |num| @as(T, @intCast(num)),
        else => return error.NotJsonInteger,
    };
}

fn getStringFromObject(obj: json.ObjectMap, key: []const u8) !?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |str| str,
        else => return error.NotJsonString,
    };
}
