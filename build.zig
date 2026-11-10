const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "debug / safe / fast / small") orelse .small;

    const specs = [_]struct { name: []const u8, arch: std.Target.Cpu.Arch }{
        .{ .name = "zzui-hello-x64", .arch = .x86_64 },
        .{ .name = "zzui-hello-x86", .arch = .x86 },
    };

    for (specs) |spec| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = spec.arch,
            .os_tag = .windows,
            .abi = .gnu,
        });
        const zzui_mod = b.createModule(.{
            .root_source_file = b.path("src/zzui.zig"),
            .target = target,
            .optimize = optimize,
        });
        const exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/hello.zig"),
                .target = target,
                .optimize = optimize,
                .strip = true,
            }),
        });
        exe.root_module.addImport("zzui", zzui_mod);
        exe.subsystem = .windows;
        b.installArtifact(exe);
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
