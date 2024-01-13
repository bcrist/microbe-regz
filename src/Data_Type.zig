name: []const u8 = "",
fallback_name: []const u8 = "",
description: []const u8 = "",
size_bits: u32,
kind: Kind,
inline_mode: Inline_Mode = .auto,
ref_count: u32 = 0,

pub const ID = u32;

pub const Kind = union(enum) {
    unsigned,
    signed,
    boolean,
    anyopaque,
    pointer: struct {
        data_type: ID,
        constant: bool,
        allow_zero: bool,
    },
    external: struct {
        import: []const u8,
        from_int: ?[]const u8 = null,
    },
    register: struct {
        data_type: ID,
        access: Access_Policy,
    },
    collection: struct {
        data_type: ID,
        count: u32,
    },
    alternative: []const Union_Field,
    structure: []const Struct_Field,
    bitpack: []const Packed_Field,
    enumeration: []const Enum_Field,
};

pub const Inline_Mode = enum { auto, always, never };
pub const Access_Policy = enum { rw, r, w };

pub const Union_Field = struct {
    name: []const u8,
    description: []const u8 = "",
    data_type: ID,
};

pub const Struct_Field = struct {
    name: []const u8,
    description: []const u8 = "",
    offset_bytes: u32,
    data_type: ID,
    default_value: u64,

    pub fn less_than(_: void, a: Struct_Field, b: Struct_Field) bool {
        return a.offset_bytes < b.offset_bytes;
    }
};

pub const Packed_Field = struct {
    name: []const u8,
    description: []const u8 = "",
    offset_bits: u32,
    data_type: ID,
    default_value: u64,

    pub fn less_than(_: void, a: Packed_Field, b: Packed_Field) bool {
        return a.offset_bits < b.offset_bits;
    }
};

pub const Enum_Field = struct {
    name: []const u8,
    description: []const u8 = "",
    value: u32,

    pub fn less_than(_: void, a: Enum_Field, b: Enum_Field) bool {
        return a.value < b.value;
    }
};

pub fn zig_name(self: *const Data_Type) []const u8 {
    return if (self.name.len > 0) self.name else self.fallback_name;
}

pub fn is_packable(self: *Data_Type) bool {
    return switch (self.kind) {
        .unsigned,
        .signed,
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

pub fn should_inline(self: Data_Type) bool {
    if (self.zig_name().len == 0) {
        return true;
    }
    return switch (self.inline_mode) {
        .always => true,
        .never => false,
        .auto => self.ref_count <= 1,
    };
}

pub fn add_ref(self: *Data_Type, group: *Peripheral_Group) void {
    if (self.ref_count == 0 or self.inline_mode == .always) switch (self.kind) {
        .unsigned, .signed, .boolean, .anyopaque, .enumeration, .external => {},
        .pointer => |info| {
            group.data_types.items[info.data_type].add_ref(group);
        },
        .register => |info| {
            group.data_types.items[info.data_type].add_ref(group);
        },
        .collection => |info| {
            group.data_types.items[info.data_type].add_ref(group);
        },
        .alternative => |fields| for (fields) |field| {
            group.data_types.items[field.data_type].add_ref(group);
        },
        .structure => |fields| for (fields) |field| {
            group.data_types.items[field.data_type].add_ref(group);
        },
        .bitpack => |fields| for (fields) |field| {
            group.data_types.items[field.data_type].add_ref(group);
        },
    };
    self.ref_count += 1;
}

pub const Dedup_Context = struct {
    group: *const Peripheral_Group,

    pub fn hash(ctx: Dedup_Context, a: Data_Type) u64 {
        return Data_Type.hash(a, ctx.group.*);
    }
    pub fn eql(ctx: Dedup_Context, a: Data_Type, b: Data_Type) bool {
        return Data_Type.eql(a, ctx.group.*, b, ctx.group.*);
    }
};
pub const With_Peripheral_Group = struct {
    group: *const Peripheral_Group,
    data_type: *const Data_Type,
};
pub const Adapted_Dedup_Context = struct {
    group: *const Peripheral_Group,

    pub fn hash(_: Adapted_Dedup_Context, a: With_Peripheral_Group) u64 {
        return Data_Type.hash(a.data_type.*, a.group.*);
    }
    pub fn eql(ctx: Adapted_Dedup_Context, a: With_Peripheral_Group, b: Data_Type) bool {
        return Data_Type.eql(a.data_type.*, a.group.*, b, ctx.group.*);
    }
};

fn hash(self: Data_Type, group: Peripheral_Group) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(self.name);
    // fallback names are ignored.
    h.update(self.description);
    h.update(std.mem.asBytes(&self.inline_mode));
    h.update(std.mem.asBytes(&self.size_bits));

    const tag = std.meta.activeTag(self.kind);
    h.update(std.mem.asBytes(&tag));

    switch (self.kind) {
        .unsigned, .signed, .boolean, .anyopaque => {},
        .external => |info| {
            h.update(info.import);
            if (info.from_int) |from_int| {
                h.update("1");
                h.update(from_int);
            } else {
                h.update("0");
            }
        },
        .pointer => |info| {
            const dt_hash = hash(group.data_types.items[info.data_type], group);
            h.update(std.mem.asBytes(&dt_hash));
            h.update(std.mem.asBytes(&info.constant));
            h.update(std.mem.asBytes(&info.allow_zero));
        },
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
fn eql(a: Data_Type, a_src: Peripheral_Group, b: Data_Type, b_src: Peripheral_Group) bool {
    if (a.size_bits != b.size_bits) return false;
    if (a.inline_mode != b.inline_mode) return false;
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    // fallback names are ignored.
    if (!std.mem.eql(u8, a.description, b.description)) return false;

    if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
    switch (a.kind) {
        .unsigned, .signed, .boolean, .anyopaque => {},
        .external => |a_info| {
            const b_info = b.kind.external;
            if (!std.mem.eql(u8, a_info.import, b_info.import)) return false;
            if (a_info.from_int) |a_from_int| {
                if (b_info.from_int) |b_from_int| {
                    if (!std.mem.eql(u8, a_from_int, b_from_int)) return false;
                } else return false;
            } else if (b_info.from_int != null) return false;
        },
        .pointer => |a_info| {
            const b_info = b.kind.pointer;
            if (a_info.constant != b_info.constant) return false;
            if (a_info.allow_zero != b_info.allow_zero) return false;
            if (!eql(a_src.data_types.items[a_info.data_type], a_src, b_src.data_types.items[b_info.data_type], b_src)) return false;
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

const Data_Type = @This();
const Database = @import("Database.zig");
const Peripheral_Group = @import("Peripheral_Group.zig");
const std = @import("std");
