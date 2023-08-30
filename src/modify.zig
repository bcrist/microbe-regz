const std = @import("std");
const sx = @import("sx-reader");
const Database = @import("Database.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");
const DataType = @import("DataType.zig");

var command_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const command_alloc = command_arena.allocator();

fn E(comptime T: type) type {
    return T.Error || std.mem.Allocator.Error || error {
        SExpressionSyntaxError,
        EndOfStream,
        NamedTypeCollision,
        NoSpaceLeft,
        PeripheralGroupMissing,
    };
}

const GroupOp = enum {
    nop,
    peripheral,
    create_peripheral,
    create_type,
    copy_type,
};
const group_ops = std.ComptimeStringMap(GroupOp, .{
    .{ "--", .nop },
    .{ "peripheral", .peripheral },
    .{ "create-peripheral", .create_peripheral },
    .{ "create-type", .create_type },
    .{ "copy-type", .copy_type },
});
pub fn handleSx(db: *Database, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    defer _ = command_arena.reset(.free_all);

    while (try reader.expression("--")) {
        try reader.ignoreRemainingExpression();
    }

    while (try reader.expression("group")) {
        var group_name = try reader.requireAnyString();
        var group = try db.findOrCreatePeripheralGroup(group_name);
        group_name = group.name;

        while (try reader.open()) {
            switch (try reader.requireMapEnum(GroupOp, group_ops)) {
                .nop => {
                    try reader.ignoreRemainingExpression();
                    continue;
                },
                .peripheral => {
                    try peripheralModify(db, group, T, reader);
                    // move-to-group may have caused db.groups to be resized,
                    // so we need to make sure our group pointer is updated:
                    group = try db.findOrCreatePeripheralGroup(group_name);
                },
                .create_peripheral => try peripheralCreate(group, T, reader),
                .create_type => try typeCreateNamed(group, T, reader),
                .copy_type => try typeCopy(group, T, reader),
            }
            try reader.requireClose();
        }

        try reader.requireClose();
    }

    while (try reader.expression("--")) {
        try reader.ignoreRemainingExpression();
    }

    try reader.requireDone();
}

const CreatePeripheralOp = enum {
    nop,
    base_address,
    set_type,
};
const create_peripheral_ops = std.ComptimeStringMap(CreatePeripheralOp, .{
    .{ "--", .nop },
    .{ "base", .base_address },
    .{ "type", .set_type },
});
fn peripheralCreate(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const name = try group.maybeDupe(try reader.requireAnyString());
    const description = try group.maybeDupe(try reader.anyString());
    var base_address: u64 = 0;

    var data_type = try group.getOrCreateType(.{
        .size_bits = 0,
        .kind = .{ .structure = &.{} }, 
    }, .{});

    while (try reader.open()) {
        switch (try reader.requireMapEnum(CreatePeripheralOp, create_peripheral_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .base_address => base_address = try reader.requireAnyInt(u64, 0),
            .set_type => data_type = try typeCreateOrRef(group, T, reader),
        }
        try reader.requireClose();
    }

    var dt = group.data_types.items[data_type];
    if (dt.fallback_name.len == 0) {
        dt.fallback_name = name;
        data_type = try group.getOrCreateType(dt, .{ .dupe_strings = false });
    }

    const peripheral = try group.createPeripheral(name, base_address, data_type);
    peripheral.description = description;
}

const PeripheralOp = enum {
    nop,
    rename,
    delete,
    move_to_group,
    @"type",
    register,
    set_type,
};
const peripheral_ops = std.ComptimeStringMap(PeripheralOp, .{
    .{ "--", .nop },
    .{ "rename", .rename },
    .{ "delete", .delete },
    .{ "move-to-group", .move_to_group },
    .{ "type", .@"type" },
    .{ "reg", .register },
    .{ "set-type", .set_type },
});
fn peripheralModify(db: *Database, original_group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const peripheral_pattern = try db.gpa.dupe(u8, try reader.requireAnyString());
    defer db.gpa.free(peripheral_pattern);

    var group = original_group;

    while (try reader.open()) {
        switch (try reader.requireMapEnum(PeripheralOp, peripheral_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .rename => try peripheralRename(group, peripheral_pattern, T, reader),
            .delete => try peripheralDelete(group, peripheral_pattern),
            .move_to_group => group = try peripheralMoveToGroup(db, group.name, peripheral_pattern, T, reader),
            .@"type" => try peripheralTypeModify(group, peripheral_pattern, T, reader),
            .register => try peripheralRegisterModify(group, peripheral_pattern, T, reader),
            .set_type => try peripheralSetType(group, peripheral_pattern, T, reader),
        }
        try reader.requireClose();
    }
}

fn peripheralRename(group: *PeripheralGroup, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.arena.dupe(u8, try reader.requireAnyString());

    var iter = PeripheralIterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        std.log.debug("Renaming peripheral {s}.{s} => {s}", .{
            group.name,
            peripheral.name,
            new_name,
        });
        peripheral.name = new_name;
    }
}

fn peripheralDelete(group: *PeripheralGroup, peripheral_pattern: []const u8) !void {
    var iter = PeripheralIterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        std.log.debug("Deleting peripheral {s}.{s}", .{
            group.name,
            peripheral.name,
        });
        peripheral.deleted = true;
    }
}

