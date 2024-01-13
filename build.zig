const std = @import("std");

pub fn build(b: *std.Build) void {
    const sx = b.dependency("Zig-SX", .{}).module("sx");

    const exe = b.addExecutable(.{
        .name = "microbe-regz",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    exe.root_module.addImport("sx", sx);
    b.installArtifact(exe);
}
