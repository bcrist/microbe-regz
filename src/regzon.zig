pub fn load_database(temp: std.mem.Allocator, db: *Database, text: []const u8, maybe_device_name: ?[]const u8) !void {
    var root = try json.parseFromSliceLeaky(json.Value, temp, text, .{});

    var types_group = Peripheral_Group{
        .arena = db.arena,
        .gpa = db.arena,
        .name = "",
        .separate_file = false,
    };
    defer types_group.deinit();

    if (root.object.get("types")) |types_value| {
        const types = try get_object(types_value);
        if (types.get("peripherals")) |peripherals_value| {
            const peripherals = try get_object(peripherals_value);
            for (peripherals.keys(), peripherals.values()) |name, peripheral| {
                try load_peripheral_type(&types_group, name, try get_object(peripheral));
            }
        }
    }

    const instances_group = try db.find_or_create_peripheral_group("");

    if (root.object.get("devices")) |devices_value| {
        const devices = try get_object(devices_value);
        for (devices.keys(), devices.values(), 0..) |name, device_value, i| {
            if (maybe_device_name) |device_name| {
                if (!std.mem.eql(u8, device_name, name)) continue;
            } else if (i != 0) continue;

            const device = try get_object(device_value);
            if (device.get("children")) |children_value| {
                const children = try get_object(children_value);

                if (children.get("interrupts")) |interrupts| {
                    try load_interrupts(db, try get_object(interrupts));
                }

                if (children.get("peripheral_instances")) |instances| {
                    try load_peripheral_instances(db.*, types_group, instances_group, try get_object(instances));
                }
            }
        }
    }
}

fn load_peripheral_type(
    group: *Peripheral_Group,
    name: []const u8,
    peripheral_json: json.ObjectMap,
) !void {
    if (peripheral_json.get("size")) |_| {
        log.warn("Peripheral {s} has unhandled size attribute", .{ name });
    }

    var fields = std.ArrayList(Data_Type.Struct_Field).init(group.gpa);
    defer fields.deinit();

    if (peripheral_json.get("children")) |peripheral_children_value| {
        const peripheral_children = try get_object(peripheral_children_value);

        if (peripheral_children.get("register_groups")) |register_groups_value| {
            const register_groups = try get_object(register_groups_value);
            for (register_groups.values()) |register_group_value| {
                const register_group = try get_object(register_group_value);
                if (register_group.get("children")) |children_value| {
                    const children = try get_object(children_value);
                    if (children.get("registers")) |registers| {
                        try load_registers(group, &fields, try get_object(registers));
                    }
                }
            }
        }

        if (peripheral_children.get("registers")) |registers| {
            try load_registers(group, &fields, try get_object(registers));
        }
    }

    const type_id = try group.get_or_create_type(.{
        .fallback_name = name,
        .size_bits = 0,
        .kind = .{ .structure = fields.items },
    }, .{});

    _ = try group.create_peripheral(try group.maybe_dupe(name), 0, type_id);
}

const access_map = std.ComptimeStringMap(Data_Type.Access_Policy, .{
    .{ "read-write", .rw },
    .{ "read-only", .r },
    .{ "write-only", .w },
});

fn load_registers(
    group: *Peripheral_Group,
    peripheral_struct_fields: *std.ArrayList(Data_Type.Struct_Field),
    registers: json.ObjectMap,
) !void {
    for (registers.keys(), registers.values()) |name, register_value| {
        const register = try get_object(register_value);
        const size_bits = (try get_integer_from_object(register, u32, "size")) orelse return error.NoRegisterSize;
        const maybe_count = try get_integer_from_object(register, u32, "count");
        const maybe_offset = try get_integer_from_object(register, u32, "offset");
        const maybe_reset_mask = try get_integer_from_object(register, u64, "reset_mask");
        const maybe_reset_value = try get_integer_from_object(register, u64, "reset_value");
        const maybe_access_str = try get_string_from_object(register, "access");

        const reset_mask = maybe_reset_mask orelse 0xFFFF_FFFF_FFFF_FFFF;
        const reset_value = maybe_reset_value orelse 0;
        const default_value = reset_mask & reset_value;

        var access: Data_Type.Access_Policy = .rw;
        if (maybe_access_str) |str| {
            access = access_map.get(str) orelse return error.InvalidAccessType;
        }

        var maybe_data_type: ?Data_Type.ID = null;
        if (register.get("children")) |children_value| {
            const children = try get_object(children_value);
            if (children.get("fields")) |fields| {
                maybe_data_type = try load_packed_data_type(group, name, size_bits, default_value, try get_object(fields));
            }
        }

        var data_type = maybe_data_type orelse try group.get_or_create_unsigned(size_bits);

        data_type = try group.get_or_create_register_type(data_type, access);

        if (maybe_count) |count| if (count > 1) {
            data_type = try group.get_or_create_array_type(data_type, count);
        };

        try peripheral_struct_fields.append(.{
            .name = name,
            .offset_bytes = maybe_offset orelse 0,
            .default_value = default_value,
            .data_type = data_type,
        });
    }
}

