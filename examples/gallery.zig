//! 控件画廊：一次性展示 `extras` 与 `controls` 两族的全部公开控件。
//! 正常启动开窗口；带 `--once` 时不建窗口，只渲染一帧并写 `zzui-gallery.bmp`（回归用）。
const std = @import("std");
const zzui = @import("zzui");

const State = struct {
    tab: usize = 0,
    seg: usize = 1,
    chip_a: bool = true,
    chip_b: bool = false,
    stars: u8 = 3,
    count: i32 = 4,
    size_idx: usize = 1,
    lo: f32 = 20,
    hi: f32 = 70,
    page: usize = 3,
};

fn build(ui: *zzui.core.Context, st: *State) void {
    var page = ui.scroll(.{ .id = "gallery", .height = ui.height - 16, .gap = 0 });
    defer page.end();

    var col = ui.column(.{ .pad = 24, .gap = 16 });
    defer col.end();

    zzui.widgets.heading(ui, "Component gallery", 2);
    zzui.widgets.secondary(ui, "extras（显示/反馈）与 controls（表单/导航）两族控件一次性铺开。");

    // ---------------------------------------------------------------- 徽标与文本件
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Badges, keys and code", 3);
        {
            var row = ui.row(.{ .gap = 6 });
            defer row.end();
            zzui.extras.badge(ui, "neutral", .neutral);
            zzui.extras.badge(ui, "accent", .accent);
            zzui.extras.badge(ui, "passed", .success);
            zzui.extras.badge(ui, "warning", .warn);
            zzui.extras.badge(ui, "failed", .danger);
        }
        {
            var row = ui.row(.{ .gap = 10 });
            defer row.end();
            zzui.extras.kbd(ui, "Ctrl Shift K");
            _ = zzui.extras.link(ui, "Documentation");
            zzui.extras.code(ui, "zig build test");
        }
        {
            var row = ui.row(.{ .gap = 10 });
            defer row.end();
            _ = zzui.extras.copyButton(ui, "copy-id", &st.chip_b);
            zzui.extras.muted(ui, "muted hint text");
        }
    }

    // ---------------------------------------------------------------- 进度与反馈
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Progress and feedback", 3);
        zzui.extras.progress(ui, 0.42, .{ .label = "Upload" });
        zzui.extras.progress(ui, 0.8, .{ .label = "Indexing", .tone = .success });
        zzui.extras.meter(ui, "CPU", 0.63);
        {
            var row = ui.row(.{ .gap = 16 });
            defer row.end();
            zzui.extras.progressRing(ui, 0.7, 56);
            zzui.extras.spinner(ui, 24);
            zzui.extras.passwordStrength(ui, 3, 4);
        }
        zzui.extras.metric(ui, "Requests", "12,480", "+8.2%");
        zzui.extras.skeleton(ui, 220, 12);
        zzui.extras.skeleton(ui, 150, 12);
    }

    // ---------------------------------------------------------------- 空状态与时间线
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Empty state and timeline", 3);
        zzui.extras.emptyState(ui, "No projects yet", "Create your first project to get started.");
        zzui.extras.timelineItem(ui, "09:12", "Build finished", "zzui-gallery x64 in 3.4s");
        zzui.extras.timelineItem(ui, "08:40", "Tests passed", "18 cases, 0 failures");
    }

    // ---------------------------------------------------------------- 导航与选择
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Navigation", 3);
        zzui.controls.tabs(ui, "tabs", &.{ "Overview", "Activity", "Settings" }, &st.tab);
        zzui.controls.segmented(ui, "seg", &.{ "Day", "Week", "Month" }, &st.seg);
        _ = zzui.controls.breadcrumb(ui, &.{ "Home", "Projects", "ZZUI" }, 2);
        {
            var row = ui.row(.{ .gap = 8 });
            defer row.end();
            _ = zzui.controls.chip(ui, "alpha", &st.chip_a);
            _ = zzui.controls.chip(ui, "beta", &st.chip_b);
        }
    }

    // ---------------------------------------------------------------- 表单控件
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Inputs", 3);
        {
            var row = ui.row(.{ .gap = 16 });
            defer row.end();
            zzui.controls.rating(ui, "rating", &st.stars, 5);
            zzui.controls.stepper(ui, "count", &st.count, 0, 99);
            zzui.controls.pagination(ui, "pages", &st.page, 12);
        }
        zzui.controls.radioGroup(ui, "sizes", &.{ "Small", "Medium", "Large" }, &st.size_idx);
        zzui.controls.rangeSlider(ui, "range", &st.lo, &st.hi, 0, 100);
    }

    // ---------------------------------------------------------------- 侧栏导航
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Side navigation", 3);
        _ = zzui.controls.navItem(ui, "Dashboard", true);
        _ = zzui.controls.navItem(ui, "Reports", false);
        _ = zzui.controls.navItem(ui, "Settings", false);
    }
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--once")) return runOnce();
    if (hasFlag(cmdline, "--shot-bottom")) return runShot(true);
    if (hasFlag(cmdline, "--shot")) return runShot(false);

    var st = State{};
    var app = zzui.App.init(.{ .title = "ZZUI gallery", .width = 720, .height = 1000 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(720, 1600) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    build(&app.ui, &st);
    app.end();
    zzui.bmpfile.saveBmp("zzui-gallery.bmp", app.backend.pixels(), 720, 1600) catch return 4;
    return 0;
}

/// 隐藏窗口真渲染（含系统字体文本）。
/// `--shot` 拍顶部；`--shot-bottom` 先滚到底再拍（窗口高受屏幕限制，分两屏看完整）。
fn runShot(bottom: bool) i32 {
    var app = zzui.App.init(.{ .title = "ZZUI gallery shot", .width = 720, .height = 1000, .show = false }) catch return 5;
    defer app.deinit();
    if (!app.next()) return 6;
    var st = State{};
    if (bottom) {
        app.ui.input = .{ .mouse = .{ .x = 300, .y = 500 }, .wheel = -60 };
        build(&app.ui, &st);
        app.end();
        if (!app.next()) return 6;
        app.ui.input = .{ .mouse = .{ .x = 300, .y = 500 } };
    }
    build(&app.ui, &st);
    app.end();
    app.saveSurface(if (bottom) "zzui-gallery-bottom.bmp" else "zzui-gallery-shot.bmp") catch return 7;
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
