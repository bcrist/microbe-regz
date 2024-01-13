var command_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const command_alloc = command_arena.allocator();

fn E(comptime T: type) type {
    return T.Error || std.mem.Allocator.Error || error {
        SExpressionSyntaxError,
        Named_Type_Collision,
        Peripheral_Group_Missing,
        EndOfStream,
        NoSpaceLeft,
    };
}

const Group_Op = enum {
    nop,
    peripheral,
    create_peripheral,
    create_type,
    copy_type,
};
const group_ops = std.ComptimeStringMap(Group_Op, .{
    .{ "--", .nop },
    .{ "peripheral", .peripheral },
    .{ "create-peripheral", .create_peripheral },
    .{ "create-type", .create_type },
    .{ "copy-type", .copy_type },
});
pub fn handle_sx(db: *Database, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    defer _ = command_arena.reset(.free_all);

    while (try reader.expression("--")) {
        try reader.ignore_remaining_expression();
    }

    while (try reader.expression("group")) {
        var group_name = try reader.require_any_string();
        var group = try db.find_or_create_peripheral_group(group_name);
        group_name = group.name;

        while (try reader.open()) {
            switch (try reader.require_map_enum(Group_Op, group_ops)) {
                .nop => {
                    try reader.ignore_remaining_expression();
                    continue;
                },
                .peripheral => {
                    try peripheral_modify(db, group, T, reader);
                    // move-to-group may have caused db.groups to be resized,
                    // so we need to make sure our group pointer is updated:
                    group = try db.find_or_create_peripheral_group(group_name);
                },
                .create_peripheral => try peripheral_create(group, T, reader),
                .create_type => try type_create_named(group, T, reader),
                .copy_type => try type_copy(group, T, reader),
            }
            try reader.require_close();
        }

        try reader.require_close();
    }

    while (try reader.expression("--")) {
        try reader.ignore_remaining_expression();
    }

    try reader.require_done();
}

const Create_Peripheral_Op = enum {
    nop,
    base_address,
    set_type,
};
const create_peripheral_ops = std.ComptimeStringMap(Create_Peripheral_Op, .{
    .{ "--", .nop },
    .{ "base", .base_address },
    .{ "type", .set_type },
});
fn peripheral_create(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const name = try group.maybe_dupe(try reader.require_any_string());
    const description = try group.maybe_dupe(try reader.any_string());
    var base_address: u64 = 0;

    var data_type = try group.get_or_create_type(.{
        .size_bits = 0,
        .kind = .{ .structure = &.{} }, 
    }, .{});

    while (try reader.open()) {
        switch (try reader.require_map_enum(Create_Peripheral_Op, create_peripheral_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .base_address => base_address = try reader.require_any_int(u64, 0),
            .set_type => data_type = try type_create_or_ref(group, T, reader),
        }
        try reader.require_close();
    }

    var dt = group.data_types.items[data_type];
    if (dt.fallback_name.len == 0) {
        dt.fallback_name = name;
        data_type = try group.get_or_create_type(dt, .{ .dupe_strings = false });
    }

    const peripheral = try group.create_peripheral(name, base_address, data_type);
    peripheral.description = description;
}

const Peripheral_Op = enum {
    nop,
    rename,
    delete,
    move_to_group,
    @"type",
    register,
    set_type,
    set_base_address,
};
const peripheral_ops = std.ComptimeStringMap(Peripheral_Op, .{
    .{ "--", .nop },
    .{ "rename", .rename },
    .{ "delete", .delete },
    .{ "move-to-group", .move_to_group },
    .{ "type", .@"type" },
    .{ "reg", .register },
    .{ "set-type", .set_type },
    .{ "set-base", .set_base_address },
});
fn peripheral_modify(db: *Database, original_group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const peripheral_pattern = try db.gpa.dupe(u8, try reader.require_any_string());
    defer db.gpa.free(peripheral_pattern);

    var group = original_group;

    while (try reader.open()) {
        switch (try reader.require_map_enum(Peripheral_Op, peripheral_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .rename => try peripheral_rename(group, peripheral_pattern, T, reader),
            .delete => try peripheral_delete(group, peripheral_pattern),
            .move_to_group => group = try peripheral_move_to_group(db, group.name, peripheral_pattern, T, reader),
            .@"type" => try peripheral_type_modify(group, peripheral_pattern, T, reader),
            .register => try peripheral_register_modify(group, peripheral_pattern, T, reader),
            .set_type => try peripheral_set_type(group, peripheral_pattern, T, reader),
            .set_base_address => try peripheral_set_base_address(group, peripheral_pattern, T, reader),
        }
        try reader.require_close();
    }
}

fn peripheral_rename(group: *Peripheral_Group, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.arena.dupe(u8, try reader.require_any_string());

    var iter = Peripheral_Iterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        std.log.debug("Renaming peripheral {s}.{s} => {s}", .{
            group.name,
            peripheral.name,
            new_name,
        });
        peripheral.name = new_name;
    }
}

fn peripheral_delete(group: *Peripheral_Group, peripheral_pattern: []const u8) !void {
    var iter = Peripheral_Iterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        std.log.debug("Deleting peripheral {s}.{s}", .{
            group.name,
            peripheral.name,
        });
        peripheral.deleted = true;
    }
}

// Note any ops in the peripheral after the move-to-group will use the new group as context, so we need to return it.
fn peripheral_move_to_group(db: *Database, src_group_name: []const u8, peripheral_pattern: []const u8, comptime T:type, reader: *sx.Reader(T)) E(T)!*Peripheral_Group {
    const dest_group_name = try reader.require_any_string();

    var new_group = try db.find_or_create_peripheral_group(dest_group_name);
    const old_group = try db.find_peripheral_group(src_group_name);

    if (new_group != old_group) {
        var iter = Peripheral_Iterator {
            .pattern = peripheral_pattern,
            .group = old_group,
        };
        while (iter.next()) |peripheral| {
            std.log.debug("Moving peripheral {s}.{s} to group {s}", .{
                old_group.name,
                peripheral.name,
                new_group.name,
            });
            _ = try new_group.clone_peripheral(old_group, peripheral.*);
            peripheral.deleted = true;
        }
    }

    return new_group;
}

fn peripheral_type_modify(group: *Peripheral_Group, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    var action_list = begin_type_actions();
    const types = try collect_matching_peripheral_types(&action_list, group, peripheral_pattern);
    try type_modify(&action_list, group, types, T, reader);
    try finish_type_actions(group, &action_list, 0);
}

