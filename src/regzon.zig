const std = @import("std");
const Database = @import("Database.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");
const DataType = @import("DataType.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const json = std.json;
const log = std.log.scoped(.microbe_regz);

pub fn loadDatabase(temp: std.mem.Allocator, db: *Database, text: []const u8, maybe_device_name: ?[]const u8) !void {
    var root = try json.parseFromSliceLeaky(json.Value, temp, text, .{});

    var types_group = PeripheralGroup{
        .arena = db.arena,
        .gpa = db.arena,
        .name = "",
        .separate_file = false,
    };
    defer types_group.deinit();

    if (root.object.get("types")) |types_value| {
        const types = try getObject(types_value);
        if (types.get("peripherals")) |peripherals_value| {
            const peripherals = try getObject(peripherals_value);
            for (peripherals.keys(), peripherals.values()) |name, peripheral| {
                try loadPeripheralType(&types_group, name, try getObject(peripheral));
            }
        }
    }

    var instances_group = try db.findOrCreatePeripheralGroup("");

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
    group: *PeripheralGroup,
    name: []const u8,
    peripheral_json: json.ObjectMap,
) !void {
    if (peripheral_json.get("size")) |_| {
        log.warn("Peripheral {s} has unhandled size attribute", .{ name });
    }

    var fields = std.ArrayList(DataType.StructField).init(group.gpa);
    defer fields.deinit();

    if (peripheral_json.get("children")) |peripheral_children_value| {
        const peripheral_children = try getObject(peripheral_children_value);

        if (peripheral_children.get("register_groups")) |register_groups_value| {
            const register_groups = try getObject(register_groups_value);
            for (register_groups.values()) |register_group_value| {
                const register_group = try getObject(register_group_value);
                if (register_group.get("children")) |children_value| {
                    const children = try getObject(children_value);
                    if (children.get("registers")) |registers| {
                        try loadRegisters(group, &fields, try getObject(registers));
                    }
                }
            }
        }

        if (peripheral_children.get("registers")) |registers| {
            try loadRegisters(group, &fields, try getObject(registers));
        }
    }

    const type_id = try group.getOrCreateType(.{
        .fallback_name = name,
        .size_bits = 0,
        .kind = .{ .structure = fields.items },
    }, .{});

    _ = try group.createPeripheral(try group.maybeDupe(name), 0, type_id);
}

const access_map = std.ComptimeStringMap(DataType.AccessPolicy, .{
    .{ "read-write", .rw },
    .{ "read-only", .r },
    .{ "write-only", .w },
});

fn loadRegisters(
    group: *PeripheralGroup,
    peripheral_struct_fields: *std.ArrayList(DataType.StructField),
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

        var access: DataType.AccessPolicy = .rw;
        if (maybe_access_str) |str| {
            access = access_map.get(str) orelse return error.InvalidAccessType;
        }

        var maybe_data_type: ?DataType.ID = null;
        if (register.get("children")) |children_value| {
            const children = try getObject(children_value);
            if (children.get("fields")) |fields| {
                maybe_data_type = try loadPackedDataType(group, name, size_bits, default_value, try getObject(fields));
            }
        }

        var data_type = maybe_data_type orelse try group.getOrCreateUnsigned(size_bits);

        data_type = try group.getOrCreateRegisterType(data_type, access);

        if (maybe_count) |count| if (count > 1) {
            data_type = try group.getOrCreateArrayType(data_type, count);
        };

        try peripheral_struct_fields.append(.{
            .name = name,
            .offset_bytes = maybe_offset orelse 0,
            .default_value = default_value,
            .data_type = data_type,
        });
    }
}

fn loadPackedDataType(
    group: *PeripheralGroup,
    register_name: []const u8,
    register_size_bits: u32,
    register_default_value: u64,
    fields: json.ObjectMap
) !DataType.ID {
    var packed_fields = std.ArrayList(DataType.PackedField).init(group.gpa);
    defer packed_fields.deinit();

    for (fields.keys(), fields.values()) |name, field_value| {
        const field = try getObject(field_value);
        const offset_bits = (try getIntegerFromObject(field, u32, "offset")) orelse 0;
        const size_bits = (try getIntegerFromObject(field, u32, "size")) orelse return error.NoFieldSize;
        if (field.get("count")) |_| {
            return error.FieldArrayUnsupported; // TODO unroll this to individual numbered fields
        }

        if (fields.count() == 1 and offset_bits == 0 and size_bits == register_size_bits) {
            if (field.get("enum")) |enum_value| {
                return loadEnumDataType(group, name, size_bits, try getObject(enum_value));
            } else {
                return try group.getOrCreateUnsigned(size_bits);
            }
        }

        const data_type = if (field.get("enum")) |enum_value|
            try loadEnumDataType(group, name, size_bits, try getObject(enum_value))
        else try group.getOrCreateUnsigned(size_bits);

        var default_value: u64 = 0;
        if (offset_bits < 64) {
            default_value = register_default_value >> @intCast(offset_bits);
            if (size_bits < 64) {
                default_value &= (@as(u64, 1) << @intCast(size_bits)) - 1;
            }
        }

        try packed_fields.append(.{
            .name = name,
            .offset_bits = offset_bits,
            .data_type = data_type,
            .default_value = default_value,
        });
    }

    return try group.getOrCreateType(.{
        .fallback_name = register_name,
        .size_bits = register_size_bits,
        .kind = .{ .bitpack = packed_fields.items },
    }, .{});
}

fn loadEnumDataType(
    group: *PeripheralGroup,
    field_name: []const u8,
    field_size_bits: u32,
    enum_value: std.json.ObjectMap
) !DataType.ID {
    const size_bits = (try getIntegerFromObject(enum_value, u32, "size")) orelse field_size_bits;

    var enum_fields = std.ArrayList(DataType.EnumField).init(group.gpa);
    defer enum_fields.deinit();

    if (enum_value.get("children")) |children_value| {
        const children = try getObject(children_value);
        if (children.get("enum_fields")) |fields_value| {
            const fields = try getObject(fields_value);
            for (fields.keys(), fields.values()) |name, enum_field_value| {
                const enum_field = try getObject(enum_field_value);
                const value = (try getIntegerFromObject(enum_field, u32, "value")) orelse return error.NoEnumValue;
                try enum_fields.append(.{
                    .name = name,
                    .value = value,
                });
            }
        }
    }

    return try group.getOrCreateType(.{
        .fallback_name = field_name,
        .size_bits = size_bits,
        .kind = .{ .enumeration = enum_fields.items },
    }, .{});
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
                    const peripheral = try group.clonePeripheral(&types, p);

                    var dt = group.data_types.items[peripheral.data_type];
                    dt.fallback_name = safe_name;
                    peripheral.data_type = try group.getOrCreateType(dt, .{ .dupe_strings = false });
                    peripheral.name = safe_name;
                    peripheral.base_address = offset_bytes;
                    if (count > 1) {
                        peripheral.data_type = try group.getOrCreateArrayType(peripheral.data_type, count);
                    }
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
