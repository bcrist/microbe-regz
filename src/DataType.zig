const std = @import("std");
const PeripheralGroup = @import("PeripheralGroup.zig");

const DataType = @This();

pub const ID = u32;

name: []const u8,
description: []const u8 = "",
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
    description: []const u8 = "",
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
    description: []const u8 = "",
    value: u32,
    deleted: bool = false,
};

pub fn debug(self: DataType, id: DataType.ID, group_name: []const u8) void {
    switch (self.kind) {
        .unsigned => {
            std.log.debug("{s}: Data Type {}: {s}: u{} RC:{} - {s}", .{
                group_name,
                id,
                self.name,
                self.size_bits,
                self.ref_count,
                self.description,
            });
        },
        .@"array" => |info| {
            std.log.debug("{s}: Data Type {}: {s}: [{}]({}) size:{} RC:{} - {s}", .{
                group_name,
                id,
                self.name,
                info.count,
                info.data_type,
                self.size_bits,
                self.ref_count,
                self.description,
            });
        },
        .@"packed" => |fields| {
            std.log.debug("{s}: Data Type {}: {s}: packed size:{} RC:{} - {s}", .{
                group_name,
                id,
                self.name,
                self.size_bits,
                self.ref_count,
                self.description,
            });
            for (fields.items) |field| {
                const deleted = if (field.deleted) "DELETED " else "";
                std.log.debug("{s} (dt {}): {s}: ({}) @{} {} {s}- {s}", .{
                    group_name,
                    id,
                    field.name,
                    field.data_type,
                    field.offset_bits,
                    field.default_value,
                    deleted,
                    field.description,
                });
            }
         },
        .@"enum" => |fields| {
            std.log.debug("{s}: Data Type {}: {s}: enum size:{} RC:{} - {s}", .{
                group_name,
                id,
                self.name,
                self.size_bits,
                self.ref_count,
                self.description,
            });
            for (fields.items) |field| {
                const deleted = if (field.deleted) "DELETED " else "";
                std.log.debug("{s} (dt {}): {s} = {} {s}- {s}", .{
                    group_name,
                    id,
                    field.name,
                    field.value,
                    deleted,
                    field.description,
                });
            }
        },
        .external => |import| {
            std.log.debug("{s}: Data Type {}: {s}: external({s}) size:{} RC:{} - {s}", .{
                group_name,
                id,
                self.name,
                import,
                self.size_bits,
                self.ref_count,
                self.description,
            });
        },
    }
}
