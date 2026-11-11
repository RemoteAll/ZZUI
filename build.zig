const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "debug / safe / fast / small") orelse .small;

    const specs = [_]struct { name: []const u8, arch: std.Target.Cpu.Arch, src: []const u8 }{
        .{ .name = "zzui-hello-x64", .arch = .x86_64, .src = "examples/hello.zig" },
        .{ .name = "zzui-hello-x86", .arch = .x86, .src = "examples/hello.zig" },
        .{ .name = "zzui-gallery-x64", .arch = .x86_64, .src = "examples/gallery.zig" },
        .{ .name = "zzui-pickers-x64", .arch = .x86_64, .src = "examples/pickers.zig" },
        .{ .name = "zzui-docs-x64", .arch = .x86_64, .src = "examples/docs.zig" },
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
                .root_source_file = b.path(spec.src),
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

    // ---- 交叉编译检查（多平台硬约束的护栏）----
    // `zig build check`：把**库**（src/zzui.zig）编到各目标，证明平台无关层
    // 在这些目标上确实能编译。示例产物是 Win32 GUI，只有 Windows 目标能出 exe。
    const check_step = b.step("check", "Cross-compile the library for every supported target");
    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    };
    for (targets) |q| {
        const t2 = b.resolveTargetQuery(q);
        const lib_mod = b.createModule(.{
            .root_source_file = b.path("src/zzui.zig"),
            .target = t2,
            .optimize = .small,
        });
        const lib = b.addLibrary(.{
            .name = "zzui",
            .root_module = lib_mod,
            .linkage = .static,
        });
        check_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }
}
