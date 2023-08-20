const std = @import("std");
const Database = @import("Database.zig");
const PeripheralGroup = @import("PeripheralGroup.zig");

const DataType = @This();

pub const ID = u32;

name: []const u8 = "",
fallback_name: []const u8 = "",
description: []const u8 = "",
size_bits: u32,
kind: Kind,
always_inline: bool = false,
ref_count: u32 = 0,

pub const Kind = union(enum) {
    unsigned,
    boolean,
    external: struct {
        import: []const u8,
    },
    register: struct {
        data_type: ID,
        access: AccessPolicy,
    },
    collection: struct {
        data_type: ID,
        count: u32,
    },
    alternative: []const UnionField,
    structure: []const StructField,
    bitpack: []const PackedField,
    enumeration: []const EnumField,
};

pub const AccessPolicy = enum { rw, r, w };

pub const UnionField = struct {
    name: []const u8,
    description: []const u8 = "",
    data_type: ID,
};

pub const StructField = struct {
    name: []const u8,
    description: []const u8 = "",
    offset_bytes: u32,
    data_type: ID,
    default_value: u64,

    pub fn lessThan(_: void, a: StructField, b: StructField) bool {
        return a.offset_bytes < b.offset_bytes;
    }
};

pub const PackedField = struct {
    name: []const u8,
    description: []const u8 = "",
    offset_bits: u32,
    data_type: ID,
    default_value: u64,

    pub fn lessThan(_: void, a: PackedField, b: PackedField) bool {
        return a.offset_bits < b.offset_bits;
    }
};

pub const EnumField = struct {
    name: []const u8,
    description: []const u8 = "",
    value: u32,

    pub fn lessThan(_: void, a: EnumField, b: EnumField) bool {
        return a.value < b.value;
    }
};

pub fn zigName(self: *const DataType) []const u8 {
    return if (self.name.len > 0) self.name else self.fallback_name;
}

pub fn isPackable(self: *DataType) bool {
    return switch (self.kind) {
        .unsigned,
        .boolean,
        .enumeration,
        .bitpack,
        => true,

        .external,
        .register,
        .collection,
        .alternative,
        .structure,
        => false,
    };
}

pub fn addRef(self: *DataType, group: *PeripheralGroup) void {
    if (self.ref_count == 0 or self.always_inline) switch (self.kind) {
        .unsigned, .boolean, .enumeration, .external => {},

        .register => |info| {
            group.data_types.items[info.data_type].addRef(group);
        },
        .collection => |info| {
            group.data_types.items[info.data_type].addRef(group);
        },
        .alternative => |fields| for (fields) |field| {
            group.data_types.items[field.data_type].addRef(group);
        },
        .structure => |fields| for (fields) |field| {
            group.data_types.items[field.data_type].addRef(group);
        },
        .bitpack => |fields| for (fields) |field| {
            group.data_types.items[field.data_type].addRef(group);
        },
    };
    self.ref_count += 1;
}

pub const DedupContext = struct {
    group: *const PeripheralGroup,

    pub fn hash(ctx: DedupContext, a: DataType) u64 {
        return DataType.hash(a, ctx.group.*);
    }
    pub fn eql(ctx: DedupContext, a: DataType, b: DataType) bool {
        return DataType.eql(a, ctx.group.*, b, ctx.group.*);
    }
};
pub const WithPeripheralGroup = struct {
    group: *const PeripheralGroup,
    data_type: *const DataType,
};
pub const AdaptedDedupContext = struct {
    group: *const PeripheralGroup,

    pub fn hash(_: AdaptedDedupContext, a: WithPeripheralGroup) u64 {
        return DataType.hash(a.data_type.*, a.group.*);
    }
    pub fn eql(ctx: AdaptedDedupContext, a: WithPeripheralGroup, b: DataType) bool {
        return DataType.eql(a.data_type.*, a.group.*, b, ctx.group.*);
    }
};

