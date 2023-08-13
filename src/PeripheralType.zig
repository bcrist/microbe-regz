const std = @import("std");
const Register = @import("Register.zig");

pub const ID = u32;

name: []const u8,
description: []const u8 = "",
registers: std.ArrayListUnmanaged(Register) = .{},
ref_count: u32 = 0,
