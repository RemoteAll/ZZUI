const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "debug / safe / fast / small") orelse .small;

    const specs = [_]struct { name: []const u8, arch: std.Target.Cpu.Arch, src: []const u8 }{
        .{ .name = "zzui-hello-x64", .arch = .x86_64, .src = "examples/hello.zig" },
        .{ .name = "zzui-hello-x86", .arch = .x86, .src = "examples/hello.zig" },
        .{ .name = "zzui-gallery-x64", .arch = .x86_64, .src = "examples/gallery.zig" },
        .{ .name = "zzui-pickers-x64", .arch = .x86_64, .src = "examples/pickers.zig" },
        .{ .name = "zzui-docs-x64", .arch = .x86_64, .src = "examples/docs.zig" },
        .{ .name = "zzui-devtools-x64", .arch = .x86_64, .src = "examples/devtools.zig" },
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
        // Linux 上 x11 是真后端：测试二进制会引用 Xlib，必须链 libc + X11
        .link_libc = @import("builtin").os.tag == .linux,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    if (@import("builtin").os.tag == .linux) tests.root_module.linkSystemLibrary("X11", .{});
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

    // ---- Linux/X11 产物（只在 Linux 主机上可用）----
    // Windows 上的 Zig 交叉编不出来：X11 后端要 `-lX11`，本机没有那套系统库。
    // 在 WSL / 真机上：`zig build x11` 出 `zzui-hello-linux`，`zig build x11-smoke` 出冒烟探针。
    if (@import("builtin").os.tag == .linux) {
        // 必须用**本机** target：显式 `x86_64-linux-gnu` 会被当成交叉编译，
        // Zig 只用自己的 glibc 存根、不去找系统里的 libX11（实测报 searched paths: none）。
        const linux_target = b.graph.host;
        const linux_zzui = b.createModule(.{
            .root_source_file = b.path("src/zzui.zig"),
            .target = linux_target,
            .optimize = optimize,
        });
        // 注意：`examples/hello.zig` 是 Windows 的 `wWinMain` 入口，Linux 上编不了；
        // 跨平台的最小演示用这个冒烟探针（同样是 App + 控件，只是跑完 8 帧存 BMP 就退出）。
        const linux_exes = [_]struct { name: []const u8, src: []const u8, step: []const u8 }{
            .{ .name = "zzui-x11-smoke", .src = "examples/x11_smoke.zig", .step = "x11-smoke" },
        };
        for (linux_exes) |le| {
            const exe = b.addExecutable(.{
                .name = le.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(le.src),
                    .target = linux_target,
                    .optimize = optimize,
                    // 0.17：`exe.linkLibC()` 没了，链接选项挂在模块上
                    .link_libc = true,
                }),
            });
            exe.root_module.addImport("zzui", linux_zzui);
            exe.root_module.linkSystemLibrary("X11", .{});
            const st = b.step(le.step, "Build the Linux/X11 example (needs libx11-dev)");
            st.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }
}