fn peripheral_register_modify(group: *Peripheral_Group, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const register_pattern = try group.gpa.dupe(u8, try reader.require_any_string());
    defer group.gpa.free(register_pattern);

    var action_list = begin_type_actions();
    const types = try collect_matching_peripheral_types(&action_list, group, peripheral_pattern);
    const reg_types = try collect_matching_register_types(&action_list, group, types, register_pattern);
    try type_modify(&action_list, group, reg_types, T, reader);
    try finish_type_actions(group, &action_list, 0);
}

fn peripheral_set_type(group: *Peripheral_Group, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const type_id = try type_create_or_ref(group, T, reader);
    var iter = Peripheral_Iterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        peripheral.data_type = type_id;
    }
}

fn peripheral_set_base_address(group: *Peripheral_Group, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_base_address = try reader.require_any_int(u64, 0);

    if (try reader.string("adjust-offsets")) {
        var action_list = begin_type_actions();

        var new_data_types = std.ArrayList(Data_Type.ID).init(command_alloc);
        var iter = Peripheral_Iterator.init(group, peripheral_pattern);
        while (iter.next()) |peripheral| {
            var dt = group.data_types.items[peripheral.data_type];
            switch (dt.kind) {
                .structure => |const_fields| {
                    var fields = try std.ArrayList(Data_Type.Struct_Field).initCapacity(command_alloc, const_fields.len);
                    for (const_fields) |f| {
                        const addr = peripheral.base_address + f.offset_bytes;
                        if (addr >= new_base_address) {
                            var new_field = f;
                            new_field.offset_bytes = @intCast(addr - new_base_address);
                            fields.appendAssumeCapacity(new_field);
                        }
                    }
                    dt.kind = .{ .structure = fields.items };
                },
                else => {},
            }
            try new_data_types.append(try group.get_or_create_type(dt, .{ .dupe_strings = false }));
        }
        iter = Peripheral_Iterator.init(group, peripheral_pattern);
        var i: usize = 0;
        while (iter.next()) |peripheral| {
            peripheral.data_type = new_data_types.items[i];
            i += 1;
        }
        try finish_type_actions(group, &action_list, 0);
    }

    var iter = Peripheral_Iterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        peripheral.base_address = new_base_address;
    }
}

fn type_copy(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const id = (try type_ref(group, T, reader)) orelse return error.SExpressionSyntaxError;
    var types: [1]Data_Type = .{ group.data_types.items[id] };
    types[0].name = try group.maybe_dupe(try reader.require_any_string());

    var action_list = begin_type_actions();
    try type_modify(&action_list, group, &types, T, reader);
    try finish_type_actions(group, &action_list, 0);
    _ = try group.get_or_create_type(types[0], .{ .dupe_strings = false });
}

fn type_create_named(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const name = try group.maybe_dupe(try reader.require_any_string());
    const desc = try group.maybe_dupe(try reader.any_string());
    _ = try type_create(group, name, desc, T, reader);
}

