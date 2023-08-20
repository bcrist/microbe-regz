const std = @import("std");
const DataType = @import("DataType.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralGroup = @This();

const load_factor = std.hash_map.default_max_load_percentage;

arena: std.mem.Allocator,
gpa: std.mem.Allocator,
name: []const u8,
description: []const u8 = "",
separate_file: bool = true,
peripherals: std.ArrayListUnmanaged(Peripheral) = .{},
data_types: std.ArrayListUnmanaged(DataType) = .{},
data_type_dedup: std.HashMapUnmanaged(DataType, DataType.ID, DataType.DedupContext, load_factor) = .{},
data_type_lookup: std.StringHashMapUnmanaged(DataType.ID) = .{},

pub fn deinit(self: *PeripheralGroup) void {
    self.peripherals.deinit(self.gpa);
    self.data_types.deinit(self.gpa);
    self.data_type_dedup.deinit(self.gpa);
    self.data_type_lookup.deinit(self.gpa);
}

pub fn createPeripheral(
    self: *PeripheralGroup,
    name: []const u8,
    base_address: u64,
    data_type: DataType.ID,
) !*Peripheral {
    try self.peripherals.append(self.gpa, .{
        .name = name,
        .base_address = base_address,
        .data_type = data_type,
    });
    return &self.peripherals.items[self.peripherals.items.len - 1];
}

pub fn clonePeripheral(
    self: *PeripheralGroup,
    src_group: *const PeripheralGroup,
    src: Peripheral,
) !*Peripheral {
    try self.peripherals.append(self.gpa, .{
        .name = src.name,
        .description = src.description,
        .base_address = src.base_address,
        .data_type = try self.getOrCreateType(src_group.data_types.items[src.data_type], .{
            .dupe_strings = false,
            .src_group = src_group,
        }),
        .deleted = src.deleted,
    });
    return &self.peripherals.items[self.peripherals.items.len - 1];
}

pub const GetOrCreateTypeOptions = struct {
    dupe_strings: bool = true,
    src_group: ?*const PeripheralGroup = null,
};
pub fn getOrCreateType(self: *PeripheralGroup, dt: DataType, options: GetOrCreateTypeOptions) !DataType.ID {
    const key = DataType.WithPeripheralGroup{
        .group = options.src_group orelse self,
        .data_type = &dt,
    };

    if (self.data_type_dedup.getAdapted(key, DataType.AdaptedDedupContext{ .group = self })) |id| {
        if (dt.fallback_name.len > 0) {
            const existing_dt = &self.data_types.items[id];
            existing_dt.fallback_name = try self.updateFallbackName(existing_dt.fallback_name, dt.fallback_name, options.dupe_strings);
        }
        return id;
    }

    if (dt.name.len > 0) {
        if (self.data_type_lookup.get(dt.name)) |_| {
            std.log.err("Type '{s}' already exists!", .{ std.fmt.fmtSliceEscapeLower(dt.name) });
            return error.NamedTypeCollision;
        }
    }

    var copy = dt;

    if (options.dupe_strings) {
        copy.name = try self.maybeDupe(copy.name);
        copy.fallback_name = try self.maybeDupe(copy.fallback_name);
        copy.description = try self.maybeDupe(copy.description);
    }

    copy.kind = switch (dt.kind) {
        .unsigned, .boolean => dt.kind,
        .external => |info| .{ .external = .{
            .import = if (options.dupe_strings) try self.maybeDupe(info.import) else info.import,
        }},
        .register => |info| .{ .register = .{
            .data_type = try self.getOrCreateType(key.group.data_types.items[info.data_type], .{
                .dupe_strings = false,
                .src_group = key.group,
            }),
            .access = info.access,
        }},
        .collection => |info| blk: {
            break :blk .{ .collection = .{
                .count = info.count,
                .data_type = try self.getOrCreateType(key.group.data_types.items[info.data_type], .{
                    .dupe_strings = false,
                    .src_group = key.group,
                }),
            }};
        },
        .alternative => |src_fields| blk: {
            var fields = try self.arena.alloc(DataType.UnionField, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybeDupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybeDupe(field.description) else field.description,
                    .data_type = try self.getOrCreateType(key.group.data_types.items[field.data_type], .{
                        .dupe_strings = false,
                        .src_group = key.group,
                    }),
                };
            }
            break :blk .{ .alternative = fields };
        },
        .structure => |src_fields| blk: {
            var fields = try self.arena.alloc(DataType.StructField, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybeDupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybeDupe(field.description) else field.description,
                    .data_type = try self.getOrCreateType(key.group.data_types.items[field.data_type], .{
                        .dupe_strings = false,
                        .src_group = key.group,
                    }),
                    .offset_bytes = field.offset_bytes,
                    .default_value = field.default_value,
                };
            }
            std.sort.insertion(DataType.StructField, fields, {}, DataType.StructField.lessThan);
            break :blk .{ .structure = fields };
        },
        .bitpack => |src_fields| blk: {
            var fields = try self.arena.alloc(DataType.PackedField, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybeDupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybeDupe(field.description) else field.description,
                    .data_type = try self.getOrCreateType(key.group.data_types.items[field.data_type], .{
                        .dupe_strings = false,
                        .src_group = key.group,
                    }),
                    .offset_bits = field.offset_bits,
                    .default_value = field.default_value,
                };
            }
            std.sort.insertion(DataType.PackedField, fields, {}, DataType.PackedField.lessThan);
            break :blk .{ .bitpack = fields };
        },
        .enumeration => |src_fields| blk: {
            var fields = try self.arena.alloc(DataType.EnumField, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybeDupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybeDupe(field.description) else field.description,
                    .value = field.value,
                };
            }
            std.sort.insertion(DataType.EnumField, fields, {}, DataType.EnumField.lessThan);
            break :blk .{ .enumeration = fields };
        },
    };

    const id: DataType.ID = @intCast(self.data_types.items.len);
    const id2 = id;
    _ =id2;
    try self.data_types.append(self.gpa, copy);
    try self.data_type_dedup.putNoClobberContext(self.gpa, copy, id, .{ .group = self });
    if (copy.name.len > 0) {
        try self.data_type_lookup.putNoClobber(self.gpa, copy.name, id);
    }
    return id;
}

