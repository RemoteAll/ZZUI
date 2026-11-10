//! 里程碑 1 样例：与 CUI 的 `examples/hello.c` 同构的最小界面。
//! 正常启动开一个窗口；带 `--once` 时不建窗口，只渲染一帧并写 `zzui-hello.bmp`（供回归校验）。
const std = @import("std");
const zzui = @import("zzui");

const State = struct {
    notifications: bool = true,
    clicks: u32 = 0,
    auto_save: bool = true,
    mode: u32 = 1,
    volume: f32 = 0.6,
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

fn buildControls(ui: *zzui.core.Context, st: *State) void {
    var col = ui.column(.{ .pad = 32, .gap = 14 });
    defer col.end();

    zzui.widgets.separator(ui);
    zzui.widgets.checkbox(ui, "Enable auto-save", &st.auto_save);

    {
        var row = ui.row(.{ .gap = 16 });
        defer row.end();
        zzui.widgets.radio(ui, "Light", &st.mode, 0);
        zzui.widgets.radio(ui, "Dark", &st.mode, 1);
    }

    zzui.widgets.slider(ui, "Volume", &st.volume, 0, 1);
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--shot")) return runShot();
    if (hasFlag(cmdline, "--once")) return runOnce();

    var st = State{};
    var app = zzui.App.init(.{ .title = "Hello, ZZUI", .width = 420, .height = 460 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        buildControls(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(420, 460) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    buildOnce(&app.ui, &st);
    app.end();
    zzui.bmpfile.saveBmp("zzui-hello.bmp", app.backend.pixels(), 420, 460) catch return 4;
    return 0;
}

fn runShot() i32 {
    var app = zzui.App.init(.{ .title = "ZZUI shot", .width = 440, .height = 500, .show = false }) catch return 5;
    defer app.deinit();
    if (!app.next()) return 6;
    var st = State{};
    buildOnce(&app.ui, &st);
    app.end();
    app.saveSurface("zzui-shot.bmp") catch return 7;
    return 0;
}

fn buildOnce(ui: *zzui.core.Context, st: *State) void {
    build(ui, st);
    buildControls(ui, st);
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