fn type_create_or_ref(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.ID {
    return (try type_ref(group, T, reader)) orelse try type_create(group, "", "", T, reader);
}

fn type_ref(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!?Data_Type.ID {
    reader.set_peek(true);
    if (try reader.any_string()) |name| {
        reader.set_peek(false);
        if (try group.find_type(name)) |id| {
            try reader.any();
            return id;
        } else {
            return error.SExpressionSyntaxError;
        }
    }
    reader.set_peek(false);
    return null;
}

const Create_Type_Op = enum {
    nop,
    name,
    fallback_name,
    description,
    size_bits,
    external,
    register,
    pointer,
    collection,
    alternative,
    structure,
    bitpack,
    enumeration,
    set_inline,
};
const create_type_ops = std.ComptimeStringMap(Create_Type_Op, .{
    .{ "--", .nop },
    .{ "name", .name },
    .{ "fallback-name", .fallback_name },
    .{ "description", .description },
    .{ "bits", .size_bits },
    .{ "ext", .external },
    .{ "reg", .register },
    .{ "pointer", .pointer },
    .{ "array", .collection },
    .{ "union", .alternative },
    .{ "struct", .structure },
    .{ "packed", .bitpack },
    .{ "enum", .enumeration },
    .{ "inline", .set_inline },
});
fn type_create(group: *Peripheral_Group, default_name: []const u8, default_desc: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.ID {
    var dt = Data_Type{
        .name = default_name,
        .description = default_desc,
        .size_bits = 0,
        .kind = .unsigned,
    };

    while (try reader.open()) {
        switch (try reader.require_map_enum(Create_Type_Op, create_type_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .name => dt.name = try group.maybe_dupe(try reader.require_any_string()),
            .fallback_name => dt.fallback_name = try group.maybe_dupe(try reader.require_any_string()),
            .description => dt.description = try group.maybe_dupe(try reader.require_any_string()),
            .size_bits => dt.size_bits = try reader.require_any_int(u32, 0),
            .set_inline => dt.inline_mode = try reader.require_any_enum(Data_Type.Inline_Mode),
            .external => {
                const import = try group.maybe_dupe(try reader.require_any_string());
                var maybe_from_int = try reader.any_string();
                if (maybe_from_int) |from_int| {
                    maybe_from_int = try group.maybe_dupe(from_int);
                }
                dt.kind = .{ .external = .{
                    .import = import,
                    .from_int = maybe_from_int,
                }};
                dt.inline_mode = .never;
            },
            .register => {
                dt.kind = try type_kind_register(group, T, reader);
                if (dt.size_bits == 0) {
                    dt.size_bits = group.data_types.items[dt.kind.register.data_type].size_bits;
                }
                dt.inline_mode = .always;
            },
            .pointer => {
                dt.kind = try type_kind_pointer(group, T, reader);
                if (dt.size_bits == 0) {
                    dt.size_bits = 32;
                }
                dt.inline_mode = .always;
            },
            .collection => {
                dt.kind = try type_kind_collection(group, T, reader);
                if (dt.size_bits == 0) {
                    const info = dt.kind.collection;
                    dt.size_bits = ((group.data_types.items[info.data_type].size_bits + 7) / 8) * info.count * 8;
                }
                dt.inline_mode = .always;
            },
            .alternative => {
                dt.kind = try type_kind_alternative(group, T, reader);
                if (dt.size_bits == 0) {
                    var max_bits: u32 = 0;
                    for (dt.kind.alternative) |f| {
                        const bits = group.data_types.items[f.data_type].size_bits;
                        max_bits = @max(max_bits, bits);
                    }
                    dt.size_bits = max_bits;
                }
            },
            .structure => {
                dt.kind = try type_kind_structure(group, T, reader);
                if (dt.size_bits == 0) {
                    var bytes: u32 = 0;
                    for (dt.kind.structure) |f| {
                        const dt_bytes = (group.data_types.items[f.data_type].size_bits + 7) / 8;
                        bytes = @max(bytes, f.offset_bytes + dt_bytes);
                    }
                    dt.size_bits = bytes * 8;
                }
            },
            .bitpack => {
                dt.kind = try type_kind_bitpack(group, T, reader);
                if (dt.size_bits == 0) {
                    var bits: u32 = 0;
                    for (dt.kind.bitpack) |f| {
                        const dt_bits = group.data_types.items[f.data_type].size_bits;
                        bits = @max(bits, f.offset_bits + dt_bits);
                    }
                    dt.size_bits = bits;
                }
            },
            .enumeration => {
                dt.kind = try type_kind_enumeration(group, T, reader);
                if (dt.size_bits == 0) {
                    var max_val: u32 = 1;
                    for (dt.kind.enumeration) |f| {
                        max_val = @max(max_val, f.value);
                    }
                    dt.size_bits = std.math.log2_int(u32, max_val) + 1;
                }
            },
        }
        try reader.require_close();
    }

    return group.get_or_create_type(dt, .{ .dupe_strings = false });
}

fn type_kind_register(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Kind {
    const access = (try reader.any_enum(Data_Type.Access_Policy)) orelse .rw;
    const inner_type = try type_create_or_ref(group, T, reader);
    return .{ .register = .{
        .access = access,
        .data_type = inner_type,
    }};
}

fn type_kind_pointer(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Kind {
    const allow_zero = try reader.string("allowzero");
    const constant = try reader.string("const");
    const inner_type = try type_create_or_ref(group, T, reader);
    return .{ .pointer = .{
        .data_type = inner_type,
        .constant = constant,
        .allow_zero = allow_zero,
    }};
}

fn type_kind_collection(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Kind {
    const count = try reader.require_any_int(u32, 0);
    const inner_type = try type_create_or_ref(group, T, reader);
    return .{ .collection = .{
        .count = count,
        .data_type = inner_type,
    }};
}

fn type_kind_alternative(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Kind {
    var fields = std.ArrayList(Data_Type.Union_Field).init(command_alloc);

    while (true) {
        if (try reader.expression("--")) {
            try reader.ignore_remaining_expression();
        } else if (try reader.open()) {
            const field = try parse_union_field(group, T, reader);
            try reader.require_close();
            try fields.append(field);
        } else break;
    }
    return .{ .alternative = fields.items };
}
const Parse_Union_Field_Op = enum {
    nop,
    set_type,
};
const parse_union_field_ops = std.ComptimeStringMap(Parse_Union_Field_Op, .{
    .{ "--", .nop },
    .{ "type", .set_type },
});
fn parse_union_field(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Union_Field {
    const name = try group.maybe_dupe(try reader.require_any_string());
    const description = try group.maybe_dupe(try reader.any_string());
    var data_type = try group.get_or_create_bool();

    while (try reader.open()) {
        switch (try reader.require_map_enum(Parse_Union_Field_Op, parse_union_field_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .set_type => data_type = try type_create_or_ref(group, T, reader),
        }
        try reader.require_close();
    }

    return .{
        .name = name,
        .description = description,
        .data_type = data_type,
    };
}

fn type_kind_structure(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Kind {
    var fields = std.ArrayList(Data_Type.Struct_Field).init(command_alloc);

    var default_offset_bytes: u32 = 0;
    while (true) {
        if (try reader.expression("--")) {
            try reader.ignore_remaining_expression();
        } else if (try reader.open()) {
            const field = try parse_struct_field(group, default_offset_bytes, T, reader);
            try reader.require_close();
            try fields.append(field);
            const dt = group.data_types.items[field.data_type];
            default_offset_bytes = field.offset_bytes + (dt.size_bits + 7) / 8;
        } else break;
    }
    return .{ .structure = fields.items };
}
const Parse_Struct_Field_Op = enum {
    nop,
    offset_bytes,
    default_value,
    set_type,
};
const parse_struct_field_ops = std.ComptimeStringMap(Parse_Struct_Field_Op, .{
    .{ "--", .nop },
    .{ "offset", .offset_bytes },
    .{ "default", .default_value },
    .{ "type", .set_type },
});
fn parse_struct_field(group: *Peripheral_Group, default_offset_bytes: u32, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Struct_Field {
    const name = try group.maybe_dupe(try reader.require_any_string());
    const description = try group.maybe_dupe(try reader.any_string());
    var offset_bytes = default_offset_bytes;
    var default_value: u64 = 0;
    var data_type = try group.get_or_create_bool();

    while (try reader.open()) {
        switch (try reader.require_map_enum(Parse_Struct_Field_Op, parse_struct_field_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .offset_bytes => offset_bytes = try reader.require_any_int(u32, 0),
            .default_value => default_value = try reader.require_any_int(u64, 0),
            .set_type => data_type = try type_create_or_ref(group, T, reader),
        }
        try reader.require_close();
    }

    return .{
        .name = name,
        .description = description,
        .offset_bytes = offset_bytes,
        .data_type = data_type,
        .default_value = default_value,
    };
}

fn type_kind_bitpack(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Kind {
    var fields = std.ArrayList(Data_Type.Packed_Field).init(command_alloc);

    var default_offset_bits: u32 = 0;
    while (true) {
        if (try reader.expression("--")) {
            try reader.ignore_remaining_expression();
        } else if (try reader.open()) {
            const field = try parse_packed_field(group, default_offset_bits, T, reader);
            try reader.require_close();
            try fields.append(field);
            const dt = group.data_types.items[field.data_type];
            default_offset_bits = field.offset_bits + dt.size_bits;
        } else break;
    }
    return .{ .bitpack = fields.items };
}
const Parse_Packed_Field_Op = enum {
    nop,
    offset_bits,
    default_value,
    set_type,
};
const parse_packed_field_ops = std.ComptimeStringMap(Parse_Packed_Field_Op, .{
    .{ "--", .nop },
    .{ "offset", .offset_bits },
    .{ "default", .default_value },
    .{ "type", .set_type },
});
fn parse_packed_field(group: *Peripheral_Group, default_offset_bits: u32, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Packed_Field {
    const name = try group.maybe_dupe(try reader.require_any_string());
    const description = try group.maybe_dupe(try reader.any_string());
    var offset_bits = default_offset_bits;
    var default_value: u64 = 0;
    var data_type = try group.get_or_create_bool();

    while (try reader.open()) {
        switch (try reader.require_map_enum(Parse_Packed_Field_Op, parse_packed_field_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .offset_bits => offset_bits = try reader.require_any_int(u32, 0),
            .default_value => default_value = try reader.require_any_int(u64, 0),
            .set_type => data_type = try type_create_or_ref(group, T, reader),
        }
        try reader.require_close();
    }

    return .{
        .name = name,
        .description = description,
        .offset_bits = offset_bits,
        .data_type = data_type,
        .default_value = default_value,
    };
}

fn type_kind_enumeration(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Kind {
    var fields = std.ArrayList(Data_Type.Enum_Field).init(command_alloc);

    while (true) {
        if (try reader.expression("--")) {
            try reader.ignore_remaining_expression();
        } else if (try reader.open()) {
            try fields.append(try parse_enum_field(group, T, reader));
            try reader.require_close();
        } else break;
    }
    return .{ .enumeration = fields.items };
}
fn parse_enum_field(group: *Peripheral_Group, comptime T: type, reader: *sx.Reader(T)) E(T)!Data_Type.Enum_Field {
    const value = try reader.require_any_int(u32, 0);
    const name = try group.maybe_dupe(try reader.require_any_string());
    const description = try group.maybe_dupe(try reader.any_string());
    return .{
        .name = name,
        .description = description,
        .value = value,
    };
}

const Modify_Type_Op = enum {
    nop,
    set_name,
    set_fallback_name,
    set_desc,
    set_bits,
    set_access,
    inner,
    field,
    delete_field,
    merge_field,
    create_field,
};
const modify_type_ops = std.ComptimeStringMap(Modify_Type_Op, .{
    .{ "--", .nop },
    .{ "rename", .set_name },
    .{ "set-name", .set_name },
    .{ "set-fallback-name", .set_fallback_name },
    .{ "set-desc", .set_desc },
    .{ "set-bits", .set_bits },
    .{ "set-access", .set_access },
    .{ "inner", .inner },
    .{ "field", .field },
    .{ "delete-field", .delete_field },
    .{ "merge-field", .merge_field },
    .{ "create-field", .create_field },
});
fn type_modify(action_list: *Type_Action_List, group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    while (try reader.open()) {
        switch (try reader.require_map_enum(Modify_Type_Op, modify_type_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .set_name => try type_set_name(group, types, T, reader),
            .set_fallback_name => try type_set_fallback_name(group, types, T, reader),
            .set_desc => try type_set_description(group, types, T, reader),
            .set_bits => try type_set_bits(types, T, reader),
            .set_access => try type_set_access(types, T, reader),
            .inner => try type_modify_inner(action_list, group, types, T, reader),
            .field => try field_modify(action_list, group, types, T, reader),
            .delete_field => try field_delete(types, T, reader),
            .merge_field => try field_merge(group, types, T, reader),
            .create_field => try field_create(group, types, T, reader),
        }
        try reader.require_close();
    }
}

fn type_set_name(group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.maybe_dupe(try reader.require_any_string());
    for (types) |*dt| {
        dt.name = new_name;
    }
}

fn type_set_fallback_name(group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.maybe_dupe(try reader.require_any_string());
    for (types) |*dt| {
        dt.fallback_name = new_name;
    }
}

fn type_set_description(group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_desc = try group.maybe_dupe(try reader.require_any_string());
    for (types) |*dt| {
        dt.description = new_desc;
    }
}

fn type_set_bits(types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const bits = try reader.require_any_int(u32, 0);
    for (types) |*dt| {
        dt.size_bits = bits;
    }
}

fn type_set_access(types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const access = try reader.require_any_enum(Data_Type.Access_Policy);
    for (types) |*dt| {
        switch (dt.kind) {
            .register => |*info| {
                info.access = access;
            },
            else => {},
        }
    }
}

fn type_modify_inner(action_list: *Type_Action_List, group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const stop = action_list.len;
    const reg_types = try collect_inner_types(action_list, group, types);
    try type_modify(action_list, group, reg_types, T, reader);
    try finish_type_actions(group, action_list, stop);
}

const Modify_Field_Op = enum {
    nop,
    set_name,
    set_desc,
    set_offset,
    set_default,
    set_value,
    @"type",
    set_type,
};
const modify_field_ops = std.ComptimeStringMap(Modify_Field_Op, .{
    .{ "--", .nop },
    .{ "rename", .set_name },
    .{ "set-name", .set_name },
    .{ "set-desc", .set_desc },
    .{ "set-offset", .set_offset },
    .{ "set-default", .set_default },
    .{ "set-value", .set_value },
    .{ "set-type", .set_type },
    .{ "type", .@"type" },
});
fn field_modify(action_list: *Type_Action_List, group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const field_pattern = try group.gpa.dupe(u8, try reader.require_any_string());
    defer group.gpa.free(field_pattern);

    const field_refs = try collect_matching_fields(types, field_pattern);

    while (try reader.open()) {
        switch (try reader.require_map_enum(Modify_Field_Op, modify_field_ops)) {
            .nop => {
                try reader.ignore_remaining_expression();
                continue;
            },
            .set_name => try field_set_name(group, field_refs, T, reader),
            .set_desc => try field_set_desc(group, field_refs, T, reader),
            .set_offset => try field_set_offset(field_refs, T, reader),
            .set_value => try field_set_value(field_refs, T, reader),
            .set_default => try field_set_default_value(field_refs, T, reader),
            .set_type => try field_type_set(group, field_refs, T, reader),
            .@"type" => try field_type_modify(action_list, group, field_refs, T, reader),
        }
        try reader.require_close();
    }
}

fn field_delete(types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const field_pattern = try reader.require_any_string();

    for (types) |*dt| {
        switch (dt.kind) {
            .unsigned, .signed, .boolean, .anyopaque,
            .external, .register, .collection, .pointer => {},
            .alternative => |const_fields| {
                var fields = try std.ArrayList(Data_Type.Union_Field).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!name_matches_pattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .alternative = fields.items };
            },
            .structure => |const_fields| {
                var fields = try std.ArrayList(Data_Type.Struct_Field).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!name_matches_pattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .structure = fields.items };
            },
            .bitpack => |const_fields| {
                var fields = try std.ArrayList(Data_Type.Packed_Field).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!name_matches_pattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .bitpack = fields.items };
            },
            .enumeration => |const_fields| {
                var fields = try std.ArrayList(Data_Type.Enum_Field).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!name_matches_pattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .enumeration = fields.items };
            },
        }
    }
}

fn field_merge(group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const field_pattern = try group.gpa.dupe(u8, try reader.require_any_string());
    defer group.gpa.free(field_pattern);

    const new_field_name = try group.maybe_dupe(try reader.require_any_string());
    const new_type_id = try type_create_or_ref(group, T, reader);

    const new_dt = group.data_types.items[new_type_id];

    for (types) |*dt| {
        switch (dt.kind) {
            .unsigned, .signed, .boolean, .anyopaque,
            .external, .register, .collection, .alternative, .enumeration, .pointer => {},
            .structure => |const_fields| {
                const base_field = loop: for (const_fields) |f| {
                    if (name_matches_pattern(f.name, field_pattern)) break :loop f;
                } else continue;
                const offset_bytes = base_field.offset_bytes;
                const end_offset_bytes = offset_bytes + (new_dt.size_bits + 7) / 8;

                var fields = try std.ArrayList(Data_Type.Struct_Field).initCapacity(command_alloc, const_fields.len + 1);

                var default_value: u64 = 0;
                for (const_fields) |f| {
                    const size_bytes = (group.data_types.items[f.data_type].size_bits + 7) / 8;
                    if (f.offset_bytes < end_offset_bytes and f.offset_bytes + size_bytes > offset_bytes) {
                        var default = f.default_value;
                        if (f.offset_bytes > offset_bytes) {
                            default = default << @truncate((f.offset_bytes - offset_bytes) * 8);
                        } else if (f.offset_bytes < offset_bytes) {
                            default = default >> @truncate((offset_bytes - f.offset_bytes) * 8);
                        }
                        default_value |= default;
                    } else {
                        fields.appendAssumeCapacity(f);
                    }
                }

                fields.appendAssumeCapacity(.{
                    .name = new_field_name,
                    .description = base_field.description,
                    .offset_bytes = offset_bytes,
                    .default_value = default_value,
                    .data_type = new_type_id,
                });

                dt.kind = .{ .structure = fields.items };
            },
            .bitpack => |const_fields| {
                const base_field = loop: for (const_fields) |f| {
                    if (name_matches_pattern(f.name, field_pattern)) break :loop f;
                } else continue;
                const offset_bits = base_field.offset_bits;
                const end_offset_bits = offset_bits + new_dt.size_bits;

                var fields = try std.ArrayList(Data_Type.Packed_Field).initCapacity(command_alloc, const_fields.len + 1);

                var default_value: u64 = 0;
                for (const_fields) |f| {
                    const size_bits = group.data_types.items[f.data_type].size_bits;
                    if (f.offset_bits < end_offset_bits and f.offset_bits + size_bits > offset_bits) {
                        var default = f.default_value;
                        if (f.offset_bits > offset_bits) {
                            default = default << @intCast(f.offset_bits - offset_bits);
                        } else if (f.offset_bits < offset_bits) {
                            default = default >> @intCast(offset_bits - f.offset_bits);
                        }
                        default_value |= default;
                    } else {
                        fields.appendAssumeCapacity(f);
                    }
                }

                fields.appendAssumeCapacity(.{
                    .name = new_field_name,
                    .description = base_field.description,
                    .offset_bits = offset_bits,
                    .default_value = default_value,
                    .data_type = new_type_id,
                });

                dt.kind = .{ .bitpack = fields.items };
            },
        }
    }
}

fn field_create(group: *Peripheral_Group, types: []Data_Type, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    if (types.len == 0) {
        std.log.err("Expected at least one matching type", .{});
        return error.SExpressionSyntaxError;
    }

    switch (types[0].kind) {
        .bitpack => {
            const new_field = try parse_packed_field(group, 0, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .bitpack => |const_fields| {
                        const fields = try command_alloc.alloc(Data_Type.Packed_Field, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .bitpack = fields };
                    },
                    else => {
                        std.log.warn("Can't add a packed field to type '{s}' because it is not a bitpack!", .{ t.zig_name() });
                    },
                }
            }
        },
        .enumeration => {
            const new_field = try parse_enum_field(group, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .enumeration => |const_fields| {
                        const fields = try command_alloc.alloc(Data_Type.Enum_Field, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .enumeration = fields };
                    },
                    else => {
                        std.log.warn("Can't add an enum field to type '{s}' because it is not a enum!", .{ t.zig_name() });
                    },
                }
            }
        },
        .structure => {
            const new_field = try parse_struct_field(group, 0, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .structure => |const_fields| {
                        const fields = try command_alloc.alloc(Data_Type.Struct_Field, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .structure = fields };
                    },
                    else => {
                        std.log.warn("Can't add a struct field to type '{s}' because it is not a struct!", .{ t.zig_name() });
                    },
                }
            }
        },
        .alternative => {
            const new_field = try parse_union_field(group, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .alternative => |const_fields| {
                        const fields = try command_alloc.alloc(Data_Type.Union_Field, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .alternative = fields };
                    },
                    else => {
                        std.log.warn("Can't add a union field to type '{s}' because it is not a union!", .{ t.zig_name() });
                    },
                }
            }
        },
        .unsigned, .signed, .boolean, .anyopaque, .external, .register, .collection, .pointer => {
            std.log.err("Can't add a field to type '{s}'; expected union, struct, bitpack, or enum!", .{ types[0].zig_name() });
        },
    }
}

fn field_set_name(group: *Peripheral_Group, field_refs: []Field_Ref, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.maybe_dupe(try reader.require_any_string());
    for (field_refs) |ref| switch (ref) {
        .alternative => |f| f.name = new_name,
        .structure => |f| f.name = new_name,
        .bitpack => |f| f.name = new_name,
        .enumeration => |f| f.name = new_name,
    };
}

fn field_set_desc(group: *Peripheral_Group, field_refs: []Field_Ref, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_desc = try group.maybe_dupe(try reader.require_any_string());
    for (field_refs) |ref| switch (ref) {
        .alternative => |f| f.description = new_desc,
        .structure => |f| f.description = new_desc,
        .bitpack => |f| f.description = new_desc,
        .enumeration => |f| f.description = new_desc,
    };
}

fn field_set_offset(field_refs: []Field_Ref, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_offset = try reader.require_any_int(u32, 0);
    for (field_refs) |ref| switch (ref) {
        .alternative => {},
        .structure => |f| f.offset_bytes = new_offset,
        .bitpack => |f| f.offset_bits = new_offset,
        .enumeration => {},
    };
}

fn field_set_default_value(field_refs: []Field_Ref, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_default = try reader.require_any_int(u64, 0);
    for (field_refs) |ref| switch (ref) {
        .alternative => {},
        .structure => |f| f.default_value = new_default,
        .bitpack => |f| f.default_value = new_default,
        .enumeration => {},
    };
}

fn field_set_value(field_refs: []Field_Ref, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_value = try reader.require_any_int(u32, 0);
    for (field_refs) |ref| switch (ref) {
        .alternative, .structure, .bitpack => {},
        .enumeration => |f| f.value = new_value,
    };
}

fn field_type_set(group: *Peripheral_Group, field_refs: []Field_Ref, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const type_id = try type_create_or_ref(group, T, reader);
    for (field_refs) |ref| switch (ref) {
        .alternative => |f| f.data_type = type_id,
        .structure => |f| f.data_type = type_id,
        .bitpack => |f| f.data_type = type_id,
        .enumeration => {},
    };
}

fn field_type_modify(action_list: *Type_Action_List, group: *Peripheral_Group, field_refs: []Field_Ref, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const stop = action_list.len;
    const types = try collect_field_types(action_list, group, field_refs);
    try type_modify(action_list, group, types, T, reader);
    try finish_type_actions(group, action_list, stop);
}

fn name_matches_pattern(name: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '#')) |first_num| {
        if (!std.mem.startsWith(u8, name, pattern[0..first_num])) return false;
        var cropped_name = name[first_num..];
        while (cropped_name.len > 0 and std.ascii.isDigit(cropped_name[0])) {
            cropped_name = cropped_name[1..];
        }
        const cropped_pattern = pattern[first_num + 1 ..];
        return name_matches_pattern(cropped_name, cropped_pattern);
    } else if (std.mem.indexOfScalar(u8, pattern, '*')) |first_star| {
        if (!std.mem.startsWith(u8, name, pattern[0..first_star])) return false;
        return std.mem.endsWith(u8, name, pattern[first_star + 1 ..]);
    } else {
        return std.mem.eql(u8, name, pattern);
    }
}

const Peripheral_Iterator = struct {
    pattern: []const u8,
    group: *Peripheral_Group,
    next_index: usize = 0,

    fn init(group: *Peripheral_Group, pattern: []const u8) Peripheral_Iterator {
        return .{
            .pattern = pattern,
            .group = group,
        };
    }

    fn next(self: *Peripheral_Iterator) ?*Peripheral {
        const peripherals = self.group.peripherals.items;
        while (true) {
            const next_index = self.next_index;
            if (peripherals.len <= next_index) return null;

            const p = peripherals[next_index];
            self.next_index = next_index + 1;
            if (!p.deleted and name_matches_pattern(p.name, self.pattern)) {
                return &peripherals[next_index];
            }
        }
    }
};

fn collect_matching_peripheral_types(action_list: *Type_Action_List, group: *Peripheral_Group, peripheral_pattern: []const u8) ![]Data_Type {
    var types = std.AutoArrayHashMap(Data_Type.ID, Data_Type).init(command_alloc);

    var iter = Peripheral_Iterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        try types.put(peripheral.data_type, group.data_types.items[peripheral.data_type]);
    }

    // types must not be modified after this point; pointers to data within must remain stable until the Type_Action_List is processed.

    iter = Peripheral_Iterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        const id_ptr = types.getKeyPtr(peripheral.data_type).?;

        try action_list.append(command_alloc, .{ .set_type = .{
            .src_type_id = id_ptr,
            .dest_type_id = &peripheral.data_type,
        }});
    }

    const slice = types.unmanaged.entries.slice();
    const ids = slice.items(.key);
    const dts = slice.items(.value);
    for (ids, dts) |*id, *dt| {
        try action_list.append(command_alloc, .{ .resolve_type = .{
            .type_id = id,
            .data_type = dt,
        }});
    }

    return dts;
}

fn collect_inner_types(action_list: *Type_Action_List, group: *const Peripheral_Group, outer_types: []Data_Type) ![]Data_Type {
    var types = std.AutoArrayHashMap(Data_Type.ID, Data_Type).init(command_alloc);

    for (outer_types) |dt| switch (dt.kind) {
        .unsigned, .signed, .boolean, .anyopaque,
        .external, .alternative, .structure, .bitpack, .enumeration => {},
        .pointer => |info| {
            try types.put(info.data_type, group.data_types.items[info.data_type]);
        },
        .register => |info| {
            try types.put(info.data_type, group.data_types.items[info.data_type]);
        },
        .collection => |info| {
            try types.put(info.data_type, group.data_types.items[info.data_type]);
        },
    };

    // types must not be modified after this point; pointers to data within must remain stable until the Type_Action_List is processed.

    for (outer_types) |*dt| switch (dt.kind) {
        .unsigned, .signed, .boolean, .anyopaque,
        .external, .alternative, .structure, .bitpack, .enumeration => {},
        .pointer => |*info| {
            const id_ptr = types.getKeyPtr(info.data_type).?;
            try action_list.append(command_alloc, .{ .set_type = .{
                .src_type_id = id_ptr,
                .dest_type_id = &info.data_type,
            }});
        },
        .register => |*info| {
            const id_ptr = types.getKeyPtr(info.data_type).?;
            try action_list.append(command_alloc, .{ .set_type = .{
                .src_type_id = id_ptr,
                .dest_type_id = &info.data_type,
            }});
        },
        .collection => |*info| {
            const id_ptr = types.getKeyPtr(info.data_type).?;
            try action_list.append(command_alloc, .{ .set_type = .{
                .src_type_id = id_ptr,
                .dest_type_id = &info.data_type,
            }});
        },
    };

    const slice = types.unmanaged.entries.slice();
    const ids = slice.items(.key);
    const dts = slice.items(.value);
    for (ids, dts) |*id, *dt| {
        try action_list.append(command_alloc, .{ .resolve_type = .{
            .type_id = id,
            .data_type = dt,
        }});
    }

    return dts;
}

const Field_Ref = union(enum) {
    alternative: *Data_Type.Union_Field,
    structure: *Data_Type.Struct_Field,
    bitpack: *Data_Type.Packed_Field,
    enumeration: *Data_Type.Enum_Field,
};
fn collect_matching_fields(types: []Data_Type, field_pattern: []const u8) ![]Field_Ref {
    var refs = std.ArrayList(Field_Ref).init(command_alloc);

    for (types) |*dt| switch (dt.kind) {
        .unsigned, .signed, .boolean, .anyopaque,
        .external, .register, .collection, .pointer => {},
        .alternative => |const_fields| {
            const fields = try command_alloc.dupe(Data_Type.Union_Field, const_fields);
            for (fields) |*f| {
                if (name_matches_pattern(f.name, field_pattern)) {
                    try refs.append(.{ .alternative = f });
                    dt.kind = .{ .alternative = fields };
                }
            }
        },
        .structure => |const_fields| {
            const fields = try command_alloc.dupe(Data_Type.Struct_Field, const_fields);
            for (fields) |*f| {
                if (name_matches_pattern(f.name, field_pattern)) {
                    try refs.append(.{ .structure = f });
                    dt.kind = .{ .structure = fields };
                }
            }
        },
        .bitpack => |const_fields| {
            const fields = try command_alloc.dupe(Data_Type.Packed_Field, const_fields);
            for (fields) |*f| {
                if (name_matches_pattern(f.name, field_pattern)) {
                    try refs.append(.{ .bitpack = f });
                    dt.kind = .{ .bitpack = fields };
                }
            }
        },
        .enumeration => |const_fields| {
            const fields = try command_alloc.dupe(Data_Type.Enum_Field, const_fields);
            for (fields) |*f| {
                if (name_matches_pattern(f.name, field_pattern)) {
                    try refs.append(.{ .enumeration = f });
                    dt.kind = .{ .enumeration = fields };
                }
            }
        },
    };

    return refs.items;
}

fn collect_field_types(action_list: *Type_Action_List, group: *const Peripheral_Group, field_refs: []Field_Ref) ![]Data_Type {
    var types = std.AutoArrayHashMap(Data_Type.ID, Data_Type).init(command_alloc);

    for (field_refs) |ref| switch (ref) {
        .alternative => |f| try types.put(f.data_type, group.data_types.items[f.data_type]),
        .structure => |f| try types.put(f.data_type, group.data_types.items[f.data_type]),
        .bitpack => |f| try types.put(f.data_type, group.data_types.items[f.data_type]),
        .enumeration => {},
    };

    // types must not be modified after this point; pointers to data within must remain stable until the Type_Action_List is processed.

    for (field_refs) |ref| {
        const dest_ptr = switch (ref) {
            .alternative => |f| &f.data_type,
            .structure => |f| &f.data_type,
            .bitpack => |f| &f.data_type,
            .enumeration => continue,
        };
        const src_ptr = types.getKeyPtr(dest_ptr.*).?;

        try action_list.append(command_alloc, .{ .set_type = .{
            .src_type_id = src_ptr,
            .dest_type_id = dest_ptr,
        }});
    }

    const slice = types.unmanaged.entries.slice();
    const ids = slice.items(.key);
    const dts = slice.items(.value);
    for (ids, dts) |*id, *dt| {
        try action_list.append(command_alloc, .{ .resolve_type = .{
            .data_type = dt,
            .type_id = id,
        }});
    }
    return dts;
}

const Collect_Matching_Register_Types_Context = struct {
    action_list: *Type_Action_List,
    group: *const Peripheral_Group,
    register_pattern: []const u8,
    reg_types: std.AutoArrayHashMap(Data_Type.ID, Data_Type),
    containers: std.AutoArrayHashMap(Data_Type.ID, Data_Type),

    pub fn populate(self: *@This(), data_type: Data_Type, found_named_field: bool) !void {
        switch (data_type.kind) {
            .unsigned, .signed, .boolean, .anyopaque,
            .external, .enumeration, .bitpack => {},
            .register => |info| {
                if (found_named_field) {
                    try self.reg_types.put(info.data_type, self.group.data_types.items[info.data_type]);
                }
            },
            .pointer => |info| {
                const result = try self.containers.getOrPut(info.data_type);
                if (!result.found_existing) {
                    result.value_ptr.* = self.group.data_types.items[info.data_type];
                    try self.populate(result.value_ptr.*, found_named_field);
                }
            },
            .collection => |info| {
                const result = try self.containers.getOrPut(info.data_type);
                if (!result.found_existing) {
                    result.value_ptr.* = self.group.data_types.items[info.data_type];
                    try self.populate(result.value_ptr.*, found_named_field);
                }
            },
            .alternative => |fields| for (fields) |f| {
                const result = try self.containers.getOrPut(f.data_type);
                if (!result.found_existing) {
                    result.value_ptr.* = self.group.data_types.items[f.data_type];
                    try self.populate(result.value_ptr.*, found_named_field);
                }
            },
            .structure => |fields| for (fields) |f| {
                const found = found_named_field or name_matches_pattern(f.name, self.register_pattern);
                const result = try self.containers.getOrPut(f.data_type);
                if (!result.found_existing) {
                    result.value_ptr.* = self.group.data_types.items[f.data_type];
                }
                try self.populate(result.value_ptr.*, found);
            },
        }
    }

    // reg_types and containers must not be modified once this is called;
    // pointers to data within must remain stable until the Type_Action_List is processed.
    pub fn add_container_actions(self: *@This(), data_type: *Data_Type, found_named_field: bool) std.mem.Allocator.Error!void {
        switch (data_type.kind) {
            .unsigned, .signed, .boolean, .anyopaque,
            .external, .enumeration, .bitpack => {},
            .register => |*info| {
                if (found_named_field) {
                    const id_ptr = self.reg_types.getKeyPtr(info.data_type).?;
                    try self.action_list.append(command_alloc, .{ .set_type = .{
                        .src_type_id = id_ptr,
                        .dest_type_id = &info.data_type,
                    }});
                }
            },
            .pointer => |*info| {
                const entry = self.containers.getEntry(info.data_type).?;

                try self.action_list.append(command_alloc, .{ .set_type = .{
                    .src_type_id = entry.key_ptr,
                    .dest_type_id = &info.data_type,
                }});

                try self.action_list.append(command_alloc, .{ .resolve_type = .{
                    .data_type = entry.value_ptr,
                    .type_id = entry.key_ptr,
                }});

                try self.add_container_actions(entry.value_ptr, found_named_field);
            },
            .collection => |*info| {
                const entry = self.containers.getEntry(info.data_type).?;

                try self.action_list.append(command_alloc, .{ .set_type = .{
                    .src_type_id = entry.key_ptr,
                    .dest_type_id = &info.data_type,
                }});

                try self.action_list.append(command_alloc, .{ .resolve_type = .{
                    .data_type = entry.value_ptr,
                    .type_id = entry.key_ptr,
                }});

                try self.add_container_actions(entry.value_ptr, found_named_field);
            },
            .alternative => |fields| for (fields, 0..) |f, i| {
                const entry = self.containers.getEntry(f.data_type).?;

                try self.action_list.append(command_alloc, .{ .set_union_field_type = .{
                    .parent_type = data_type,
                    .field_index = @intCast(i),
                    .field_type = entry.key_ptr,
                }});

                try self.action_list.append(command_alloc, .{ .resolve_type = .{
                    .data_type = entry.value_ptr,
                    .type_id = entry.key_ptr,
                }});

                try self.add_container_actions(entry.value_ptr, found_named_field);
            },
            .structure => |fields| for (fields, 0..) |f, i| {
                const entry = self.containers.getEntry(f.data_type).?;

                try self.action_list.append(command_alloc, .{ .set_struct_field_type = .{
                    .parent_type = data_type,
                    .field_index = @intCast(i),
                    .field_type = entry.key_ptr,
                }});

                try self.action_list.append(command_alloc, .{ .resolve_type = .{
                    .data_type = entry.value_ptr,
                    .type_id = entry.key_ptr,
                }});

                try self.add_container_actions(entry.value_ptr, found_named_field or name_matches_pattern(f.name, self.register_pattern));
            },
        }
    }

    pub fn add_register_type_actions(self: *@This()) ![]Data_Type {
        const slice = self.reg_types.unmanaged.entries.slice();
        const ids = slice.items(.key);
        const types = slice.items(.value);
        for (ids, types) |*id, *dt| {
            try self.action_list.append(command_alloc, .{ .resolve_type = .{
                .data_type = dt,
                .type_id = id,
            }});
        }
        return types;
    }
};
fn collect_matching_register_types(action_list: *Type_Action_List, group: *const Peripheral_Group, peripheral_types: []Data_Type, register_pattern: []const u8) ![]Data_Type {
    var ctx = Collect_Matching_Register_Types_Context{
        .action_list = action_list,
        .group = group,
        .register_pattern = register_pattern,
        .reg_types = std.AutoArrayHashMap(Data_Type.ID, Data_Type).init(command_alloc),
        .containers = std.AutoArrayHashMap(Data_Type.ID, Data_Type).init(command_alloc),
    };

    for (peripheral_types) |dt| {
        try ctx.populate(dt, false);
    }

    for (peripheral_types) |*dt| {
        try ctx.add_container_actions(dt, false);
    }

    return try ctx.add_register_type_actions();
}

fn begin_type_actions() Type_Action_List {
    _ = command_arena.reset(.retain_capacity);
    return .{};
}

fn finish_type_actions(group: *Peripheral_Group, list: *Type_Action_List, stop_at: usize) !void {
    while (list.len > stop_at) switch (list.pop().?) {
        .resolve_type => |a| try a.run(group),
        .set_type => |a| try a.run(),
        .set_union_field_type => |a| try a.run(),
        .set_struct_field_type => |a| try a.run(),
        .set_packed_field_type => |a| try a.run(),
    };
}

const Type_Action_List = std.SegmentedList(Type_Action, 16);

const Type_Action = union(enum) {
    resolve_type: Resolve_Type,
    set_type: Set_Type,
    set_union_field_type: Set_Union_Field_Type,
    set_struct_field_type: Set_Struct_Field_Type,
    set_packed_field_type: Set_Packed_Field_Type,
};

const Resolve_Type = struct {
    type_id: *Data_Type.ID,
    data_type: *Data_Type,
    pub fn run(self: Resolve_Type, group: *Peripheral_Group) !void {
        self.type_id.* = try group.get_or_create_type(self.data_type.*, .{ .dupe_strings = false });
    }
};

const Set_Type = struct {
    dest_type_id: *Data_Type.ID,
    src_type_id: *Data_Type.ID,
    pub fn run(self: Set_Type) !void {
        self.dest_type_id.* = self.src_type_id.*;
    }
};

const Set_Union_Field_Type = struct {
    parent_type: *Data_Type,
    field_index: u32,
    field_type: *Data_Type.ID,
    pub fn run(self: Set_Union_Field_Type) !void {
        const field_index = self.field_index;
        const type_id = self.field_type.*;
        const old_fields = self.parent_type.kind.alternative;
        if (type_id != old_fields[field_index].data_type) {
            const new_fields = try command_alloc.dupe(Data_Type.Union_Field, old_fields);
            new_fields[field_index].data_type = type_id;
            self.parent_type.kind = .{ .alternative = new_fields };
        }
    }
};

const Set_Struct_Field_Type = struct {
    parent_type: *Data_Type,
    field_index: u32,
    field_type: *Data_Type.ID,
    pub fn run(self: Set_Struct_Field_Type) !void {
        const field_index = self.field_index;
        const type_id = self.field_type.*;
        const old_fields = self.parent_type.kind.structure;
        if (type_id != old_fields[field_index].data_type) {
            const new_fields = try command_alloc.dupe(Data_Type.Struct_Field, old_fields);
            new_fields[field_index].data_type = type_id;
            self.parent_type.kind = .{ .structure = new_fields };
        }
    }
};

const Set_Packed_Field_Type = struct {
    parent_type: *Data_Type,
    field_index: u32,
    field_type: *Data_Type.ID,
    pub fn run(self: Set_Packed_Field_Type) !void {
        const field_index = self.field_index;
        const type_id = self.field_type.*;
        const old_fields = self.parent_type.kind.bitpack;
        if (type_id != old_fields[field_index].data_type) {
            const new_fields = try command_alloc.dupe(Data_Type.Packed_Field, old_fields);
            new_fields[field_index].data_type = type_id;
            self.parent_type.kind = .{ .bitpack = new_fields };
        }
    }
};

const Database = @import("Database.zig");
const Peripheral = @import("Peripheral.zig");
const Peripheral_Group = @import("Peripheral_Group.zig");
const Data_Type = @import("Data_Type.zig");
const sx = @import("sx");
const std = @import("std");
