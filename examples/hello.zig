//! 里程碑 1 样例：与 CUI 的 `examples/hello.c` 同构的最小界面。
//! 正常启动开一个窗口；带 `--once` 时不建窗口，只渲染一帧并写 `zzui-hello.bmp`（供回归校验）。
const std = @import("std");
const zzui = @import("zzui");

const State = struct {
    notifications: bool = true,
    clicks: u32 = 0,
};

fn build(ui: *zzui.core.Context, st: *State) void {
    var col = ui.column(.{ .pad = 32, .gap = 16 });
    defer col.end();

    zzui.widgets.heading(ui, "Hello, ZZUI", 2);
    zzui.widgets.secondary(ui, "A native window, a few components and no dependencies.");
    zzui.widgets.controlSwitch(ui, "Notifications", &st.notifications);

    var row = ui.row(.{ .gap = 8 });
    defer row.end();
    if (zzui.widgets.button(ui, "Click me", .{ .variant = .primary })) st.clicks += 1;
    zzui.widgets.textInt(ui, "Clicked ", st.clicks, " times");
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--once")) return runOnce();

    var st = State{};
    var app = zzui.App.init(.{ .title = "Hello, ZZUI", .width = 420, .height = 300 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(420, 300) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    build(&app.ui, &st);
    app.end();
    zzui.bmpfile.saveBmp("zzui-hello.bmp", app.backend.pixels(), 420, 300) catch return 4;
    return 0;
}

fn hasFlag(cmd: [*:0]u16, flag: []const u8) bool {
    var i: usize = 0;
    while (cmd[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < flag.len and cmd[i + j] != 0 and cmd[i + j] == @as(u16, flag[j])) : (j += 1) {}
        if (j == flag.len) return true;
    }
    return false;
}
