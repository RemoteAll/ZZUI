//! 选择器族样例（对位 CUI `cui_pickers.c`）：多选 / 区间日历 / 日期区间 / 时分 /
//! 滚轮 / 表盘 / 刻度尺 / 直方图 / 签名板。
//!
//! 单独一个产物（不塞进 gallery）：选择器族代码量大，塞进 gallery 会顶穿它的体积门槛。
//! `--once` 无窗口渲染写 `zzui-pickers.bmp`；`--shot` 真渲染（含系统字体）写 `zzui-pickers-shot.bmp`；
//! `--shot-1` 先滚到底再拍（看表盘/刻度尺/直方图/签名板）。
const std = @import("std");
const zzui = @import("zzui");

const State = struct {
    // 多选
    ms_state: zzui.pickers.PopupState = .{},
    ms: [8]bool = .{ true, false, true, false, false, false, false, false },
    // 区间日历
    cal_month: zzui.pickers.Date = .{ .year = 2026, .month = 11, .day = 1 },
    range: zzui.pickers.DateRange = .{
        .start = .{ .year = 2026, .month = 11, .day = 3 },
        .end = .{ .year = 2026, .month = 11, .day = 10 },
    },
    // 日期区间字段
    dr_state: zzui.pickers.PopupState = .{},
    // 时分
    hour: i32 = 9,
    minute: i32 = 30,
    tp_state: zzui.pickers.PopupState = .{},
    // 滚轮
    wheel_idx: usize = 2,
    wheel: zzui.pickers.WheelState = .{ .pos = 2 },
    wheel_idx2: usize = 0,
    wheel2: zzui.pickers.WheelState = .{ .pos = 0 },
    // 表盘
    dial_hour: i32 = 3,
    dial_minute: i32 = 45,
    // 刻度尺
    ruler_v: f32 = 42,
    ruler: zzui.pickers.RulerState = .{},
    // 直方图
    hist_lo: f32 = 20,
    hist_hi: f32 = 78,
    // 签名
    sig: zzui.pickers.SignatureState = .{},
};

