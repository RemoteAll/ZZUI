//! 选择器族测试（由 `tests.zig` 引入）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const pickers = @import("pickers.zig");
const t = @import("types.zig");

// ---------------------------------------------------------------- 日期工具

test "pickers dateToDays and dateFromDays round-trip" {
    const cases = [_]pickers.Date{
        .{ .year = 1970, .month = 1, .day = 1 },
        .{ .year = 2000, .month = 2, .day = 29 },
        .{ .year = 2026, .month = 11, .day = 10 },
        .{ .year = 1969, .month = 12, .day = 31 },
        .{ .year = 2100, .month = 3, .day = 1 },
    };
    for (cases) |d| {
        const days = pickers.dateToDays(d);
        const back = pickers.dateFromDays(days);
        try std.testing.expectEqual(d.year, back.year);
        try std.testing.expectEqual(d.month, back.month);
        try std.testing.expectEqual(d.day, back.day);
    }
    // 1970-01-01 = 0
    try std.testing.expectEqual(@as(i32, 0), pickers.dateToDays(.{ .year = 1970, .month = 1, .day = 1 }));
}

test "pickers formatDate writes ISO and dashes when unset" {
    var buf: [16]u8 = @splat(0);
    try std.testing.expectEqualStrings("2026-11-10", pickers.formatDate(&buf, .{ .year = 2026, .month = 11, .day = 10 }));
    var buf2: [16]u8 = @splat(0);
    try std.testing.expectEqualStrings("--", pickers.formatDate(&buf2, .{ .year = 0, .month = 0, .day = 0 }));
}

test "pickers date range contains only inside the span" {
    const r = pickers.DateRange{
        .start = .{ .year = 2026, .month = 11, .day = 3 },
        .end = .{ .year = 2026, .month = 11, .day = 10 },
    };
    try std.testing.expect(r.contains(.{ .year = 2026, .month = 11, .day = 3 }));
    try std.testing.expect(r.contains(.{ .year = 2026, .month = 11, .day = 7 }));
    try std.testing.expect(r.contains(.{ .year = 2026, .month = 11, .day = 10 }));
    try std.testing.expect(!r.contains(.{ .year = 2026, .month = 11, .day = 11 }));
    try std.testing.expect(!r.contains(.{ .year = 2026, .month = 11, .day = 2 }));
}

// ---------------------------------------------------------------- 区间日历

fn runCalendar(ui: *core.Context, shown: *pickers.Date, range: *pickers.DateRange) void {
    ui.begin(700, 620);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    _ = pickers.rangeCalendar(ui, "cal", shown, range, .{ .months = 2, .cell_h = 26 });
    ui.paint();
}

test "pickers range calendar sets start then end" {
    var ui = core.Context{};
    var shown = pickers.Date{ .year = 2026, .month = 11, .day = 1 };
    var range = pickers.DateRange{};

    // 两帧建立命中
    runCalendar(&ui, &shown, &range);
    if (ui.overflowed) return error.Overflowed;
    runCalendar(&ui, &shown, &range);

    // 点 11 月 5 日（格子 id 按「月槽 + 日」绑定）
    const day5_id = core.Context.idOf("cal") ^ (0xD00 + 0 * 0x4000 + 5);
    const r5 = ui.lastRect(day5_id) orelse return error.NoHitDay5;
    ui.input = .{ .mouse = .{ .x = r5.x + 4, .y = r5.y + 4 }, .click = .{ .x = r5.x + 4, .y = r5.y + 4 } };
    runCalendar(&ui, &shown, &range);
    try std.testing.expectEqual(@as(u8, 5), range.start.day);
    try std.testing.expectEqual(@as(u8, 0), range.end.day);

    // 再点 11 月 9 日
    ui.input = .{};
    runCalendar(&ui, &shown, &range);
    const day9_id = core.Context.idOf("cal") ^ (0xD00 + 0 * 0x4000 + 9);
    const r9 = ui.lastRect(day9_id) orelse return error.NoHitDay9;
    ui.input = .{ .mouse = .{ .x = r9.x + 4, .y = r9.y + 4 }, .click = .{ .x = r9.x + 4, .y = r9.y + 4 } };
    runCalendar(&ui, &shown, &range);
    try std.testing.expectEqual(@as(u8, 5), range.start.day);
    try std.testing.expectEqual(@as(u8, 9), range.end.day);
}

