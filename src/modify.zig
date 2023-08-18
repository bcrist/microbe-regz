const std = @import("std");
const sx = @import("sx-reader");
const Database = @import("Database.zig");
const Peripheral = @import("Peripheral.zig");
const PeripheralType = @import("PeripheralType.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");
const Register = @import("Register.zig");
const DataType = @import("DataType.zig");

const GroupOp = enum {
    nop,
    peripheral,
    create_enum,
    create_packed,
    create_peripheral,
};
const group_ops = std.ComptimeStringMap(GroupOp, .{
    .{ "--", .nop },
    .{ "peripheral", .peripheral },
    .{ "create-enum", .create_enum },
    .{ "create-packed", .create_packed },
    .{ "create-peripheral", .create_peripheral },
});
pub fn parseAndApplySx(db: *Database, comptime T: type, reader: *sx.Reader(T)) !void {
    while (try reader.expression("--")) {
        try reader.ignoreRemainingExpression();
    }

    while (try reader.expression("group")) {
        var group_name = try reader.requireAnyString();

        var group = try db.getPeripheralGroup(.{
            .name = group_name,
            .description = "",
            .separate_file = true,
        });

        group_name = group.name;

        while (try reader.open()) {
            switch (try reader.requireMapEnum(GroupOp, group_ops)) {
                .nop => {
                    try reader.ignoreRemainingExpression();
                    continue;
                },
                .peripheral => {
                    try parseAndApplyPeripheral(db, group, T, reader);
                    // move-to-group may have caused db.groups to be resized,
                    // so we need to make sure our group pointer is updated:
                    group = try db.getPeripheralGroup(.{
                        .name = group_name,
                        .description = "",
                        .separate_file = true,
                    });
                },
                .create_enum => try parseAndApplyCreateEnum(db.*, group, T, reader),
                .create_packed => try parseAndApplyCreatePacked(db.*, group, T, reader),
                .create_peripheral => try parseAndApplyCreatePeripheral(db.*, group, T, reader),
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

const PeripheralOp = enum {
    nop,
    rename,
    register,
    move_to_group,
    set_typename,
    delete,
};
const peripheral_ops = std.ComptimeStringMap(PeripheralOp, .{
    .{ "--", .nop },
    .{ "rename", .rename },
    .{ "reg", .register },
    .{ "move-to-group", .move_to_group },
    .{ "set-typename", .set_typename },
    .{ "delete", .delete },
});
fn parseAndApplyPeripheral(db: *Database, original_group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) !void {
    const peripheral_pattern = try db.gpa.dupe(u8, try reader.requireAnyString());
    defer db.gpa.free(peripheral_pattern);

    var group = original_group;

    while (try reader.open()) {
        switch (try reader.requireMapEnum(PeripheralOp, peripheral_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .register => try parseAndApplyRegister(db.*, group, peripheral_pattern, T, reader),
            .move_to_group => group = try parseAndApplyMoveToGroup(db, group.name, peripheral_pattern, T, reader),
            .rename => try parseAndApplyPeripheralRename(db.*, group, peripheral_pattern, T, reader),
            .set_typename => try parseAndApplyPeripheralSetTypename(db.*, group, peripheral_pattern, T, reader),
            .delete => try parseAndApplyPeripheralDelete(db.*, group, peripheral_pattern, T, reader),
        }
        try reader.requireClose();
    }
}

fn parseAndApplyPeripheralDelete(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    _ = reader;
    _ = db;
    var iter = PeripheralIterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        std.log.debug("Deleting peripheral {s}.{s}", .{
            group.name,
            peripheral.name,
        });
        peripheral.deleted = true;
    }
}

fn parseAndApplyPeripheralRename(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    const new_name = try db.arena.dupe(u8, try reader.requireAnyString());

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

fn parseAndApplyPeripheralSetTypename(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    const new_name = try db.arena.dupe(u8, try reader.requireAnyString());

    var iter = PeripheralIterator.init(group, peripheral_pattern);
    while (iter.next()) |peripheral| {
        std.log.debug("Setting peripheral typename for {s}.{s}: {s} => {s}", .{
            group.name,
            iter.current().?.name,
            group.peripheral_types.items[peripheral.peripheral_type].name,
            new_name,
        });
        group.peripheral_types.items[peripheral.peripheral_type].name = new_name;
    }
}

const RegisterOp = enum {
    nop,
    type,
    rename,
};
const register_ops = std.ComptimeStringMap(RegisterOp, .{
    .{ "--", .nop },
    .{ "type", .type },
    .{ "rename", .rename },
});
fn parseAndApplyRegister(db: Database, group: *PeripheralGroup, peripheral_pattern: []const u8, comptime T: type, reader: *sx.Reader(T)) !void {
    const register_pattern = try db.gpa.dupe(u8, try reader.requireAnyString());
    defer db.gpa.free(register_pattern);

    while (try reader.open()) {
        switch (try reader.requireMapEnum(RegisterOp, register_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .type => try parseAndApplyRegisterType(db, group, peripheral_pattern, register_pattern, T, reader),
            .rename => try parseAndApplyRegisterRename(db, group, peripheral_pattern, register_pattern, T, reader),
        }
        try reader.requireClose();
    }
}

fn parseAndApplyRegisterRename(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    const new_name = try db.arena.dupe(u8, try reader.requireAnyString());

    var iter = RegisterIterator.init(group, peripheral_pattern, register_pattern);
    while (iter.next()) |reg| {
        std.log.debug("Renaming register {s}.{s}.{s} => {s}", .{
            group.name,
            iter.peripheral_iter.current().?.name,
            reg.name,
            new_name,
        });
        reg.name = new_name;
    }
}

const RegisterTypeOp = enum {
    nop,
    field,
    rename,
};
const register_type_ops = std.ComptimeStringMap(RegisterTypeOp, .{
    .{ "--", .nop },
    .{ "field", .field },
    .{ "rename", .rename },
});
fn parseAndApplyRegisterType(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    while (try reader.open()) {
        switch (try reader.requireMapEnum(RegisterTypeOp, register_type_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .field => try parseAndApplyRegisterField(db, group, peripheral_pattern, register_pattern, T, reader),
            .rename => try parseAndApplyRegisterTypeRename(db, group, peripheral_pattern, register_pattern, T, reader),
        }
        try reader.requireClose();
    }
}

fn parseAndApplyRegisterTypeRename(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    const new_name = try db.arena.dupe(u8, try reader.requireAnyString());

    var iter = RegisterIterator.init(group, peripheral_pattern, register_pattern);
    while (iter.next()) |reg| {
        std.log.debug("Renaming register type {s}.{s}.{s}: {s} => {s}", .{
            group.name,
            iter.peripheral_iter.current().?.name,
            iter.current().?.name,
            group.data_types.items[reg.data_type].name,
            new_name,
        });
        group.data_types.items[reg.data_type].name = new_name;
    }
}


const RegisterFieldOp = enum {
    nop,
    rename,
    delete,
    set_type,
    set_description,
};
const register_field_ops = std.ComptimeStringMap(RegisterFieldOp, .{
    .{ "--", .nop },
    .{ "set-type", .set_type },
    .{ "set-desc", .set_description },
    .{ "rename", .rename },
    .{ "delete", .delete },
});
fn parseAndApplyRegisterField(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    const field_pattern = try db.gpa.dupe(u8, try reader.requireAnyString());
    defer db.gpa.free(field_pattern);

    while (try reader.open()) {
        switch (try reader.requireMapEnum(RegisterFieldOp, register_field_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .rename => try parseAndApplyRegisterFieldRename(db, group, peripheral_pattern, register_pattern, field_pattern, T, reader),
            .delete => try parseAndApplyRegisterFieldDelete(db, group, peripheral_pattern, register_pattern, field_pattern, T, reader),
            .set_type => try parseAndApplyRegisterFieldSetType(db, group, peripheral_pattern, register_pattern, field_pattern, T, reader),
            .set_description => try parseAndApplyRegisterFieldSetDescription(db, group, peripheral_pattern, register_pattern, field_pattern, T, reader),
        }
        try reader.requireClose();
    }
}

fn parseAndApplyRegisterFieldRename(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    field_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    const new_name = try db.arena.dupe(u8, try reader.requireAnyString());

    var iter = PackedFieldIterator.init(group, peripheral_pattern, register_pattern, field_pattern);
    while (iter.next()) |field| {
        std.log.debug("Renaming register packed field {s}.{s}.{s}.{s} => {s}", .{
            group.name,
            iter.register_iter.peripheral_iter.current().?.name,
            iter.register_iter.current().?.name,
            field.name,
            new_name,
        });
        field.name = new_name;
    }
}

fn parseAndApplyRegisterFieldDelete(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    field_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    _ = reader;
    _ = db;
    var iter = PackedFieldIterator.init(group, peripheral_pattern, register_pattern, field_pattern);
    while (iter.next()) |field| {
        std.log.debug("Deleting register packed field {s}.{s}.{s}.{s}", .{
            group.name,
            iter.register_iter.peripheral_iter.current().?.name,
            iter.register_iter.current().?.name,
            field.name,
        });
        field.deleted = true;
    }
}

fn parseAndApplyRegisterFieldSetType(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    field_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    reader.peekNext();
    const data_type = try group.findType(db, try reader.requireAnyString()) orelse return error.SExpressionSyntaxError;
    reader.any();

    var iter = PackedFieldIterator.init(group, peripheral_pattern, register_pattern, field_pattern);
    while (iter.next()) |field| {
        const copied_type = try group.copyType(db, group.*, data_type);
        std.log.debug("Setting register packed field {s}.{s}.{s}.{s} to type {s}", .{
            group.name,
            iter.register_iter.peripheral_iter.current().?.name,
            iter.register_iter.current().?.name,
            field.name,
            group.data_types.items[copied_type].name,
        });
        field.data_type = copied_type;
    }
}

fn parseAndApplyRegisterFieldSetDescription(
    db: Database,
    group: *PeripheralGroup,
    peripheral_pattern: []const u8,
    register_pattern: []const u8,
    field_pattern: []const u8,
    comptime T: type, reader: *sx.Reader(T)
) !void {
    const new_desc = try db.arena.dupe(u8, try reader.requireAnyString());

    var iter = PackedFieldIterator.init(group, peripheral_pattern, register_pattern, field_pattern);
    while (iter.next()) |field| {
        std.log.debug("Setting register packed field description {s}.{s}.{s}.{s} to {s}", .{
            group.name,
            iter.register_iter.peripheral_iter.current().?.name,
            iter.register_iter.current().?.name,
            field.name,
            new_desc,
        });
        field.description = new_desc;
    }
}

// Note any ops in the peripheral after the move-to-group will use the new group as context, so we need to return it.
fn parseAndApplyMoveToGroup(db: *Database, src_group_name: []const u8, peripheral_pattern: []const u8, comptime T:type, reader: *sx.Reader(T)) !*PeripheralGroup {
    const dest_group_name = try reader.requireAnyString();

    var new_group = try db.getPeripheralGroup(.{
        .name = dest_group_name,
        .description = "",
        .separate_file = true,
    });

    var old_group = try db.getPeripheralGroup(.{
        .name = src_group_name,
        .description = "",
        .separate_file = true,
    });

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
            try new_group.copyPeripheral(db.*, old_group.*, peripheral.*,
                peripheral.name,
                peripheral.description,
                peripheral.offset_bytes,
                peripheral.count
            );
            peripheral.deleted = true;
        }
    }

    return new_group;
}

const CreateEnumOp = enum {
    nop,
    bits,
    value,
};
const create_enum_ops = std.ComptimeStringMap(CreateEnumOp, .{
    .{ "--", .nop },
    .{ "bits", .bits },
    .{ "value", .value },
});
fn parseAndApplyCreateEnum(db: Database, group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) !void {
    const name = try reader.requireAnyString();
    const type_id = try group.createEnumType(db, name, null, 1, &.{});
    const data_type = &group.data_types.items[type_id];

    if (try reader.anyString()) |desc| {
        data_type.description = try db.arena.dupe(u8, desc);
    }

    while (try reader.open()) {
        switch (try reader.requireMapEnum(CreateEnumOp, create_enum_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .bits => {
                data_type.size_bits = try reader.requireAnyInt(u32, 0);
            },
            .value => {
                try data_type.kind.@"enum".append(db.gpa, try parseEnumField(db, T, reader));
            },
        }
        try reader.requireClose();
    }
}

fn parseEnumField(db: Database, comptime T: type, reader: *sx.Reader(T)) !DataType.EnumField {
    const value = try reader.requireAnyInt(u32, 0);
    const name = try db.arena.dupe(u8, try reader.requireAnyString());
    const maybe_description = try reader.anyString();
    const description = if (maybe_description) |desc| try db.arena.dupe(u8, desc) else "";

    return .{
        .name = name,
        .description = description,
        .value = value,
    };
}

const CreatePackedOp = enum {
    nop,
    bits,
    field,
};
const create_packed_ops = std.ComptimeStringMap(CreatePackedOp, .{
    .{ "--", .nop },
    .{ "bits", .bits },
    .{ "field", .field },
});

fn parseAndApplyCreatePacked(db: Database, group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) !void {
    const name = try reader.requireAnyString();
    const type_id = try group.createPackedType(db, name, null, 1, &.{});
    const data_type = &group.data_types.items[type_id];

    if (try reader.anyString()) |desc| {
        data_type.description = try db.arena.dupe(u8, desc);
    }

    var default_offset_bits: u32 = 0;
    while (try reader.open()) {
        switch (try reader.requireMapEnum(CreatePackedOp, create_packed_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .bits => {
                data_type.size_bits = try reader.requireAnyInt(u32, 0);
            },
            .field => {
                const field = try parsePackedField(db, group, default_offset_bits, T, reader);
                try data_type.kind.@"packed".append(db.gpa, field);
                const field_data_type = group.data_types.items[field.data_type];
                default_offset_bits = field.offset_bits + field_data_type.size_bits;
            },
        }
        try reader.requireClose();
    }
}

const CreatePackedFieldOp = enum {
    nop,
    offset_bits,
    default_value,
};
const create_packed_field_ops = std.ComptimeStringMap(CreatePackedFieldOp, .{
    .{ "--", .nop },
    .{ "offset", .offset_bits },
    .{ "default", .default_value },
});
fn parsePackedField(db: Database, group: *PeripheralGroup, default_offset_bits: u32, comptime T: type, reader: *sx.Reader(T)) !DataType.PackedField {
    const name = try db.arena.dupe(u8, try reader.requireAnyString());

    reader.peekNext();
    const data_type = try group.findType(db, try reader.requireAnyString()) orelse return error.SExpressionSyntaxError;
    reader.any();

    const maybe_description = try reader.anyString();
    const description = if (maybe_description) |desc| try db.arena.dupe(u8, desc) else "";
    var offset_bits = default_offset_bits;
    var default_value: u64 = 0;

    while (try reader.open()) {
        switch (try reader.requireMapEnum(CreatePackedFieldOp, create_packed_field_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .offset_bits => offset_bits = try reader.requireAnyInt(u32, 0),
            .default_value => default_value = try reader.requireAnyInt(u64, 0),
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

const CreatePeripheralOp = enum {
    nop,
    offset,
    reg,
};
const create_peripheral_ops = std.ComptimeStringMap(CreatePeripheralOp, .{
    .{ "--", .nop },
    .{ "offset", .offset },
    .{ "reg", .reg },
});
fn parseAndApplyCreatePeripheral(db: Database, group: *PeripheralGroup, comptime T: type, reader: *sx.Reader(T)) !void {
    const name = try db.arena.dupe(u8, try reader.requireAnyString());
    const maybe_description = try reader.anyString();
    const description = if (maybe_description) |desc| try db.arena.dupe(u8, desc) else "";

    var offset: u64 = 0;
    var count: u32 = 1;

    var registers = std.ArrayListUnmanaged(Register) {};

    var default_offset_bytes: u32 = 0;
    while (try reader.open()) {
        switch (try reader.requireMapEnum(CreatePeripheralOp, create_peripheral_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .offset => offset = try reader.requireAnyInt(u64, 0),
            .reg => {
                const register = try parseCreateRegister(db, group, default_offset_bytes, T, reader);
                try registers.append(db.gpa, register);
                const register_data_type = group.data_types.items[register.data_type];
                default_offset_bytes = register.offset_bytes + register_data_type.size_bits;
            },
        }
        try reader.requireClose();
    }

    const type_id: PeripheralType.ID = @intCast(group.peripheral_types.items.len);
    try group.peripheral_types.append(db.gpa, .{
        .name = name,
        .description = description,
        .registers = registers,
    });

    try group.peripherals.append(db.gpa, .{
        .name = name,
        .description = description,
        .offset_bytes = offset,
        .count = count,
        .peripheral_type = type_id,
    });
}

const CreateRegisterOp = enum {
    nop,
    access,
    offset,
};
const create_register_ops = std.ComptimeStringMap(CreateRegisterOp, .{
    .{ "--", .nop },
    .{ "access", .access },
    .{ "offset", .offset },
});
fn parseCreateRegister(db: Database, group: *PeripheralGroup, default_offset_bytes: u32, comptime T: type, reader: *sx.Reader(T)) !Register {
    const name = try db.arena.dupe(u8, try reader.requireAnyString());

    reader.peekNext();
    const data_type = try group.findType(db, try reader.requireAnyString()) orelse return error.SExpressionSyntaxError;
    reader.any();

    const maybe_description = try reader.anyString();
    const description = if (maybe_description) |desc| try db.arena.dupe(u8, desc) else "";

    var offset_bytes = default_offset_bytes;
    var access: Register.AccessPolicy = .@"read-write";
    var reset_value: u64 = 0;
    var reset_mask = ~reset_value;

    while (try reader.open()) {
        switch (try reader.requireMapEnum(CreateRegisterOp, create_register_ops)) {
            .nop => {
                try reader.ignoreRemainingExpression();
                continue;
            },
            .offset => offset_bytes = try reader.requireAnyInt(u32, 0),
            .access => access = try reader.requireAnyEnum(Register.AccessPolicy),
        }
        try reader.requireClose();
    }

    return .{
        .name = name,
        .description = description,
        .offset_bytes = offset_bytes,
        .reset_value = reset_value,
        .reset_mask = reset_mask,
        .data_type = data_type,
        .access = access,
    };
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

    fn current(self: PeripheralIterator) ?*Peripheral {
        const next_index = self.next_index;
        if (next_index == 0) {
            return null;
        } else {
            return &self.group.peripherals.items[next_index - 1];
        }
    }
};

const RegisterIterator = struct {
    peripheral_iter: PeripheralIterator,
    pattern: []const u8,
    remaining: []Register = &.{},
    current_register: ?*Register = null,

    fn init(group: *PeripheralGroup, peripheral_pattern: []const u8, register_pattern: []const u8) RegisterIterator {
        return .{
            .peripheral_iter = PeripheralIterator.init(group, peripheral_pattern),
            .pattern = register_pattern,
        };
    }

    fn next(self: *RegisterIterator) ?*Register {
        while (true) {
            while (self.remaining.len == 0) {
                if (self.peripheral_iter.next()) |peripheral| {
                    self.remaining = self.peripheral_iter.group.peripheral_types.items[peripheral.peripheral_type].registers.items;
                } else {
                    return null;
                }
            }

            const remaining = self.remaining;
            self.remaining = remaining[1..];
            const register = &remaining[0];
            if (nameMatchesPattern(register.name, self.pattern)) {
                self.current_register = register;
                return register;
            }
        }
    }

    fn current(self: RegisterIterator) ?*Register {
        return self.current_register;
    }
};

const PackedFieldIterator = struct {
    register_iter: RegisterIterator,
    pattern: []const u8,
    remaining: []DataType.PackedField = &.{},
    current_field: ?*DataType.PackedField = null,

    fn init(group: *PeripheralGroup, peripheral_pattern: []const u8, register_pattern: []const u8, field_pattern: []const u8) PackedFieldIterator {
        return .{
            .register_iter = RegisterIterator.init(group, peripheral_pattern, register_pattern),
            .pattern = field_pattern,
        };
    }

    fn next(self: *PackedFieldIterator) ?*DataType.PackedField {
        while (true) {
            while (self.remaining.len == 0) {
                if (self.register_iter.next()) |reg| {
                    const group = self.register_iter.peripheral_iter.group;
                    switch (group.data_types.items[reg.data_type].kind) {
                        .@"packed" => |fields| {
                            self.remaining = fields.items;
                        },
                        else => {}
                    }
                } else {
                    return null;
                }
            }

            const remaining = self.remaining;
            self.remaining = remaining[1..];
            const field = &remaining[0];
            if (nameMatchesPattern(field.name, self.pattern)) {
                self.current_field = field;
                return field;
            }
        }
    }

    fn current(self: PackedFieldIterator) ?*DataType.PackedField {
        return self.current_field;
    }
};