fn hash(self: DataType, group: PeripheralGroup) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(self.name);
    // fallback names are ignored.
    h.update(self.description);
    h.update(std.mem.asBytes(&self.always_inline));
    h.update(std.mem.asBytes(&self.size_bits));

    const tag = std.meta.activeTag(self.kind);
    h.update(std.mem.asBytes(&tag));

    switch (self.kind) {
        .unsigned, .boolean => {},
        .external => |info| h.update(info.import),
        .register => |info| {
            const dt_hash = hash(group.data_types.items[info.data_type], group);
            h.update(std.mem.asBytes(&dt_hash));
            h.update(std.mem.asBytes(&info.access));
        },
        .collection => |info| {
            const dt_hash = hash(group.data_types.items[info.data_type], group);
            h.update(std.mem.asBytes(&dt_hash));
            h.update(std.mem.asBytes(&info.count));
        },
        .alternative => |fields| for (fields) |f| {
            const dt_hash = hash(group.data_types.items[f.data_type], group);
            h.update(std.mem.asBytes(&dt_hash));
            h.update(f.name);
            h.update(f.description);
        },
        .structure => |fields| {
            var set_hash: u64 = 0;
            for (fields) |f| {
                var field_hash = std.hash.Wyhash.init(hash(group.data_types.items[f.data_type], group));
                field_hash.update(f.name);
                field_hash.update(f.description);
                field_hash.update(std.mem.asBytes(&f.offset_bytes));
                field_hash.update(std.mem.asBytes(&f.default_value));
                // Since fields may not be ordered canonically yet,
                // we need to ensure that the hash doesn't depend on field order:
                set_hash ^= field_hash.final();
            }
            h.update(std.mem.asBytes(&set_hash));
        },
        .bitpack => |fields| {
            var set_hash: u64 = 0;
            for (fields) |f| {
                var field_hash = std.hash.Wyhash.init(hash(group.data_types.items[f.data_type], group));
                field_hash.update(f.name);
                field_hash.update(f.description);
                field_hash.update(std.mem.asBytes(&f.offset_bits));
                field_hash.update(std.mem.asBytes(&f.default_value));
                // Since fields may not be ordered canonically yet,
                // we need to ensure that the hash doesn't depend on field order:
                set_hash ^= field_hash.final();
            }
            h.update(std.mem.asBytes(&set_hash));
        },
        .enumeration => |fields| {
            var set_hash: u64 = 0;
            for (fields) |f| {
                var field_hash = std.hash.Wyhash.init(0);
                field_hash.update(f.name);
                field_hash.update(f.description);
                field_hash.update(std.mem.asBytes(&f.value));
                // Since fields may not be ordered canonically yet,
                // we need to ensure that the hash doesn't depend on field order:
                set_hash ^= field_hash.final();
            }
            h.update(std.mem.asBytes(&set_hash));
        },
    }

    return h.final();
}
fn eql(a: DataType, a_src: PeripheralGroup, b: DataType, b_src: PeripheralGroup) bool {
    if (a.size_bits != b.size_bits) return false;
    if (a.always_inline != b.always_inline) return false;
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    // fallback names are ignored.
    if (!std.mem.eql(u8, a.description, b.description)) return false;

    if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
    switch (a.kind) {
        .unsigned, .boolean => {},
        .external => |a_info| {
            const b_info = b.kind.external;
            if (!std.mem.eql(u8, a_info.import, b_info.import)) return false;
        },
        .register => |a_info| {
            const b_info = b.kind.register;
            if (a_info.access != b_info.access) return false;
            if (!eql(a_src.data_types.items[a_info.data_type], a_src, b_src.data_types.items[b_info.data_type], b_src)) return false;
        },
        .collection => |a_info| {
            const b_info = b.kind.collection;
            if (a_info.count != b_info.count) return false;
            if (!eql(a_src.data_types.items[a_info.data_type], a_src, b_src.data_types.items[b_info.data_type], b_src)) return false;
        },
        .alternative => |a_fields| {
            const b_fields = b.kind.alternative;
            if (a_fields.len != b_fields.len) return false;
            for (a_fields, b_fields) |af, bf| {
                if (!std.mem.eql(u8, af.name, bf.name)) return false;
                if (!std.mem.eql(u8, af.description, bf.description)) return false;
                if (!eql(a_src.data_types.items[af.data_type], a_src, b_src.data_types.items[bf.data_type], b_src)) return false;
            }
        },
        .structure => |a_fields| {
            const b_fields = b.kind.structure;
            if (a_fields.len != b_fields.len) return false;
            found_matching_field: for (a_fields) |af| {
                for (b_fields) |bf| {
                    if (af.offset_bytes != bf.offset_bytes) continue;
                    if (af.default_value != bf.default_value) continue;
                    if (!std.mem.eql(u8, af.name, bf.name)) continue;
                    if (!std.mem.eql(u8, af.description, bf.description)) continue;
                    if (!eql(a_src.data_types.items[af.data_type], a_src, b_src.data_types.items[bf.data_type], b_src)) continue;
                    continue :found_matching_field;
                }
                return false;
            }
        },
        .bitpack => |a_fields| {
            const b_fields = b.kind.bitpack;
            if (a_fields.len != b_fields.len) return false;
            found_matching_field: for (a_fields) |af| {
                for (b_fields) |bf| {
                    if (af.offset_bits != bf.offset_bits) continue;
                    if (af.default_value != bf.default_value) continue;
                    if (!std.mem.eql(u8, af.name, bf.name)) continue;
                    if (!std.mem.eql(u8, af.description, bf.description)) continue;
                    if (!eql(a_src.data_types.items[af.data_type], a_src, b_src.data_types.items[bf.data_type], b_src)) continue;
                    continue :found_matching_field;
                }
                return false;
            }
        },
        .enumeration => |a_fields| {
            const b_fields = b.kind.enumeration;
            if (a_fields.len != b_fields.len) return false;
            found_matching_field: for (a_fields) |af| {
                for (b_fields) |bf| {
                    if (af.value != bf.value) continue;
                    if (!std.mem.eql(u8, af.name, bf.name)) continue;
                    if (!std.mem.eql(u8, af.description, bf.description)) continue;
                    continue :found_matching_field;
                }
                return false;
            }
        },
    }
    return true;
}
