arena: std.mem.Allocator,
gpa: std.mem.Allocator,
name: []const u8,
description: []const u8 = "",
separate_file: bool = true,
peripherals: std.ArrayListUnmanaged(Peripheral) = .{},
data_types: std.ArrayListUnmanaged(Data_Type) = .{},
data_type_dedup: std.HashMapUnmanaged(Data_Type, Data_Type.ID, Data_Type.Dedup_Context, load_factor) = .{},
data_type_lookup: std.StringHashMapUnmanaged(Data_Type.ID) = .{},

pub fn deinit(self: *Peripheral_Group) void {
    self.peripherals.deinit(self.gpa);
    self.data_types.deinit(self.gpa);
    self.data_type_dedup.deinit(self.gpa);
    self.data_type_lookup.deinit(self.gpa);
}

pub fn create_peripheral(
    self: *Peripheral_Group,
    name: []const u8,
    base_address: u64,
    data_type: Data_Type.ID,
) !*Peripheral {
    try self.peripherals.append(self.gpa, .{
        .name = name,
        .base_address = base_address,
        .data_type = data_type,
    });
    return &self.peripherals.items[self.peripherals.items.len - 1];
}

pub fn clone_peripheral(
    self: *Peripheral_Group,
    src_group: *const Peripheral_Group,
    src: Peripheral,
) !*Peripheral {
    try self.peripherals.append(self.gpa, .{
        .name = src.name,
        .description = src.description,
        .base_address = src.base_address,
        .data_type = try self.get_or_create_type(src_group.data_types.items[src.data_type], .{
            .dupe_strings = false,
            .src_group = src_group,
        }),
        .deleted = src.deleted,
    });
    return &self.peripherals.items[self.peripherals.items.len - 1];
}

pub const Get_Or_Create_Type_Options = struct {
    dupe_strings: bool = true,
    src_group: ?*const Peripheral_Group = null,
};
pub fn get_or_create_type(self: *Peripheral_Group, dt: Data_Type, options: Get_Or_Create_Type_Options) !Data_Type.ID {
    const key = Data_Type.With_Peripheral_Group{
        .group = options.src_group orelse self,
        .data_type = &dt,
    };

    if (self.data_type_dedup.getAdapted(key, Data_Type.Adapted_Dedup_Context{ .group = self })) |id| {
        if (dt.fallback_name.len > 0) {
            const existing_dt = &self.data_types.items[id];
            existing_dt.fallback_name = try self.update_fallback_name(existing_dt.fallback_name, dt.fallback_name, options.dupe_strings);
        }
        return id;
    }

    if (dt.name.len > 0) {
        if (self.data_type_lookup.get(dt.name)) |_| {
            std.log.err("Type '{s}' already exists!", .{ std.fmt.fmtSliceEscapeLower(dt.name) });
            return error.Named_Type_Collision;
        }
    }

    var copy = dt;

    if (options.dupe_strings) {
        copy.name = try self.maybe_dupe(copy.name);
        copy.fallback_name = try self.maybe_dupe(copy.fallback_name);
        copy.description = try self.maybe_dupe(copy.description);
    }

    copy.kind = switch (dt.kind) {
        .unsigned, .signed, .boolean, .anyopaque => dt.kind,
        .external => |info| .{ .external = .{
            .import = if (options.dupe_strings) try self.maybe_dupe(info.import) else info.import,
            .from_int = if (info.from_int) |from_int| blk: {
                break :blk if (options.dupe_strings) try self.maybe_dupe(from_int) else from_int;
            } else null,
        }},
        .pointer => |info| .{ .pointer = .{
            .data_type = try self.get_or_create_type(key.group.data_types.items[info.data_type], .{
                .dupe_strings = false,
                .src_group = key.group,
            }),
            .constant = info.constant,
            .allow_zero = info.allow_zero,
        }},
        .register => |info| .{ .register = .{
            .data_type = try self.get_or_create_type(key.group.data_types.items[info.data_type], .{
                .dupe_strings = false,
                .src_group = key.group,
            }),
            .access = info.access,
        }},
        .collection => |info| blk: {
            break :blk .{ .collection = .{
                .count = info.count,
                .data_type = try self.get_or_create_type(key.group.data_types.items[info.data_type], .{
                    .dupe_strings = false,
                    .src_group = key.group,
                }),
            }};
        },
        .alternative => |src_fields| blk: {
            const fields = try self.arena.alloc(Data_Type.Union_Field, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybe_dupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybe_dupe(field.description) else field.description,
                    .data_type = try self.get_or_create_type(key.group.data_types.items[field.data_type], .{
                        .dupe_strings = false,
                        .src_group = key.group,
                    }),
                };
            }
            break :blk .{ .alternative = fields };
        },
        .structure => |src_fields| blk: {
            const fields = try self.arena.alloc(Data_Type.Struct_Field, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybe_dupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybe_dupe(field.description) else field.description,
                    .data_type = try self.get_or_create_type(key.group.data_types.items[field.data_type], .{
                        .dupe_strings = false,
                        .src_group = key.group,
                    }),
                    .offset_bytes = field.offset_bytes,
                    .default_value = field.default_value,
                };
            }
            std.sort.insertion(Data_Type.Struct_Field, fields, {}, Data_Type.Struct_Field.less_than);
            break :blk .{ .structure = fields };
        },
        .bitpack => |src_fields| blk: {
            const fields = try self.arena.alloc(Data_Type.Packed_Field, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybe_dupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybe_dupe(field.description) else field.description,
                    .data_type = try self.get_or_create_type(key.group.data_types.items[field.data_type], .{
                        .dupe_strings = false,
                        .src_group = key.group,
                    }),
                    .offset_bits = field.offset_bits,
                    .default_value = field.default_value,
                };
            }
            std.sort.insertion(Data_Type.Packed_Field, fields, {}, Data_Type.Packed_Field.less_than);
            break :blk .{ .bitpack = fields };
        },
        .enumeration => |src_fields| blk: {
            const fields = try self.arena.alloc(Data_Type.Enum_Field, src_fields.len);
            for (src_fields, fields) |field, *dest| {
                dest.* = .{
                    .name = if (options.dupe_strings) try self.maybe_dupe(field.name) else field.name,
                    .description = if (options.dupe_strings) try self.maybe_dupe(field.description) else field.description,
                    .value = field.value,
                };
            }
            std.sort.insertion(Data_Type.Enum_Field, fields, {}, Data_Type.Enum_Field.less_than);
            break :blk .{ .enumeration = fields };
        },
    };

    const id: Data_Type.ID = @intCast(self.data_types.items.len);
    const id2 = id;
    _ =id2;
    try self.data_types.append(self.gpa, copy);
    try self.data_type_dedup.putNoClobberContext(self.gpa, copy, id, .{ .group = self });
    if (copy.name.len > 0) {
        try self.data_type_lookup.putNoClobber(self.gpa, copy.name, id);
    }
    return id;
}

