const std = @import("std");
const PeripheralType = @import("PeripheralType.zig");
const Peripheral = @This();

name: []const u8,
description: []const u8,
offset_bytes: u64,
count: u32,
peripheral_type: PeripheralType.ID,
deleted: bool = false,

pub fn lessThan(_: void, a: Peripheral, b: Peripheral) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