fn load_packed_data_type(
    group: *Peripheral_Group,
    register_name: []const u8,
    register_size_bits: u32,
    register_default_value: u64,
    fields: json.ObjectMap
) !Data_Type.ID {
    var packed_fields = std.ArrayList(Data_Type.Packed_Field).init(group.gpa);
    defer packed_fields.deinit();

    for (fields.keys(), fields.values()) |name, field_value| {
        const field = try get_object(field_value);
        const offset_bits = (try get_integer_from_object(field, u32, "offset")) orelse 0;
        const size_bits = (try get_integer_from_object(field, u32, "size")) orelse return error.NoFieldSize;
        if (field.get("count")) |_| {
            return error.FieldArrayUnsupported; // TODO unroll this to individual numbered fields
        }

        if (fields.count() == 1 and offset_bits == 0 and size_bits == register_size_bits) {
            if (field.get("enum")) |enum_value| {
                return load_enum_data_type(group, name, size_bits, try get_object(enum_value));
            } else {
                return try group.get_or_create_unsigned(size_bits);
            }
        }

        const data_type = if (field.get("enum")) |enum_value|
            try load_enum_data_type(group, name, size_bits, try get_object(enum_value))
        else try group.get_or_create_unsigned(size_bits);

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

    return try group.get_or_create_type(.{
        .fallback_name = register_name,
        .size_bits = register_size_bits,
        .kind = .{ .bitpack = packed_fields.items },
    }, .{});
}

fn load_enum_data_type(
    group: *Peripheral_Group,
    field_name: []const u8,
    field_size_bits: u32,
    enum_value: std.json.ObjectMap
) !Data_Type.ID {
    const size_bits = (try get_integer_from_object(enum_value, u32, "size")) orelse field_size_bits;

    var enum_fields = std.ArrayList(Data_Type.Enum_Field).init(group.gpa);
    defer enum_fields.deinit();

    if (enum_value.get("children")) |children_value| {
        const children = try get_object(children_value);
        if (children.get("enum_fields")) |fields_value| {
            const fields = try get_object(fields_value);
            for (fields.keys(), fields.values()) |name, enum_field_value| {
                const enum_field = try get_object(enum_field_value);
                const value = (try get_integer_from_object(enum_field, u32, "value")) orelse return error.NoEnumValue;
                try enum_fields.append(.{
                    .name = name,
                    .value = value,
                });
            }
        }
    }

    return try group.get_or_create_type(.{
        .fallback_name = field_name,
        .size_bits = size_bits,
        .kind = .{ .enumeration = enum_fields.items },
    }, .{});
}

fn load_interrupts(db: *Database, interrupts: json.ObjectMap) !void {
    for (interrupts.keys(), interrupts.values()) |name, interrupt_value| {
        const interrupt = try get_object(interrupt_value);
        const index = (try get_integer_from_object(interrupt, i32, "index")) orelse return error.MissingInterruptIndex;

        try db.interrupts.append(db.gpa, .{
            .name = try db.arena.dupe(u8, name),
            .index = index,
        });
    }
}

fn load_peripheral_instances(db: Database, types: Peripheral_Group, group: *Peripheral_Group, instances: std.json.ObjectMap) !void {
    for (instances.keys(), instances.values()) |name, instance_value| {
        const instance = try get_object(instance_value);
        const offset_bytes = try get_integer_from_object(instance, u32, "offset") orelse 0;
        const count = try get_integer_from_object(instance, u32, "count") orelse 1;

        const type_ref = (try get_string_from_object(instance, "type")) orelse return error.MissingInstanceType;

        if (std.mem.startsWith(u8, type_ref, "types.peripherals.")) {
            const peripheral_name = type_ref[18..];
            for (types.peripherals.items) |p| {
                if (std.mem.eql(u8, peripheral_name, p.name)) {
                    const safe_name = try db.arena.dupe(u8, name);
                    const peripheral = try group.clone_peripheral(&types, p);

                    var dt = group.data_types.items[peripheral.data_type];
                    dt.fallback_name = safe_name;
                    peripheral.data_type = try group.get_or_create_type(dt, .{ .dupe_strings = false });
                    peripheral.name = safe_name;
                    peripheral.base_address = offset_bytes;
                    if (count > 1) {
                        peripheral.data_type = try group.get_or_create_array_type(peripheral.data_type, count);
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

fn get_object(val: json.Value) !json.ObjectMap {
    return switch (val) {
        .object => |obj| obj,
        else => return error.NotJsonObject,
    };
}

// TODO: handle edge cases
fn get_integer_from_object(obj: json.ObjectMap, comptime T: type, key: []const u8) !?T {
    return switch (obj.get(key) orelse return null) {
        .integer => |num| @as(T, @intCast(num)),
        else => return error.NotJsonInteger,
    };
}

fn get_string_from_object(obj: json.ObjectMap, key: []const u8) !?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |str| str,
        else => return error.NotJsonString,
    };
}

const Database = @import("Database.zig");
const Peripheral = @import("Peripheral.zig");
const Peripheral_Group = @import("Peripheral_Group.zig");
const Data_Type = @import("Data_Type.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const json = std.json;
const log = std.log.scoped(.microbe_regz);
const std = @import("std");
