
const Interrupt = @This();

name: []const u8,
description: []const u8 = "",
index: i32,

pub fn lessThan(_: void, a: Interrupt, b: Interrupt) bool {
    return a.index < b.index;
}
