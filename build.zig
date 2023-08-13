const std = @import("std");

pub fn build(b: *std.Build) void {
    const zig_sx_dep = b.dependency("Zig-SX", .{});
    const sx_reader = zig_sx_dep.module("sx-reader");

    const exe = b.addExecutable(.{
        .name = "microbe-regz",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    exe.addModule("sx-reader", sx_reader);
    b.installArtifact(exe);
}