// Note any ops in the peripheral after the move-to-group will use the new group as context, so we need to return it.
fn peripheralMoveToGroup(db: *Database, src_group_name: []const u8, peripheral_pattern: []const u8, comptime T:type, reader: *sx.Reader(T)) E(T)!*PeripheralGroup {
    const dest_group_name = try reader.requireAnyString();

    var new_group = try db.findOrCreatePeripheralGroup(dest_group_name);
    var old_group = try db.findPeripheralGroup(src_group_name);

    if (new_group != old_group) {
        var iter = PeripheralIterator {
            .pattern = peripheral_pattern,
            .group = old_group,
        };
        while (iter.next()) |peripheral| {
            std.log.debug("Moving peripheral {s}.{s} to group {s}", .{
                old_group.name,
                peripheral.name,
                new_group.name,
            });
            _ = try new_group.clonePeripheral(old_group, peripheral.*);
            peripheral.deleted = true;
        }
    }

    return new_group;
}

fn peripheralTypeModify(group: *PeripheralGroup, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    var action_list = beginTypeActions();
    const types = try collectMatchingPeripheralTypes(&action_list, group, peripheral_pattern);
    try typeModify(&action_list, group, types, T, reader);
    try finishTypeActions(group, &action_list, 0);
}

fn peripheralRegisterModify(group: *PeripheralGroup, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const register_pattern = try group.gpa.dupe(u8, try reader.requireAnyString());
    defer group.gpa.free(register_pattern);

    var action_list = beginTypeActions();
    const types = try collectMatchingPeripheralTypes(&action_list, group, peripheral_pattern);
    const reg_types = try collectMatchingRegisterTypes(&action_list, group, types, register_pattern);
    try typeModify(&action_list, group, reg_types, T, reader);
    try finishTypeActions(group, &action_list, 0);
}

fn peripheralSetType(group: *PeripheralGroup, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const type_id = try typeCreateOrRef(group, T, reader);
    var iter = PeripheralIterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        peripheral.data_type = type_id;
    }
}

fn typeCopy(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    var id = (try typeRef(group, T, reader)) orelse return error.SExpressionSyntaxError;
    var types: [1]DataType = .{ group.data_types.items[id] };
    types[0].name = try group.maybeDupe(try reader.requireAnyString());

    var action_list = beginTypeActions();
    try typeModify(&action_list, group, &types, T, reader);
    try finishTypeActions(group, &action_list, 0);
    _ = try group.getOrCreateType(types[0], .{ .dupe_strings = false });
}

fn typeCreateNamed(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const name = try group.maybeDupe(try reader.requireAnyString());
    const desc = try group.maybeDupe(try reader.anyString());
    _ = try typeCreate(group, name, desc, T, reader);
}