test "pickers range calendar swaps when the second click is earlier" {
    var ui = core.Context{};
    var shown = pickers.Date{ .year = 2026, .month = 11, .day = 1 };
    var range = pickers.DateRange{};
    runCalendar(&ui, &shown, &range);
    runCalendar(&ui, &shown, &range);

    // 点 9 号，再点 5 号 → 应交换成 start=5 end=9
    const id9 = core.Context.idOf("cal") ^ (0xD00 + 0 * 0x4000 + 9);
    var r9 = ui.lastRect(id9) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r9.x + 4, .y = r9.y + 4 }, .click = .{ .x = r9.x + 4, .y = r9.y + 4 } };
    runCalendar(&ui, &shown, &range);

    ui.input = .{};
    runCalendar(&ui, &shown, &range);
    const id5 = core.Context.idOf("cal") ^ (0xD00 + 0 * 0x4000 + 5);
    r9 = ui.lastRect(id5) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r9.x + 4, .y = r9.y + 4 }, .click = .{ .x = r9.x + 4, .y = r9.y + 4 } };
    runCalendar(&ui, &shown, &range);

    try std.testing.expectEqual(@as(u8, 5), range.start.day);
    try std.testing.expectEqual(@as(u8, 9), range.end.day);
}

// ---------------------------------------------------------------- 多选

const ms_items = [_][]const u8{ "Alpha", "Bravo", "Charlie" };

fn runMulti(ui: *core.Context, sel: *[3]bool, st: *pickers.PopupState) void {
    ui.begin(600, 460);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    _ = pickers.multiSelect(ui, "ms", ms_items[0..], sel[0..], st, .{});
    ui.paint();
}

test "pickers multi select toggles an item in the popup" {
    var ui = core.Context{};
    var sel = [3]bool{ false, false, false };
    var st = pickers.PopupState{ .open = true };

    runMulti(&ui, &sel, &st);
    runMulti(&ui, &sel, &st);
    if (ui.overflowed) return error.Overflowed;

    const row1 = core.Context.idOf("ms") ^ (0xB0 + 1);
    const r = ui.lastRect(row1) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r.x + 8, .y = r.y + 8 }, .click = .{ .x = r.x + 8, .y = r.y + 8 } };
    runMulti(&ui, &sel, &st);
    try std.testing.expect(!sel[0]);
    try std.testing.expect(sel[1]);
    try std.testing.expect(!sel[2]);
}

// ---------------------------------------------------------------- 时分

fn runTime(ui: *core.Context, h: *i32, m: *i32, st: *pickers.PopupState) void {
    ui.begin(600, 460);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    _ = pickers.timePicker(ui, "tp", h, m, st, .{ .minute_step = 5 });
    ui.paint();
}

test "pickers time picker changes the minute column" {
    var ui = core.Context{};
    var h: i32 = 9;
    var m: i32 = 30;
    var st = pickers.PopupState{ .open = true };

    runTime(&ui, &h, &m, &st);
    runTime(&ui, &h, &m, &st);

    // 分列第 6 项（30 分，step 5 → index 6）应在中间；点第 7 项 = 35 分
    const minute_id = (core.Context.idOf("tp") ^ 0x5000) ^ (0x7C0 + 7);
    const r = ui.lastRect(minute_id) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r.x + 6, .y = r.y + 6 }, .click = .{ .x = r.x + 6, .y = r.y + 6 } };
    runTime(&ui, &h, &m, &st);
    try std.testing.expectEqual(@as(i32, 35), m);
}

// ---------------------------------------------------------------- 滚轮

fn runWheel(ui: *core.Context, idx: *usize, st: *pickers.WheelState) void {
    ui.begin(400, 300);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    _ = pickers.wheelPicker(ui, "wh", ms_items[0..], idx, st, .{});
    ui.paint();
}