pub fn maybe_dupe(self: Peripheral_Group, maybe_str: ?[]const u8) ![]const u8 {
    if (maybe_str) |str| {
        if (str.len > 0) {
            return self.arena.dupe(u8, str);
        }
    }
    return "";
}

fn update_fallback_name(self: Peripheral_Group, existing: []const u8, new: []const u8, allow_dupe: bool) ![]const u8 {
    if (existing.len == 0) return if (allow_dupe) self.maybe_dupe(new) else new;
    if (std.mem.indexOfDiff(u8, existing, new)) |i| {
        if (i > 2) {
            return existing[0..i];
        }
        return if (allow_dupe) self.maybe_dupe(new) else new;
    }
    return existing;
}

pub fn get_or_create_register_type(self: *Peripheral_Group, inner: Data_Type.ID, access: Data_Type.Access_Policy) !Data_Type.ID {
    const size_bits = self.data_types.items[inner].size_bits;
    return self.get_or_create_type(.{
        .name = "",
        .size_bits = size_bits,
        .kind = .{ .register = .{
            .data_type = inner,
            .access = access,
        }},
        .inline_mode = .always,
    }, .{ .dupe_strings = false });
}

pub fn get_or_create_array_type(self: *Peripheral_Group, inner: Data_Type.ID, count: u32) !Data_Type.ID {
    const size_bits = self.data_types.items[inner].size_bits * count;
    return self.get_or_create_type(.{
        .name = "",
        .size_bits = size_bits,
        .kind = .{ .collection = .{
            .count = count,
            .data_type = inner,
        }},
        .inline_mode = .always,
    }, .{ .dupe_strings = false });
}

pub fn get_or_create_pointer(self: *Peripheral_Group, inner: Data_Type.ID, allow_zero: bool, constant: bool) !Data_Type.ID {
    return self.get_or_create_type(.{
        .name = "",
        .size_bits = 32,
        .kind = .{ .pointer = .{
            .data_type = inner,
            .constant = constant,
            .allow_zero = allow_zero,
        }},
        .inline_mode = .always,
    }, .{ .dupe_strings = false });
}

pub fn get_or_create_unsigned(self: *Peripheral_Group, bits: u32) !Data_Type.ID {
    var name_buf: [64]u8 = undefined;
    return self.get_or_create_type(.{
        .name = try std.fmt.bufPrint(&name_buf, "u{}", .{ bits }),
        .size_bits = bits,
        .kind = .unsigned,
        .inline_mode = .always,
    }, .{});
}

