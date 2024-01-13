name: []const u8,
description: []const u8 = "",
base_address: u64,
data_type: Data_Type.ID,
deleted: bool = false,

pub fn less_than(_: void, a: Peripheral, b: Peripheral) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const Peripheral = @This();
const Data_Type = @import("Data_Type.zig");
const std = @import("std");