test "pickers wheel picker steps with the wheel" {
    var ui = core.Context{};
    var idx: usize = 0;
    var st = pickers.WheelState{};
    runWheel(&ui, &idx, &st);
    const r = ui.lastRect(core.Context.idOf("wh") ^ 0x7EE1) orelse return error.NoHit;

    // 滚轮向下（-1）= 下一项
    ui.input = .{ .mouse = .{ .x = r.x + 10, .y = r.y + 10 }, .wheel = -1 };
    runWheel(&ui, &idx, &st);
    try std.testing.expectEqual(@as(usize, 1), idx);

    // 再滚一次到 2；越界夹取
    ui.input = .{ .mouse = .{ .x = r.x + 10, .y = r.y + 10 }, .wheel = -5 };
    runWheel(&ui, &idx, &st);
    try std.testing.expectEqual(@as(usize, 2), idx);
}

// ---------------------------------------------------------------- 表盘

fn runDial(ui: *core.Context, h: *i32, m: *i32) void {
    ui.begin(400, 400);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    _ = pickers.timeDial(ui, "dial", h, m, 160);
    ui.paint();
}

test "pickers time dial sets hours when dragging outside the inner ring" {
    var ui = core.Context{};
    var h: i32 = 12;
    var m: i32 = 0;
    runDial(&ui, &h, &m);
    const r = ui.lastRect(core.Context.idOf("dial") ^ 0x71A1) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    // 正右方 = 3 点
    ui.input = .{ .mouse = .{ .x = cx + r.w * 0.42, .y = cy }, .down = true, .pressed = true };
    runDial(&ui, &h, &m);
    try std.testing.expectEqual(@as(i32, 3), h);

    // 正下方 = 6 点
    ui.input = .{ .mouse = .{ .x = cx, .y = cy + r.h * 0.42 }, .down = true };
    runDial(&ui, &h, &m);
    try std.testing.expectEqual(@as(i32, 6), h);
}

// ---------------------------------------------------------------- 刻度尺

fn runRuler(ui: *core.Context, v: *f32, st: *pickers.RulerState) void {
    ui.begin(500, 260);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    _ = pickers.rulerSlider(ui, "ruler", v, 0, 100, st, .{ .step = 1, .spacing = 10 });
    ui.paint();
}

test "pickers ruler slider drags then snaps to the step" {
    var ui = core.Context{};
    var v: f32 = 50;
    var st = pickers.RulerState{};
    runRuler(&ui, &v, &st);
    const r = ui.lastRect(core.Context.idOf("ruler") ^ 0x810E) orelse return error.NoHit;

    ui.input = .{ .mouse = .{ .x = r.x + 100, .y = r.y + 20 }, .down = true, .pressed = true };
    runRuler(&ui, &v, &st);
    ui.input = .{ .mouse = .{ .x = r.x + 100, .y = r.y + 20 }, .down = true, .pressed = true };
    runRuler(&ui, &v, &st);
    try std.testing.expect(st.dragging);

    // 右拖 25px → +2.5 → 52.5（未吸附）
    ui.input = .{ .mouse = .{ .x = r.x + 125, .y = r.y + 20 }, .down = true };
    runRuler(&ui, &v, &st);
    try std.testing.expect(v > 52 and v < 53);

    ui.input = .{ .mouse = .{ .x = r.x + 125, .y = r.y + 20 }, .down = false };
    runRuler(&ui, &v, &st);
    try std.testing.expectApproxEqAbs(@as(f32, 53), v, 0.01);
}

// ---------------------------------------------------------------- 直方图

fn runHist(ui: *core.Context, lo: *f32, hi: *f32) void {
    ui.begin(500, 260);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    const bins = [_]f32{ 1, 3, 6, 9, 4, 2 };
    _ = pickers.histogramSlider(ui, "hist", bins[0..], lo, hi, 0, 100, .{});
    ui.paint();
}

test "pickers histogram slider drags the low thumb" {
    var ui = core.Context{};
    var lo: f32 = 20;
    var hi: f32 = 80;
    runHist(&ui, &lo, &hi);
    runHist(&ui, &lo, &hi);

    // 找轨道：总宽 rect.w，lo 在 20% 处
    const lo_id = core.Context.idOf("hist") ^ 0x1001;
    const r = ui.lastRect(lo_id) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 }, .down = true, .pressed = true };
    runHist(&ui, &lo, &hi);
    // 拖到左边 30px
    ui.input = .{ .mouse = .{ .x = r.x + r.w / 2 - 30, .y = r.y + r.h / 2 }, .down = true };
    runHist(&ui, &lo, &hi);
    try std.testing.expect(lo < 20);
    try std.testing.expectApproxEqAbs(@as(f32, 80), hi, 0.01);
}

