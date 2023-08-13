const std = @import("std");
const PeripheralGroup = @import("PeripheralGroup.zig");

const DataType = @This();

pub const ID = u32;

name: []const u8,
description: []const u8,
size_bits: u32,
kind: union(enum) {
    unsigned,
    @"array": ArrayInfo,
    @"packed": std.ArrayListUnmanaged(PackedField),
    @"enum": std.ArrayListUnmanaged(EnumField),
    external: []const u8, // @import where type is defined
},
ref_count: u32 = 0,

pub const ArrayInfo = struct {
    count: u32,
    data_type: ID,
};

pub const PackedField = struct {
    name: []const u8,
    description: []const u8,
    offset_bits: u32,
    data_type: ID,
    default_value: u64,
    deleted: bool = false,

    pub fn lessThan(_: void, a: PackedField, b: PackedField) bool {
        return a.offset_bits < b.offset_bits;
    }
};

pub const EnumField = struct {
    name: []const u8,
    description: []const u8,
    value: u32,
    deleted: bool = false,
};