fn typeCreateOrRef(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.ID {
    return (try typeRef(group, T, reader)) orelse try typeCreate(group, "", "", T, reader);
}

fn typeRef(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!?DataType.ID {
    reader.setPeek(true);
    if (try reader.anyString()) |name| {
        reader.setPeek(false);
        if (try group.findType(name)) |id| {
            try reader.any();
            return id;
        } else {
            return error.SExpressionSyntaxError;
        }
    }
    reader.setPeek(false);
    return null;
}

const CreateTypeOp = enum {
    nop,
    name,
    fallback_name,
    description,
    size_bits,
    external,
    register,
    collection,
    alternative,
    structure,
    bitpack,
    enumeration,
    set_inline,
};
const create_type_ops = std.ComptimeStringMap(CreateTypeOp, .{
    .{ "--", .nop },
    .{ "name", .name },
    .{ "fallback_name", .fallback_name },
    .{ "description", .description },
    .{ "bits", .size_bits },
    .{ "ext", .external },
    .{ "reg", .register },
    .{ "array", .collection },
    .{ "union", .alternative },
    .{ "struct", .structure },
    .{ "packed", .bitpack },
    .{ "enum", .enumeration },
    .{ "inline", .set_inline },
});
fn typeCreate(group: *PeripheralGroup, default_name: []const u8, default_desc: []const u8, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.ID {
    var dt = DataType{
        .name = default_name,
        .description = default_desc,
        .size_bits = 0,
        .kind = .unsigned,
    };

    while (try reader.open()) {
        switch (try reader.requireMapEnum(CreateTypeOp, create_type_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .name => dt.name = try group.maybeDupe(try reader.requireAnyString()),
            .fallback_name => dt.fallback_name = try group.maybeDupe(try reader.requireAnyString()),
            .description => dt.description = try group.maybeDupe(try reader.requireAnyString()),
            .size_bits => dt.size_bits = try reader.requireAnyInt(u32, 0),
            .set_inline => dt.inline_mode = try reader.requireAnyEnum(DataType.InlineMode),
            .external => {
                const import = try group.maybeDupe(try reader.requireAnyString());
                var maybe_from_int = try reader.anyString();
                if (maybe_from_int) |from_int| {
                    maybe_from_int = try group.maybeDupe(from_int);
                }
                dt.kind = .{ .external = .{
                    .import = import,
                    .from_int = maybe_from_int,
                }};
                dt.inline_mode = .never;
            },
            .register => {
                dt.kind = try typeKindRegister(group, T, reader);
                if (dt.size_bits == 0) {
                    dt.size_bits = group.data_types.items[dt.kind.register.data_type].size_bits;
                }
                dt.inline_mode = .always;
            },
            .collection => {
                dt.kind = try typeKindCollection(group, T, reader);
                if (dt.size_bits == 0) {
                    const info = dt.kind.collection;
                    dt.size_bits = ((group.data_types.items[info.data_type].size_bits + 7) / 8) * info.count * 8;
                }
                dt.inline_mode = .always;
            },
            .alternative => {
                dt.kind = try typeKindAlternative(group, T, reader);
                if (dt.size_bits == 0) {
                    var max_bits: u32 = 0;
                    for (dt.kind.alternative) |f| {
                        max_bits = @max(max_bits, group.data_types.items[f.data_type].size_bits);
                    }
                    dt.size_bits = max_bits;
                }
            },
            .structure => {
                dt.kind = try typeKindStructure(group, T, reader);
                if (dt.size_bits == 0) {
                    var bytes: u32 = 0;
                    for (dt.kind.structure) |f| {
                        bytes += (group.data_types.items[f.data_type].size_bits + 7) / 8;
                    }
                    dt.size_bits = bytes * 8;
                }
            },
            .bitpack => {
                dt.kind = try typeKindBitpack(group, T, reader);
                if (dt.size_bits == 0) {
                    var bits: u32 = 0;
                    for (dt.kind.bitpack) |f| {
                        bits += group.data_types.items[f.data_type].size_bits;
                    }
                    dt.size_bits = bits;
                }
            },
            .enumeration => {
                dt.kind = try typeKindEnumeration(group, T, reader);
                if (dt.size_bits == 0) {
                    var max_val: u32 = 1;
                    for (dt.kind.enumeration) |f| {
                        max_val = @max(max_val, f.value);
                    }
                    dt.size_bits = std.math.log2_int(u32, max_val) + 1;
                }
            },
        }
        try reader.requireClose();
    }

    return group.getOrCreateType(dt, .{ .dupe_strings = false });
}

fn typeKindRegister(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.Kind {
    const access = (try reader.anyEnum(DataType.AccessPolicy)) orelse .rw;
    const inner_type = try typeCreateOrRef(group, T, reader);
    return .{ .register = .{
        .access = access,
        .data_type = inner_type,
    }};
}

fn typeKindCollection(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.Kind {
    const count = try reader.requireAnyInt(u32, 0);
    const inner_type = try typeCreateOrRef(group, T, reader);
    return .{ .collection = .{
        .count = count,
        .data_type = inner_type,
    }};
}

fn typeKindAlternative(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.Kind {
    var fields = std.ArrayList(DataType.UnionField).init(command_alloc);

    while (true) {
        if (try reader.expression("--")) {
            try reader.ignoreRemainingExpression();
        } else if (try reader.open()) {
            const field = try parseUnionField(group, T, reader);
            try reader.requireClose();
            try fields.append(field);
        } else break;
    }
    return .{ .alternative = fields.items };
}
const ParseUnionFieldOp = enum {
    nop,
    set_type,
};
const parse_union_field_ops = std.ComptimeStringMap(ParseUnionFieldOp, .{
    .{ "--", .nop },
    .{ "type", .set_type },
});
fn parseUnionField(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.UnionField {
    const name = try group.maybeDupe(try reader.requireAnyString());
    const description = try group.maybeDupe(try reader.anyString());
    var data_type = try group.getOrCreateBool();

    while (try reader.open()) {
        switch (try reader.requireMapEnum(ParseUnionFieldOp, parse_union_field_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .set_type => data_type = try typeCreateOrRef(group, T, reader),
        }
        try reader.requireClose();
    }

    return .{
        .name = name,
        .description = description,
        .data_type = data_type,
    };
}


fn typeKindStructure(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.Kind {
    var fields = std.ArrayList(DataType.StructField).init(command_alloc);

    var default_offset_bytes: u32 = 0;
    while (true) {
        if (try reader.expression("--")) {
            try reader.ignoreRemainingExpression();
        } else if (try reader.open()) {
            const field = try parseStructField(group, default_offset_bytes, T, reader);
            try reader.requireClose();
            try fields.append(field);
            const dt = group.data_types.items[field.data_type];
            default_offset_bytes = field.offset_bytes + (dt.size_bits + 7) / 8;
        } else break;
    }
    return .{ .structure = fields.items };
}
const ParseStructFieldOp = enum {
    nop,
    offset_bytes,
    default_value,
    set_type,
};
const parse_struct_field_ops = std.ComptimeStringMap(ParseStructFieldOp, .{
    .{ "--", .nop },
    .{ "offset", .offset_bytes },
    .{ "default", .default_value },
    .{ "type", .set_type },
});
fn parseStructField(group: *PeripheralGroup, default_offset_bytes: u32, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.StructField {
    const name = try group.maybeDupe(try reader.requireAnyString());
    const description = try group.maybeDupe(try reader.anyString());
    var offset_bytes = default_offset_bytes;
    var default_value: u64 = 0;
    var data_type = try group.getOrCreateBool();

    while (try reader.open()) {
        switch (try reader.requireMapEnum(ParseStructFieldOp, parse_struct_field_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .offset_bytes => offset_bytes = try reader.requireAnyInt(u32, 0),
            .default_value => default_value = try reader.requireAnyInt(u64, 0),
            .set_type => data_type = try typeCreateOrRef(group, T, reader),
        }
        try reader.requireClose();
    }

    return .{
        .name = name,
        .description = description,
        .offset_bytes = offset_bytes,
        .data_type = data_type,
        .default_value = default_value,
    };
}

fn typeKindBitpack(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.Kind {
    var fields = std.ArrayList(DataType.PackedField).init(command_alloc);

    var default_offset_bits: u32 = 0;
    while (true) {
        if (try reader.expression("--")) {
            try reader.ignoreRemainingExpression();
        } else if (try reader.open()) {
            const field = try parsePackedField(group, default_offset_bits, T, reader);
            try reader.requireClose();
            try fields.append(field);
            const dt = group.data_types.items[field.data_type];
            default_offset_bits = field.offset_bits + dt.size_bits;
        } else break;
    }
    return .{ .bitpack = fields.items };
}
const ParsePackedFieldOp = enum {
    nop,
    offset_bits,
    default_value,
    set_type,
};
const parse_packed_field_ops = std.ComptimeStringMap(ParsePackedFieldOp, .{
    .{ "--", .nop },
    .{ "offset", .offset_bits },
    .{ "default", .default_value },
    .{ "type", .set_type },
});
fn parsePackedField(group: *PeripheralGroup, default_offset_bits: u32, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.PackedField {
    const name = try group.maybeDupe(try reader.requireAnyString());
    const description = try group.maybeDupe(try reader.anyString());
    var offset_bits = default_offset_bits;
    var default_value: u64 = 0;
    var data_type = try group.getOrCreateBool();

    while (try reader.open()) {
        switch (try reader.requireMapEnum(ParsePackedFieldOp, parse_packed_field_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .offset_bits => offset_bits = try reader.requireAnyInt(u32, 0),
            .default_value => default_value = try reader.requireAnyInt(u64, 0),
            .set_type => data_type = try typeCreateOrRef(group, T, reader),
        }
        try reader.requireClose();
    }

    return .{
        .name = name,
        .description = description,
        .offset_bits = offset_bits,
        .data_type = data_type,
        .default_value = default_value,
    };
}

fn typeKindEnumeration(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.Kind {
    var fields = std.ArrayList(DataType.EnumField).init(command_alloc);

    while (true) {
        if (try reader.expression("--")) {
            try reader.ignoreRemainingExpression();
        } else if (try reader.open()) {
            try fields.append(try parseEnumField(group, T, reader));
            try reader.requireClose();
        } else break;
    }
    return .{ .enumeration = fields.items };
}
fn parseEnumField(group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) E(T)!DataType.EnumField {
    const value = try reader.requireAnyInt(u32, 0);
    const name = try group.maybeDupe(try reader.requireAnyString());
    const description = try group.maybeDupe(try reader.anyString());
    return .{
        .name = name,
        .description = description,
        .value = value,
    };
}

const ModifyTypeOp = enum {
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
const modify_type_ops = std.ComptimeStringMap(ModifyTypeOp, .{
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
fn typeModify(action_list: *TypeActionList, group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    while (try reader.open()) {
        switch (try reader.requireMapEnum(ModifyTypeOp, modify_type_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .set_name => try typeSetName(group, types, T, reader),
            .set_fallback_name => try typeSetFallbackName(group, types, T, reader),
            .set_desc => try typeSetDescription(group, types, T, reader),
            .set_bits => try typeSetBits(types, T, reader),
            .set_access => try typeSetAccess(types, T, reader),
            .inner => try typeModifyInner(action_list, group, types, T, reader),
            .field => try fieldModify(action_list, group, types, T, reader),
            .delete_field => try fieldDelete(types, T, reader),
            .merge_field => try fieldMerge(group, types, T, reader),
            .create_field => try fieldCreate(group, types, T, reader),
        }
        try reader.requireClose();
    }
}

fn typeSetName(group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.maybeDupe(try reader.requireAnyString());
    for (types) |*dt| {
        dt.name = new_name;
    }
}

fn typeSetFallbackName(group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.maybeDupe(try reader.requireAnyString());
    for (types) |*dt| {
        dt.fallback_name = new_name;
    }
}

fn typeSetDescription(group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_desc = try group.maybeDupe(try reader.requireAnyString());
    for (types) |*dt| {
        dt.description = new_desc;
    }
}

fn typeSetBits(types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const bits = try reader.requireAnyInt(u32, 0);
    for (types) |*dt| {
        dt.size_bits = bits;
    }
}

fn typeSetAccess(types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const access = try reader.requireAnyEnum(DataType.AccessPolicy);
    for (types) |*dt| {
        switch (dt.kind) {
            .register => |*info| {
                info.access = access;
            },
            else => {},
        }
    }
}

fn typeModifyInner(action_list: *TypeActionList, group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const stop = action_list.len;
    const reg_types = try collectInnerTypes(action_list, group, types);
    try typeModify(action_list, group, reg_types, T, reader);
    try finishTypeActions(group, action_list, stop);
}

const ModifyFieldOp = enum {
    nop,
    set_name,
    set_desc,
    set_offset,
    set_default,
    set_value,
    @"type",
    set_type,
};
const modify_field_ops = std.ComptimeStringMap(ModifyFieldOp, .{
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
fn fieldModify(action_list: *TypeActionList, group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const field_pattern = try group.gpa.dupe(u8, try reader.requireAnyString());
    defer group.gpa.free(field_pattern);

    const field_refs = try collectMatchingFields(types, field_pattern);

    while (try reader.open()) {
        switch (try reader.requireMapEnum(ModifyFieldOp, modify_field_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .set_name => try fieldSetName(group, field_refs, T, reader),
            .set_desc => try fieldSetDesc(group, field_refs, T, reader),
            .set_offset => try fieldSetOffset(field_refs, T, reader),
            .set_value => try fieldSetValue(field_refs, T, reader),
            .set_default => try fieldSetDefaultValue(field_refs, T, reader),
            .set_type => try fieldTypeSet(group, field_refs, T, reader),
            .@"type" => try fieldTypeModify(action_list, group, field_refs, T, reader),
        }
        try reader.requireClose();
    }
}

fn fieldDelete(types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const field_pattern = try reader.requireAnyString();

    for (types) |*dt| {
        switch (dt.kind) {
            .unsigned, .boolean, .external, .register, .collection => {},
            .alternative => |const_fields| {
                var fields = try std.ArrayList(DataType.UnionField).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!nameMatchesPattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .alternative = fields.items };
            },
            .structure => |const_fields| {
                var fields = try std.ArrayList(DataType.StructField).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!nameMatchesPattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .structure = fields.items };
            },
            .bitpack => |const_fields| {
                var fields = try std.ArrayList(DataType.PackedField).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!nameMatchesPattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .bitpack = fields.items };
            },
            .enumeration => |const_fields| {
                var fields = try std.ArrayList(DataType.EnumField).initCapacity(command_alloc, const_fields.len);
                for (const_fields) |f| {
                    if (!nameMatchesPattern(f.name, field_pattern)) {
                        fields.appendAssumeCapacity(f);
                    }
                }
                dt.kind = .{ .enumeration = fields.items };
            },
        }
    }
}

fn fieldMerge(group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const field_pattern = try group.gpa.dupe(u8, try reader.requireAnyString());
    defer group.gpa.free(field_pattern);

    const new_field_name = try group.maybeDupe(try reader.requireAnyString());
    const new_type_id = try typeCreateOrRef(group, T, reader);

    const new_dt = group.data_types.items[new_type_id];

    for (types) |*dt| {
        switch (dt.kind) {
            .unsigned, .boolean, .external, .register, .collection, .alternative, .enumeration => {},
            .structure => |const_fields| {
                const base_field = loop: for (const_fields) |f| {
                    if (nameMatchesPattern(f.name, field_pattern)) break :loop f;
                } else continue;
                const offset_bytes = base_field.offset_bytes;
                const end_offset_bytes = offset_bytes + (new_dt.size_bits + 7) / 8;

                var fields = try std.ArrayList(DataType.StructField).initCapacity(command_alloc, const_fields.len);

                var default_value: u64 = 0;
                for (const_fields) |f| {
                    const size_bytes = (group.data_types.items[f.data_type].size_bits + 7) / 8;
                    if (f.offset_bytes < end_offset_bytes and f.offset_bytes + size_bytes > offset_bytes) {
                        var default = f.default_value;
                        if (f.offset_bytes > offset_bytes) {
                            default = default << @intCast((f.offset_bytes - offset_bytes) * 8);
                        } else if (f.offset_bytes < offset_bytes) {
                            default = default >> @intCast((offset_bytes - f.offset_bytes) * 8);
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
                    if (nameMatchesPattern(f.name, field_pattern)) break :loop f;
                } else continue;
                const offset_bits = base_field.offset_bits;
                const end_offset_bits = offset_bits + new_dt.size_bits;

                var fields = try std.ArrayList(DataType.PackedField).initCapacity(command_alloc, const_fields.len);

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

fn fieldCreate(group: *PeripheralGroup, types: []DataType, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    if (types.len == 0) {
        std.log.err("Expected at least one matching type", .{});
        return error.SExpressionSyntaxError;
    }

    switch (types[0].kind) {
        .bitpack => {
            const new_field = try parsePackedField(group, 0, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .bitpack => |const_fields| {
                        const fields = try command_alloc.alloc(DataType.PackedField, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .bitpack = fields };
                    },
                    else => {
                        std.log.warn("Can't add a packed field to type '{s}' because it is not a bitpack!", .{ t.zigName() });
                    },
                }
            }
        },
        .enumeration => {
            const new_field = try parseEnumField(group, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .enumeration => |const_fields| {
                        const fields = try command_alloc.alloc(DataType.EnumField, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .enumeration = fields };
                    },
                    else => {
                        std.log.warn("Can't add an enum field to type '{s}' because it is not a enum!", .{ t.zigName() });
                    },
                }
            }
        },
        .structure => {
            const new_field = try parseStructField(group, 0, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .structure => |const_fields| {
                        const fields = try command_alloc.alloc(DataType.StructField, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .structure = fields };
                    },
                    else => {
                        std.log.warn("Can't add a struct field to type '{s}' because it is not a struct!", .{ t.zigName() });
                    },
                }
            }
        },
        .alternative => {
            const new_field = try parseUnionField(group, T, reader);
            for (types) |*t| {
                switch (t.kind) {
                    .alternative => |const_fields| {
                        const fields = try command_alloc.alloc(DataType.UnionField, const_fields.len + 1);
                        @memcpy(fields.ptr, const_fields);
                        fields[fields.len - 1] = new_field;
                        t.kind = .{ .alternative = fields };
                    },
                    else => {
                        std.log.warn("Can't add a union field to type '{s}' because it is not a union!", .{ t.zigName() });
                    },
                }
            }
        },
        .unsigned, .boolean, .external, .register, .collection => {
            std.log.err("Can't add a field to type '{s}'; expected union, struct, bitpack, or enum!", .{ types[0].zigName() });
        },
    }
}

fn fieldSetName(group: *PeripheralGroup, field_refs: []FieldRef, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_name = try group.maybeDupe(try reader.requireAnyString());
    for (field_refs) |ref| switch (ref) {
        .alternative => |f| f.name = new_name,
        .structure => |f| f.name = new_name,
        .bitpack => |f| f.name = new_name,
        .enumeration => |f| f.name = new_name,
    };
}

fn fieldSetDesc(group: *PeripheralGroup, field_refs: []FieldRef, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_desc = try group.maybeDupe(try reader.requireAnyString());
    for (field_refs) |ref| switch (ref) {
        .alternative => |f| f.description = new_desc,
        .structure => |f| f.description = new_desc,
        .bitpack => |f| f.description = new_desc,
        .enumeration => |f| f.description = new_desc,
    };
}

fn fieldSetOffset(field_refs: []FieldRef, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_offset = try reader.requireAnyInt(u32, 0);
    for (field_refs) |ref| switch (ref) {
        .alternative => {},
        .structure => |f| f.offset_bytes = new_offset,
        .bitpack => |f| f.offset_bits = new_offset,
        .enumeration => {},
    };
}

fn fieldSetDefaultValue(field_refs: []FieldRef, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_default = try reader.requireAnyInt(u64, 0);
    for (field_refs) |ref| switch (ref) {
        .alternative => {},
        .structure => |f| f.default_value = new_default,
        .bitpack => |f| f.default_value = new_default,
        .enumeration => {},
    };
}

fn fieldSetValue(field_refs: []FieldRef, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const new_value = try reader.requireAnyInt(u32, 0);
    for (field_refs) |ref| switch (ref) {
        .alternative, .structure, .bitpack => {},
        .enumeration => |f| f.value = new_value,
    };
}

fn fieldTypeSet(group: *PeripheralGroup, field_refs: []FieldRef, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const type_id = try typeCreateOrRef(group, T, reader);
    for (field_refs) |ref| switch (ref) {
        .alternative => |f| f.data_type = type_id,
        .structure => |f| f.data_type = type_id,
        .bitpack => |f| f.data_type = type_id,
        .enumeration => {},
    };
}

fn fieldTypeModify(action_list: *TypeActionList, group: *PeripheralGroup, field_refs: []FieldRef, comptime T: type, reader: *sx.Reader(T)) E(T)!void {
    const stop = action_list.len;
    const types = try collectFieldTypes(action_list, group, field_refs);
    try typeModify(action_list, group, types, T, reader);
    try finishTypeActions(group, action_list, stop);
}

fn nameMatchesPattern(name: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '#')) |first_num| {
        if (!std.mem.startsWith(u8, name, pattern[0..first_num])) return false;
        var cropped_name = name[first_num..];
        while (cropped_name.len > 0 and std.ascii.isDigit(cropped_name[0])) {
            cropped_name = cropped_name[1..];
        }
        const cropped_pattern = pattern[first_num + 1 ..];
        return nameMatchesPattern(cropped_name, cropped_pattern);
    } else if (std.mem.indexOfScalar(u8, pattern, '*')) |first_star| {
        if (!std.mem.startsWith(u8, name, pattern[0..first_star])) return false;
        return std.mem.endsWith(u8, name, pattern[first_star + 1 ..]);
    } else {
        return std.mem.eql(u8, name, pattern);
    }
}

const PeripheralIterator = struct {
    pattern: []const u8,
    group: *PeripheralGroup,
    next_index: usize = 0,

    fn init(group: *PeripheralGroup, pattern: []const u8) PeripheralIterator {
        return .{
            .pattern = pattern,
            .group = group,
        };
    }

    fn next(self: *PeripheralIterator) ?*Peripheral {
        const peripherals = self.group.peripherals.items;
        while (true) {
            const next_index = self.next_index;
            if (peripherals.len <= next_index) return null;

            const p = peripherals[next_index];
            self.next_index = next_index + 1;
            if (!p.deleted and nameMatchesPattern(p.name, self.pattern)) {
                return &peripherals[next_index];
            }
        }
    }
};

fn collectMatchingPeripheralTypes(action_list: *TypeActionList, group: *PeripheralGroup, peripheral_pattern: []const u8) ![]DataType {
    var types = std.AutoArrayHashMap(DataType.ID, DataType).init(command_alloc);

    var iter = PeripheralIterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        try types.put(peripheral.data_type, group.data_types.items[peripheral.data_type]);
    }

    // types must not be modified after this point; pointers to data within must remain stable until the TypeActionList is processed.

    iter = PeripheralIterator.init(group, peripheral_pattern);
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

fn collectInnerTypes(action_list: *TypeActionList, group: *const PeripheralGroup, outer_types: []DataType) ![]DataType {
    var types = std.AutoArrayHashMap(DataType.ID, DataType).init(command_alloc);

    for (outer_types) |dt| switch (dt.kind) {
        .unsigned, .boolean, .external, .alternative, .structure, .bitpack, .enumeration => {},
        .register => |info| {
            try types.put(info.data_type, group.data_types.items[info.data_type]);
        },
        .collection => |info| {
            try types.put(info.data_type, group.data_types.items[info.data_type]);
        },
    };

    // types must not be modified after this point; pointers to data within must remain stable until the TypeActionList is processed.

    for (outer_types) |*dt| switch (dt.kind) {
        .unsigned, .boolean, .external, .alternative, .structure, .bitpack, .enumeration => {},
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

const FieldRef = union(enum) {
    alternative: *DataType.UnionField,
    structure: *DataType.StructField,
    bitpack: *DataType.PackedField,
    enumeration: *DataType.EnumField,
};
fn collectMatchingFields(types: []DataType, field_pattern: []const u8) ![]FieldRef {
    var refs = std.ArrayList(FieldRef).init(command_alloc);

    for (types) |*dt| switch (dt.kind) {
        .unsigned, .boolean, .external, .register, .collection => {},
        .alternative => |const_fields| {
            const fields = try command_alloc.dupe(DataType.UnionField, const_fields);
            for (fields) |*f| {
                if (nameMatchesPattern(f.name, field_pattern)) {
                    try refs.append(.{ .alternative = f });
                    dt.kind = .{ .alternative = fields };
                }
            }
        },
        .structure => |const_fields| {
            const fields = try command_alloc.dupe(DataType.StructField, const_fields);
            for (fields) |*f| {
                if (nameMatchesPattern(f.name, field_pattern)) {
                    try refs.append(.{ .structure = f });
                    dt.kind = .{ .structure = fields };
                }
            }
        },
        .bitpack => |const_fields| {
            const fields = try command_alloc.dupe(DataType.PackedField, const_fields);
            for (fields) |*f| {
                if (nameMatchesPattern(f.name, field_pattern)) {
                    try refs.append(.{ .bitpack = f });
                    dt.kind = .{ .bitpack = fields };
                }
            }
        },
        .enumeration => |const_fields| {
            const fields = try command_alloc.dupe(DataType.EnumField, const_fields);
            for (fields) |*f| {
                if (nameMatchesPattern(f.name, field_pattern)) {
                    try refs.append(.{ .enumeration = f });
                    dt.kind = .{ .enumeration = fields };
                }
            }
        },
    };

    return refs.items;
}

fn collectFieldTypes(action_list: *TypeActionList, group: *const PeripheralGroup, field_refs: []FieldRef) ![]DataType {
    var types = std.AutoArrayHashMap(DataType.ID, DataType).init(command_alloc);

    for (field_refs) |ref| switch (ref) {
        .alternative => |f| try types.put(f.data_type, group.data_types.items[f.data_type]),
        .structure => |f| try types.put(f.data_type, group.data_types.items[f.data_type]),
        .bitpack => |f| try types.put(f.data_type, group.data_types.items[f.data_type]),
        .enumeration => {},
    };

    // types must not be modified after this point; pointers to data within must remain stable until the TypeActionList is processed.

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

const CollectMatchingRegisterTypesContext = struct {
    action_list: *TypeActionList,
    group: *const PeripheralGroup,
    register_pattern: []const u8,
    reg_types: std.AutoArrayHashMap(DataType.ID, DataType),
    containers: std.AutoArrayHashMap(DataType.ID, DataType),

    pub fn populate(self: *@This(), data_type: DataType, found_named_field: bool) !void {
        switch (data_type.kind) {
            .unsigned, .boolean, .external, .enumeration, .bitpack => {},
            .register => |info| {
                if (found_named_field) {
                    try self.reg_types.put(info.data_type, self.group.data_types.items[info.data_type]);
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
                const found = found_named_field or nameMatchesPattern(f.name, self.register_pattern);
                const result = try self.containers.getOrPut(f.data_type);
                if (!result.found_existing) {
                    result.value_ptr.* = self.group.data_types.items[f.data_type];
                }
                try self.populate(result.value_ptr.*, found);
            },
        }
    }

    // reg_types and containers must not be modified once this is called;
    // pointers to data within must remain stable until the TypeActionList is processed.
    pub fn addContainerActions(self: *@This(), data_type: *DataType, found_named_field: bool) std.mem.Allocator.Error!void {
        switch (data_type.kind) {
            .unsigned, .boolean, .external, .enumeration, .bitpack => {},
            .register => |*info| {
                if (found_named_field) {
                    const id_ptr = self.reg_types.getKeyPtr(info.data_type).?;
                    try self.action_list.append(command_alloc, .{ .set_type = .{
                        .src_type_id = id_ptr,
                        .dest_type_id = &info.data_type,
                    }});
                }
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

                try self.addContainerActions(entry.value_ptr, found_named_field);
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

                try self.addContainerActions(entry.value_ptr, found_named_field);
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

                try self.addContainerActions(entry.value_ptr, found_named_field or nameMatchesPattern(f.name, self.register_pattern));
            },
        }
    }

    pub fn addRegisterTypeActions(self: *@This()) ![]DataType {
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
fn collectMatchingRegisterTypes(action_list: *TypeActionList, group: *const PeripheralGroup, peripheral_types: []DataType, register_pattern: []const u8) ![]DataType {
    var ctx = CollectMatchingRegisterTypesContext{
        .action_list = action_list,
        .group = group,
        .register_pattern = register_pattern,
        .reg_types = std.AutoArrayHashMap(DataType.ID, DataType).init(command_alloc),
        .containers = std.AutoArrayHashMap(DataType.ID, DataType).init(command_alloc),
    };

    for (peripheral_types) |dt| {
        try ctx.populate(dt, false);
    }

    for (peripheral_types) |*dt| {
        try ctx.addContainerActions(dt, false);
    }

    return try ctx.addRegisterTypeActions();
}

fn beginTypeActions() TypeActionList {
    _ = command_arena.reset(.retain_capacity);
    return .{};
}

fn finishTypeActions(group: *PeripheralGroup, list: *TypeActionList, stop_at: usize) !void {
    while (list.len > stop_at) switch (list.pop().?) {
        .resolve_type => |a| try a.run(group),
        .set_type => |a| try a.run(),
        .set_union_field_type => |a| try a.run(),
        .set_struct_field_type => |a| try a.run(),
        .set_packed_field_type => |a| try a.run(),
    };
}

const TypeActionList = std.SegmentedList(TypeAction, 16);

const TypeAction = union(enum) {
    resolve_type: ResolveType,
    set_type: SetType,
    set_union_field_type: SetUnionFieldType,
    set_struct_field_type: SetStructFieldType,
    set_packed_field_type: SetPackedFieldType,
};

const ResolveType = struct {
    type_id: *DataType.ID,
    data_type: *DataType,
    pub fn run(self: ResolveType, group: *PeripheralGroup) !void {
        self.type_id.* = try group.getOrCreateType(self.data_type.*, .{ .dupe_strings = false });
    }
};

const SetType = struct {
    dest_type_id: *DataType.ID,
    src_type_id: *DataType.ID,
    pub fn run(self: SetType) !void {
        self.dest_type_id.* = self.src_type_id.*;
    }
};

const SetUnionFieldType = struct {
    parent_type: *DataType,
    field_index: u32,
    field_type: *DataType.ID,
    pub fn run(self: SetUnionFieldType) !void {
        const field_index = self.field_index;
        const type_id = self.field_type.*;
        const old_fields = self.parent_type.kind.alternative;
        if (type_id != old_fields[field_index].data_type) {
            const new_fields = try command_alloc.dupe(DataType.UnionField, old_fields);
            new_fields[field_index].data_type = type_id;
            self.parent_type.kind = .{ .alternative = new_fields };
        }
    }
};

const SetStructFieldType = struct {
    parent_type: *DataType,
    field_index: u32,
    field_type: *DataType.ID,
    pub fn run(self: SetStructFieldType) !void {
        const field_index = self.field_index;
        const type_id = self.field_type.*;
        const old_fields = self.parent_type.kind.structure;
        if (type_id != old_fields[field_index].data_type) {
            const new_fields = try command_alloc.dupe(DataType.StructField, old_fields);
            new_fields[field_index].data_type = type_id;
            self.parent_type.kind = .{ .structure = new_fields };
        }
    }
};

const SetPackedFieldType = struct {
    parent_type: *DataType,
    field_index: u32,
    field_type: *DataType.ID,
    pub fn run(self: SetPackedFieldType) !void {
        const field_index = self.field_index;
        const type_id = self.field_type.*;
        const old_fields = self.parent_type.kind.bitpack;
        if (type_id != old_fields[field_index].data_type) {
            const new_fields = try command_alloc.dupe(DataType.PackedField, old_fields);
            new_fields[field_index].data_type = type_id;
            self.parent_type.kind = .{ .bitpack = new_fields };
        }
    }
};