pub fn maybeDupe(self: PeripheralGroup, maybe_str: ?[]const u8) ![]const u8 {
    if (maybe_str) |str| {
        if (str.len > 0) {
            return self.arena.dupe(u8, str);
        }
    }
    return "";
}

fn updateFallbackName(self: PeripheralGroup, existing: []const u8, new: []const u8, allow_dupe: bool) ![]const u8 {
    if (existing.len == 0) return if (allow_dupe) self.maybeDupe(new) else new;
    if (std.mem.indexOfDiff(u8, existing, new)) |i| {
        if (i > 2) {
            return existing[0..i];
        }
        return if (allow_dupe) self.maybeDupe(new) else new;
    }
    return existing;
}

pub fn getOrCreateRegisterType(self: *PeripheralGroup, inner: DataType.ID, access: DataType.AccessPolicy) !DataType.ID {
    const size_bits = self.data_types.items[inner].size_bits;
    return self.getOrCreateType(.{
        .name = "",
        .size_bits = size_bits,
        .kind = .{ .register = .{
            .data_type = inner,
            .access = access,
        }},
        .always_inline = true,
    }, .{});
}

pub fn getOrCreateArrayType(self: *PeripheralGroup, inner: DataType.ID, count: u32) !DataType.ID {
    const size_bits = self.data_types.items[inner].size_bits * count;
    return self.getOrCreateType(.{
        .name = "",
        .size_bits = size_bits,
        .kind = .{ .collection = .{
            .count = count,
            .data_type = inner,
        }},
        .always_inline = true,
    }, .{});
}

pub fn getOrCreateUnsigned(self: *PeripheralGroup, bits: u32) !DataType.ID {
    var name_buf: [64]u8 = undefined;
    return self.getOrCreateType(.{
        .name = try std.fmt.bufPrint(&name_buf, "u{}", .{ bits }),
        .size_bits = bits,
        .kind = .unsigned,
        .always_inline = true,
    }, .{});
}

pub fn getOrCreateBool(self: *PeripheralGroup) !DataType.ID {
    return self.getOrCreateType(.{
        .name = "bool",
        .size_bits = 1,
        .kind = .boolean,
        .always_inline = true,
    }, .{});
}

pub fn findType(self: *PeripheralGroup, name: []const u8) !?DataType.ID {
    if (self.data_type_lookup.get(name)) |id| return id;

    if (std.mem.startsWith(u8, name, "u")) {
        if (std.fmt.parseInt(u32, name[1..], 10)) |bits| {
            return try self.getOrCreateUnsigned(bits);
        } else |_| {}
    }

    if (std.mem.eql(u8, name, "bool")) {
        return try self.getOrCreateBool();
    }

    // TODO [] prefix for arrays

    return null;
}

pub fn lessThan(_: void, a: PeripheralGroup, b: PeripheralGroup) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn computeRefCounts(self: *PeripheralGroup) void {
    // for (self.data_types.items) |*data_type| {
    //     data_type.ref_count = 0;
    // }
    for (self.peripherals.items) |peripheral| {
        if (peripheral.deleted) continue;
        self.data_types.items[peripheral.data_type].addRef(self);
        // "Top level" types used directly by peripherals should always be defined separately if possible.
        // Adding a second ref ensures that will happen unless the type is unnamed:
        self.data_types.items[peripheral.data_type].addRef(self);
    }
}

pub fn assignNames(self: *PeripheralGroup) !void {
    for (self.data_types.items, 0..) |*dt, id| {
        if (!dt.always_inline and dt.ref_count > 1 and dt.name.len == 0 and dt.fallback_name.len > 0) {
            var new_name = dt.fallback_name;
            var attempt: u64 = 1;
            while (true) {
                const result = try self.data_type_lookup.getOrPut(self.gpa, new_name);
                if (result.found_existing) {
                    new_name = try std.fmt.allocPrint(self.arena, "{s}_{}", .{ dt.fallback_name, attempt });
                    attempt += 1;
                } else {
                    result.value_ptr.* = @intCast(id);
                    dt.fallback_name = new_name;
                    break;
                }
            }
        }
    }
}