pub fn get_or_create_signed(self: *Peripheral_Group, bits: u32) !Data_Type.ID {
    var name_buf: [64]u8 = undefined;
    return self.get_or_create_type(.{
        .name = try std.fmt.bufPrint(&name_buf, "i{}", .{ bits }),
        .size_bits = bits,
        .kind = .signed,
        .inline_mode = .always,
    }, .{});
}

pub fn get_or_create_bool(self: *Peripheral_Group) !Data_Type.ID {
    return self.get_or_create_type(.{
        .name = "bool",
        .size_bits = 1,
        .kind = .boolean,
        .inline_mode = .always,
    }, .{ .dupe_strings = false });
}

pub fn get_or_create_anyopaque(self: *Peripheral_Group) !Data_Type.ID {
    return self.get_or_create_type(.{
        .name = "anyopaque",
        .size_bits = 0,
        .kind = .anyopaque,
        .inline_mode = .always,
    }, .{ .dupe_strings = false });
}

pub fn get_or_create_external_type(self: *Peripheral_Group, name: []const u8, import: []const u8, size: u32) !Data_Type.ID {
    return self.get_or_create_type(.{
        .name = name,
        .size_bits = size,
        .kind = .{ .external = .{
            .import = import,
        }},
        .inline_mode = .never,
    }, .{});
}

pub fn find_type(self: *Peripheral_Group, name: []const u8) !?Data_Type.ID {
    if (self.data_type_lookup.get(name)) |id| return id;

    if (std.mem.startsWith(u8, name, "u")) {
        if (std.fmt.parseInt(u32, name[1..], 10)) |bits| {
            return try self.get_or_create_unsigned(bits);
        } else |_| {}
    }

    if (std.mem.startsWith(u8, name, "i")) {
        if (std.fmt.parseInt(u32, name[1..], 10)) |bits| {
            return try self.get_or_create_signed(bits);
        } else |_| {}
    }

    if (std.mem.eql(u8, name, "bool")) {
        return try self.get_or_create_bool();
    }

    if (std.mem.startsWith(u8, name, "*")) {
        var remaining = name[1..];
        while (remaining.len > 0 and remaining[0] == ' ') {
            remaining = remaining[1..];
        }

        var allow_zero = false;
        if (std.mem.startsWith(u8, remaining, "allowzero ")) {
            remaining = remaining["allowzero ".len ..];
            allow_zero = true;
        }

        var constant = false;
        if (std.mem.startsWith(u8, remaining, "const ")) {
            remaining = remaining["const ".len ..];
            constant = true;
        }

        const base = (try self.find_type(remaining)) orelse return null;
        return try self.get_or_create_pointer(base, allow_zero, constant);
    }

    if (std.mem.startsWith(u8, name, "[")) {
        var remaining = name[1..];
        while (remaining.len > 0 and remaining[0] == ' ') {
            remaining = remaining[1..];
        }

        const end = for (0.., remaining) |i, ch| {
            if (ch == ' ' or ch == ']') break i;
        } else remaining.len;
        const count = std.fmt.parseUnsigned(u32, remaining[0..end], 0) catch return null;

        remaining = remaining[end..];
        while (remaining.len > 0 and remaining[0] == ' ') {
            remaining = remaining[1..];
        }

        if (remaining.len == 0 or remaining[0] != ']') return null;
        remaining = remaining[1..];

        while (remaining.len > 0 and remaining[0] == ' ') {
            remaining = remaining[1..];
        }

        const base = (try self.find_type(remaining)) orelse return null;
        return try self.get_or_create_array_type(base, count);
    }

    if (std.mem.eql(u8, name, "anyopaque")) {
        return try self.get_or_create_anyopaque();
    }

    return null;
}

pub fn less_than(_: void, a: Peripheral_Group, b: Peripheral_Group) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn compute_ref_counts(self: *Peripheral_Group) void {
    // for (self.data_types.items) |*data_type| {
    //     data_type.ref_count = 0;
    // }
    for (self.peripherals.items) |peripheral| {
        if (peripheral.deleted) continue;
        self.data_types.items[peripheral.data_type].add_ref(self);
        // "Top level" types used directly by peripherals should always be defined separately if possible.
        // Adding a second ref ensures that will happen unless the type is unnamed:
        self.data_types.items[peripheral.data_type].add_ref(self);
    }
}

pub fn assign_names(self: *Peripheral_Group) !void {
    for (self.data_types.items, 0..) |*dt, id| {
        if (dt.inline_mode != .always and dt.ref_count > 1 and dt.name.len == 0 and dt.fallback_name.len > 0) {
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

const load_factor = std.hash_map.default_max_load_percentage;

const Peripheral_Group = @This();
const Data_Type = @import("Data_Type.zig");
const Peripheral = @import("Peripheral.zig");
const std = @import("std");
