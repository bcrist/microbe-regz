const std = @import("std");
const DataType = @import("DataType.zig");
const Peripheral = @This();

name: []const u8,
description: []const u8 = "",
base_address: u64,
data_type: DataType.ID,
deleted: bool = false,

pub fn lessThan(_: void, a: Peripheral, b: Peripheral) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
