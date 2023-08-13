const std = @import("std");
const DataType = @import("DataType.zig");
const Register = @This();

name: []const u8,
description: []const u8 = "",
offset_bytes: u32,
reset_value: u64,
reset_mask: u64,
data_type: DataType.ID,
access: AccessPolicy,

pub const AccessPolicy = enum {
    @"read-write",
    @"read-only",
    @"write-only",
};

pub fn lessThan(_: void, a: Register, b: Register) bool {
    return a.offset_bytes < b.offset_bytes;
}