const multi_items = [_][]const u8{ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel" };
const wheel_items = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const wheel_items2 = [_][]const u8{ "2024", "2025", "2026", "2027", "2028" };
const hist_bins = [_]f32{ 2, 5, 9, 14, 22, 31, 38, 42, 36, 28, 19, 12, 8, 5, 3 };

fn build(ui: *zzui.core.Context, st: *State) void {
    var col = ui.column(.{ .pad = 24, .gap = 14 });
    defer col.end();

    zzui.widgets.heading(ui, "Pickers", 2);
    zzui.widgets.secondary(ui, "Multi-select, date ranges, time, wheels, dials, rulers and a signature pad.");

    var body = ui.scroll(.{ .id = "pickers-body", .height = ui.height - 120, .gap = 14 });
    defer body.end();

    zzui.extras.muted(ui, "Multi-select (searchable, chips collapse to +N)");
    _ = zzui.pickers.multiSelect(ui, "ms", multi_items[0..], st.ms[0..], &st.ms_state, .{
        .searchable = true,
        .max_chips = 2,
        .placeholder = "Pick tags",
    });

    zzui.extras.muted(ui, "Date range calendar (click a start, then an end)");
    _ = zzui.pickers.rangeCalendar(ui, "rcal", &st.cal_month, &st.range, .{ .months = 2, .cell_h = 28 });

    var rb: [16]u8 = @splat(0);
    var r2: [16]u8 = @splat(0);
    zzui.widgets.textInt(ui, "selected days = ", @intCast(zzui.pickers.dateToDays(st.range.end) - zzui.pickers.dateToDays(st.range.start) + 1), "  ");
    zzui.extras.code(ui, ui.frameStr(zzui.pickers.formatDate(&rb, st.range.start)));
    zzui.extras.code(ui, ui.frameStr(zzui.pickers.formatDate(&r2, st.range.end)));

    zzui.extras.muted(ui, "Date range field (opens presets + two-month calendar)");
    _ = zzui.pickers.dateRangePicker(ui, "dr", &st.cal_month, &st.range, &st.dr_state, .{});

    zzui.extras.muted(ui, "Time picker (hour + minute columns)");
    _ = zzui.pickers.timePicker(ui, "tp", &st.hour, &st.minute, &st.tp_state, .{ .minute_step = 5 });

    zzui.extras.muted(ui, "Wheel pickers side by side (drag, wheel or arrow keys)");
    {
        var row = ui.row(.{ .gap = 0 });
        defer row.end();
        _ = zzui.pickers.wheelPicker(ui, "w1", wheel_items[0..], &st.wheel_idx, &st.wheel, .{ .join_right = true });
        _ = zzui.pickers.wheelPicker(ui, "w2", wheel_items2[0..], &st.wheel_idx2, &st.wheel2, .{ .join_left = true });
    }

    zzui.extras.muted(ui, "Time dial (drag the hand inside for minutes, outside for hours)");
    _ = zzui.pickers.timeDial(ui, "dial", &st.dial_hour, &st.dial_minute, 180);

    zzui.extras.muted(ui, "Ruler slider (drag to change, snaps to step)");
    _ = zzui.pickers.rulerSlider(ui, "Threshold", &st.ruler_v, 0, 100, &st.ruler, .{ .step = 1, .major_every = 5, .spacing = 12, .unit = "ms" });

    zzui.extras.muted(ui, "Histogram range slider");
    _ = zzui.pickers.histogramSlider(ui, "Latency", hist_bins[0..], &st.hist_lo, &st.hist_hi, 0, 100, .{});

    zzui.extras.muted(ui, "Signature pad (press and drag; clear with the button)");
    _ = zzui.pickers.signaturePad(ui, "sig", &st.sig, .{ .height = 130, .placeholder = "Sign here" });
    if (zzui.widgets.button(ui, "Clear signature", .{})) {
        zzui.pickers.signatureClear(&st.sig);
    }
    const pts = zzui.pickers.signaturePoints(&st.sig);
    zzui.widgets.textInt(ui, "points = ", @intCast(pts.points.len), "  ");
    zzui.widgets.textInt(ui, "strokes = ", @intCast(pts.strokes), "");
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--once")) return runOnce();
    if (hasFlag(cmdline, "--shot-1")) return runShot(1);
    if (hasFlag(cmdline, "--shot")) return runShot(0);

    var st = State{};
    var app = zzui.App.init(.{ .title = "ZZUI pickers", .width = 760, .height = 1000 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(760, 1000) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    build(&app.ui, &st);
    app.end();
    if (app.ui.overflowed) return 8;
    zzui.bmpfile.saveBmp("zzui-pickers.bmp", app.backend.pixels(), 760, 1000) catch return 4;
    return 0;
}

fn runShot(page: usize) i32 {
    const offset: f32 = if (page == 1) 640 else 0;
    var app = zzui.App.init(.{ .title = "ZZUI pickers", .width = 760, .height = 1000, .show = false }) catch return 5;
    defer app.deinit();
    if (!app.next()) return 6;
    var st = State{};
    // 两帧：第一帧字体未挂上，宽度按估算，排版会偏
    if (offset > 0) app.ui.scrollTo("pickers-body", offset);
    build(&app.ui, &st);
    app.end();
    if (!app.next()) return 6;
    if (offset > 0) app.ui.scrollTo("pickers-body", offset);
    build(&app.ui, &st);
    app.end();
    if (app.ui.overflowed) return 8;
    if (page == 1) {
        app.saveSurface("zzui-pickers-shot1.bmp") catch return 7;
    } else {
        app.saveSurface("zzui-pickers-shot.bmp") catch return 7;
    }
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