// ---------------------------------------------------------------- 签名板

fn runSig(ui: *core.Context, st: *pickers.SignatureState) void {
    ui.begin(500, 320);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    _ = pickers.signaturePad(ui, "sig", st, .{ .height = 140 });
    ui.paint();
}

test "pickers signature pad records points and clears" {
    var ui = core.Context{};
    var st = pickers.SignatureState{};
    runSig(&ui, &st);
    const r = ui.lastRect(core.Context.idOf("sig") ^ 0x5167) orelse return error.NoHit;

    ui.input = .{ .mouse = .{ .x = r.x + 20, .y = r.y + 40 }, .down = true, .pressed = true };
    runSig(&ui, &st);
    try std.testing.expectEqual(@as(usize, 1), st.n_pts);

    // 拖动两次（每次 >= 2px）
    ui.input = .{ .mouse = .{ .x = r.x + 40, .y = r.y + 50 }, .down = true };
    runSig(&ui, &st);
    ui.input = .{ .mouse = .{ .x = r.x + 70, .y = r.y + 60 }, .down = true };
    runSig(&ui, &st);
    try std.testing.expectEqual(@as(usize, 3), st.n_pts);

    // 松手 → 一条笔画
    ui.input = .{ .down = false };
    runSig(&ui, &st);
    try std.testing.expectEqual(@as(usize, 1), st.n_strokes);
    try std.testing.expectEqual(@as(u16, 3), st.ends[0]);

    const pts = pickers.signaturePoints(&st);
    try std.testing.expectEqual(@as(usize, 3), pts.points.len);
    try std.testing.expectEqual(@as(usize, 1), pts.strokes);

    pickers.signatureClear(&st);
    try std.testing.expect(st.isEmpty());
}

// 冒烟：所有选择器同页不溢出
test "smoke: all pickers build without overflowing" {
    var ui = core.Context{};
    var ms_sel = [3]bool{ true, false, false };
    var ms_st = pickers.PopupState{};
    var shown = pickers.Date{ .year = 2026, .month = 11, .day = 1 };
    var range = pickers.DateRange{ .start = .{ .year = 2026, .month = 11, .day = 1 }, .end = .{ .year = 2026, .month = 11, .day = 5 } };
    var dr_st = pickers.PopupState{};
    var h: i32 = 9;
    var m: i32 = 30;
    var tp_st = pickers.PopupState{};
    var w_idx: usize = 1;
    var w_st = pickers.WheelState{ .pos = 1 };
    var ruler_v: f32 = 40;
    var ruler_st = pickers.RulerState{};
    var hist_lo: f32 = 20;
    var hist_hi: f32 = 70;
    var sig = pickers.SignatureState{};

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(760, 1400);
        var col = ui.column(.{ .pad = 20, .gap = 12 });
        defer col.end();
        _ = pickers.multiSelect(&ui, "s-ms", ms_items[0..], ms_sel[0..], &ms_st, .{});
        _ = pickers.dateRangePicker(&ui, "s-dr", &shown, &range, &dr_st, .{});
        _ = pickers.timePicker(&ui, "s-tp", &h, &m, &tp_st, .{});
        _ = pickers.wheelPicker(&ui, "s-w", ms_items[0..], &w_idx, &w_st, .{});
        _ = pickers.timeDial(&ui, "s-dial", &h, &m, 160);
        _ = pickers.rulerSlider(&ui, "s-ruler", &ruler_v, 0, 100, &ruler_st, .{});
        const bins = [_]f32{ 1, 3, 6, 9, 4, 2 };
        _ = pickers.histogramSlider(&ui, "s-hist", bins[0..], &hist_lo, &hist_hi, 0, 100, .{});
        _ = pickers.signaturePad(&ui, "s-sig", &sig, .{ .height = 120 });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}
