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
    name: [64]u8 = @splat(0),
    name_len: usize = 0,
    name_caret: usize = 0,
    dialog_open: bool = false,
    menu_open: bool = false,
    menu_anchor: zzui.types.Rect = .{},
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
    const mb = zzui.widgets.buttonEx(ui, "Menu", .{});
    if (mb.clicked) st.menu_open = true;
    st.menu_anchor = mb.rect;
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

    {
        var list = ui.scroll(.{ .id = "items", .height = 140, .gap = 6 });
        defer list.end();
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            ui.textIntRun("Item ", @intCast(i + 1), " (wheel to scroll)", zzui.theme.font_body, zzui.theme.text);
        }
    }

    zzui.widgets.slider(ui, "Volume", &st.volume, 0, 1);

    zzui.widgets.secondary(ui, "Text wraps to the content width, so a long sentence stays inside the window " ++
        "instead of running off the right edge like it used to.");

    _ = zzui.widgets.input(ui, "name", &st.name, &st.name_len, &st.name_caret, .{ .placeholder = "Type your name" });
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--shot")) return runShot();
    if (hasFlag(cmdline, "--once")) return runOnce();

    var st = State{};
    var app = zzui.App.init(.{ .title = "Hello, ZZUI", .width = 420, .height = 760 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        buildControls(&app.ui, &st);
        buildOverlays(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(420, 760) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    buildOnce(&app.ui, &st);
    app.end();
    zzui.bmpfile.saveBmp("zzui-hello.bmp", app.backend.pixels(), 420, 760) catch return 4;
    return 0;
}

fn runShot() i32 {
    var app = zzui.App.init(.{ .title = "ZZUI shot", .width = 460, .height = 820, .show = false }) catch return 5;
    defer app.deinit();
    if (!app.next()) return 6;
    var st = State{};
    st.menu_open = true;
    buildOnce(&app.ui, &st);
    buildOverlays(&app.ui, &st);
    app.end();

    // 第二帧：鼠标移到“Menu”按钮上，开始计悬停时间
    if (!app.next()) return 6;
    st.menu_open = false;
    app.ui.time = 10;
    app.ui.input = .{ .mouse = .{ .x = st.menu_anchor.x + 8, .y = st.menu_anchor.y + 8 } };
    buildOnce(&app.ui, &st);
    buildOverlays(&app.ui, &st);
    app.end();

    // 第三帧：超过延迟，提示出现
    if (!app.next()) return 6;
    app.ui.time = 10.5;
    app.ui.input = .{ .mouse = .{ .x = st.menu_anchor.x + 8, .y = st.menu_anchor.y + 8 } };
    buildOnce(&app.ui, &st);
    buildOverlays(&app.ui, &st);
    app.end();
    app.saveSurface("zzui-shot.bmp") catch return 7;
    return 0;
}

fn buildOnce(ui: *zzui.core.Context, st: *State) void {
    build(ui, st);
    buildControls(ui, st);
}

fn buildOverlays(ui: *zzui.core.Context, st: *State) void {
    if (st.menu_open) {
        const items = [_]zzui.widgets.MenuItem{
            .{ .label = "Rename" },
            .{ .label = "Duplicate" },
            .{ .label = "Delete project..." },
            .{ .label = "Disabled item", .enabled = false },
        };
        if (zzui.widgets.menu(ui, "main-menu", st.menu_anchor, &items, &st.menu_open, .{})) |idx| {
            if (idx == 2) st.dialog_open = true;
        }
    } else {
        const ax = st.menu_anchor;
        const hov = ax.contains(ui.input.mouse.x, ui.input.mouse.y);
        zzui.widgets.tooltip(ui, "menu-tip", ax, "Open the actions menu", hov, 0.35);
    }
    if (st.dialog_open) {
        _ = zzui.widgets.dialog(ui, &st.dialog_open, .{
            .title = "Delete project",
            .message = "This action cannot be undone.",
            .ok_label = "Delete",
        });
    }
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
