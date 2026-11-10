//! 旋钮族 / 代码呈现族 / 月历族 / 时间线族的测试（由 `tests.zig` 引入）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const dials = @import("dials.zig");
const codeview = @import("codeview.zig");
const month = @import("month.zig");
const timeline = @import("timeline.zig");
const t = @import("types.zig");

// ---------------------------------------------------------------- 旋钮族

// 旋钮上下拖拽改值（向上变大），Shift 精细。
test "knob drags upward to increase its value" {
    var ui = core.Context{};
    var v: f32 = 50;
    var st = dials.KnobState{};
    const id = core.Context.idOf("knob") ^ 0x4B0B;

    ui.begin(300, 300);
    var row = ui.row(.{});
    _ = dials.knob(&ui, "knob", &v, 0, 100, &st, .{ .step = 1 });
    row.end();
    ui.paint();
    const r = ui.lastRect(id) orelse return error.NoHit;

    // 按下
    ui.input = .{ .mouse = .{ .x = r.x + 10, .y = r.y + 30 }, .down = true, .pressed = true };
    ui.begin(300, 300);
    var row2 = ui.row(.{});
    _ = dials.knob(&ui, "knob", &v, 0, 100, &st, .{ .step = 1 });
    row2.end();
    ui.paint();

    // 向上拖 60px → 120 满量程的一半
    ui.input = .{ .mouse = .{ .x = r.x + 10, .y = r.y - 30 }, .down = true };
    ui.begin(300, 300);
    var row3 = ui.row(.{});
    const changed = dials.knob(&ui, "knob", &v, 0, 100, &st, .{ .step = 1 });
    row3.end();
    ui.paint();

    try std.testing.expect(changed);
    try std.testing.expect(v > 50);
    try std.testing.expect(v <= 100);
}

// 旋钮的对数映射：等转角等倍率（每个八度处在中点）。
test "knob log scale maps octaves evenly" {
    var ui = core.Context{};
    var v: f32 = 100;
    var st = dials.KnobState{};
    _ = &st;
    // 直接验证映射：用 knob 的公开行为不便断言内部比例，
    // 这里改为验证「min 到 max 的等比中点」——通过拖拽一半行程后再读值。
    ui.begin(300, 300);
    var row = ui.row(.{});
    _ = dials.knob(&ui, "k2", &v, 100, 800, &st, .{ .log_scale = true });
    row.end();
    ui.paint();
    const id = core.Context.idOf("k2") ^ 0x4B0B;
    const r = ui.lastRect(id) orelse return error.NoHit;

    ui.input = .{ .mouse = .{ .x = r.x + 10, .y = r.y + 30 }, .down = true, .pressed = true };
    ui.begin(300, 300);
    var row2 = ui.row(.{});
    _ = dials.knob(&ui, "k2", &v, 100, 800, &st, .{ .log_scale = true });
    row2.end();
    ui.paint();

    // 向上 60px = 半个行程 → 几何中点 ≈ 283
    ui.input = .{ .mouse = .{ .x = r.x + 10, .y = r.y - 30 }, .down = true };
    ui.begin(300, 300);
    var row3 = ui.row(.{});
    _ = dials.knob(&ui, "k2", &v, 100, 800, &st, .{ .log_scale = true });
    row3.end();
    ui.paint();

    try std.testing.expectApproxEqAbs(@as(f32, 282.8), v, 12);
}

// 推子拖动与方向键步进。
test "fader drags and steps with the keyboard" {
    var ui = core.Context{};
    var v: f32 = 0;
    var st = dials.FaderState{};
    const id = core.Context.idOf("fd") ^ 0xFA0E;

    ui.begin(300, 400);
    var row = ui.row(.{});
    _ = dials.fader(&ui, "fd", &v, 0, 1, &st, .{ .length = 100, .step = 0.1 });
    row.end();
    ui.paint();
    const r = ui.lastRect(id) orelse return error.NoHit;

    ui.input = .{ .mouse = .{ .x = r.x + r.w / 2, .y = r.y + 40 }, .down = true, .pressed = true };
    ui.begin(300, 400);
    var row2 = ui.row(.{});
    _ = dials.fader(&ui, "fd", &v, 0, 1, &st, .{ .length = 100, .step = 0.1 });
    row2.end();
    ui.paint();

    // 向上拖 50px = 半个轨道
    ui.input = .{ .mouse = .{ .x = r.x + r.w / 2, .y = r.y - 10 }, .down = true };
    ui.begin(300, 400);
    var row3 = ui.row(.{});
    const changed = dials.fader(&ui, "fd", &v, 0, 1, &st, .{ .length = 100, .step = 0.1 });
    row3.end();
    ui.paint();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), v, 0.12);
}

// 电平表：dB 换算与峰值保持不越界，且分段模式也不溢出容量。
test "level meter keeps peaks and stays inside its rect" {
    var ui = core.Context{};
    var st = dials.LevelMeterState{};
    const levels = [_]f32{ 0.5, 0.001, 1.0 };

    ui.time = 1;
    ui.begin(400, 300);
    var row = ui.row(.{});
    dials.levelMeter(&ui, "lm", levels[0..], &st, .{ .length = 120, .segmented = true });
    row.end();
    ui.paint();

    try std.testing.expect(st.peaks[2] > 0.9);
    try std.testing.expect(!ui.overflowed);

    // 第二帧电平归零：峰值仍保持（hold 未到）
    ui.time = 1.2;
    const zero = [_]f32{ 0, 0, 0 };
    ui.begin(400, 300);
    var row2 = ui.row(.{});
    dials.levelMeter(&ui, "lm", zero[0..], &st, .{ .length = 120, .hold = 1.5 });
    row2.end();
    ui.paint();
    try std.testing.expect(st.peaks[2] > 0.9);
}

// ---------------------------------------------------------------- 代码 / JSON / 十六进制

// 代码块：行号与高亮行都画出来，且不死循环。
test "code block draws numbered lines and highlights a range" {
    var ui = core.Context{};
    const code = "const a = 1;\nconst b = 2;\nconst c = 3;";

    ui.begin(500, 300);
    codeview.codeBlock(&ui, "cb", code, .{ .title = "main.zig", .lang = "zig", .highlight_from = 2, .highlight_to = 2 });
    ui.paint();

    try std.testing.expect(!ui.overflowed);
    // 3 行正文 + 3 个行号 + 1 条高亮 + 底框 + 标题栏 ≈ 9 个节点以上
    try std.testing.expect(ui.node_count >= 8);
}

// 代码块可滚动（超过 max_height 时用滚动区，不溢出）。
test "code block scrolls when it exceeds max height" {
    var ui = core.Context{};
    const code = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10";
    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(500, 200);
        codeview.codeBlock(&ui, "cbs", code, .{ .max_height = 60 });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}

// JSON 视图：折叠根容器后行数变少。
test "json view collapses a container" {
    var ui = core.Context{};
    const json = "{\"a\":1,\"b\":{\"c\":2},\"d\":3}";
    var st = codeview.JsonState{};

    ui.begin(500, 400);
    _ = codeview.jsonView(&ui, "jv", json, &st, .{});
    const open_lines = ui.node_count;
    ui.paint();

    // 找到第一行的折叠三角并点击
    const tri_id = core.Context.idOf("jv") ^ 0x1500;
    const r = ui.lastRect(tri_id) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(500, 400);
    const changed = codeview.jsonView(&ui, "jv", json, &st, .{});
    ui.paint();

    try std.testing.expect(changed);
    try std.testing.expect(ui.node_count < open_lines);
}

// 十六进制视图：点击选中字节、悬停能算出偏移。
test "hex view selects a byte under the pointer" {
    var ui = core.Context{};
    const data = "0123456789abcdef0123456789abcdef";
    var sel = codeview.HexSelection{};

    ui.begin(620, 300);
    const r1 = codeview.hexView(&ui, "hx", data, &sel, .{});
    ui.paint();
    try std.testing.expectEqual(@as(i64, -1), r1.hovered);

    // 点第一行第三个字节（列宽 3 个等宽字符，行高约 17）
    const id = core.Context.idOf("hx") ^ 0x4E8;
    const rr = ui.lastRect(id) orelse return error.NoHit;
    const cw = ui.measureText("00000000", 12).w / 8;
    const bx = rr.x + 8 + cw * 9 + cw * 3 * 2.5;
    const by = rr.y + 26 + 8;

    ui.input = .{ .mouse = .{ .x = bx, .y = by }, .click = .{ .x = bx, .y = by } };
    ui.begin(620, 300);
    const r2 = codeview.hexView(&ui, "hx", data, &sel, .{});
    ui.paint();

    try std.testing.expect(r2.selection_changed);
    try std.testing.expectEqual(@as(usize, 2), sel.start);
    try std.testing.expectEqual(@as(usize, 1), sel.length);
}

// hex_view_goto：直接定位到指定偏移。
test "hex view goto moves the cursor" {
    var sel = codeview.HexSelection{};
    codeview.hexViewGoto(&sel, 12);
    try std.testing.expectEqual(@as(usize, 12), sel.cursor);
    try std.testing.expectEqual(@as(usize, 1), sel.length);
}

// ---------------------------------------------------------------- 月历

// 民用历算法自检：闰年、月份长度、已知星期。
test "calendar arithmetic matches known dates" {
    try std.testing.expect(month.isLeap(2024));
    try std.testing.expect(!month.isLeap(2023));
    try std.testing.expect(!month.isLeap(1900));
    try std.testing.expect(month.isLeap(2000));
    try std.testing.expectEqual(@as(u8, 29), month.daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u8, 28), month.daysInMonth(2023, 2));
    // 2026-11-10 是周二（0 = 周一）
    try std.testing.expectEqual(@as(u8, 1), month.weekdayOf(.{ .year = 2026, .month = 11, .day = 10 }));
    // 1970-01-01 是周四
    try std.testing.expectEqual(@as(u8, 3), month.weekdayOf(.{ .year = 1970, .month = 1, .day = 1 }));
}

// 月历：点日期格选中该日；点右箭头翻到下月。
test "month calendar selects a day and pages forward" {
    var ui = core.Context{};
    var cur = month.Date{ .year = 2026, .month = 11, .day = 1 };
    var sel = month.Date{ .year = 2026, .month = 11, .day = 1 };
    const events = [_]month.MonthEvent{
        .{ .title = "Standup", .start = .{ .year = 2026, .month = 11, .day = 10 } },
    };

    ui.begin(640, 620);
    const r1 = month.monthCalendar(&ui, "mc", &cur, events[0..], .{ .selected = &sel, .today = .{ .year = 2026, .month = 11, .day = 10 } });
    ui.paint();
    try std.testing.expect(!r1.day_clicked);

    // 2026-11-10：lead = weekday(1 Nov 2026) = 周日(6)，所以格子下标 = 6 + 9 = 15
    const cell_id = core.Context.idOf("mc") ^ (0xD00 + 15);
    const cr = ui.lastRect(cell_id) orelse return error.NoHit;
    const cx = cr.x + cr.w / 2;
    const cy = cr.y + cr.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(640, 620);
    const r2 = month.monthCalendar(&ui, "mc", &cur, events[0..], .{ .selected = &sel, .today = .{ .year = 2026, .month = 11, .day = 10 } });
    ui.paint();
    try std.testing.expect(r2.day_clicked);
    try std.testing.expectEqual(@as(u8, 10), sel.day);

    // 翻月
    const next_id = core.Context.idOf("mc") ^ 0x60D8;
    const nr = ui.lastRect(next_id) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = nr.x + nr.w / 2, .y = nr.y + nr.h / 2 }, .click = .{ .x = nr.x + nr.w / 2, .y = nr.y + nr.h / 2 } };
    ui.begin(640, 620);
    const r3 = month.monthCalendar(&ui, "mc", &cur, events[0..], .{ .selected = &sel, .today = .{ .year = 2026, .month = 11, .day = 10 } });
    ui.paint();
    try std.testing.expect(r3.month_changed);
    try std.testing.expectEqual(@as(u8, 12), cur.month);
}

// 月历：点事件条返回事件下标。
test "month calendar reports a clicked event" {
    var ui = core.Context{};
    var cur = month.Date{ .year = 2026, .month = 11, .day = 1 };
    const events = [_]month.MonthEvent{
        .{ .title = "Release", .start = .{ .year = 2026, .month = 11, .day = 10 } },
    };

    ui.begin(640, 700);
    _ = month.monthCalendar(&ui, "mc2", &cur, events[0..], .{ .today = .{ .year = 2026, .month = 11, .day = 10 } });
    ui.paint();

    const ev_id = core.Context.idOf("mc2") ^ 0xE00;
    const r = ui.lastRect(ev_id) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(640, 700);
    const res = month.monthCalendar(&ui, "mc2", &cur, events[0..], .{ .today = .{ .year = 2026, .month = 11, .day = 10 } });
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), res.event);
}

// ---------------------------------------------------------------- 时间线

// 时间线：标尺点击移动播放头；关键帧可被点选。
test "timeline scrubs the playhead and picks a key" {
    var ui = core.Context{};
    var keys = [_]timeline.TimelineKey{ .{ .time = 2, .value = 0.5 }, .{ .time = 6, .value = 0.8 } };
    var tracks = [_]timeline.TimelineTrack{.{ .name = "Position", .keys = keys[0..] }};
    var playhead: f32 = 0;
    var st = timeline.TimelineState{};

    ui.begin(640, 300);
    _ = timeline.timelineEditor(&ui, "tl", tracks[0..], &playhead, &st, .{ .time_max = 10 });
    ui.paint();

    // 在标尺上点 5 秒附近
    const lane_x = 96.0;
    const lane_w = 640.0 - 96.0 - 12.0;
    const x5 = lane_x + lane_w * 0.5;
    ui.input = .{ .mouse = .{ .x = x5, .y = 10 }, .down = true, .pressed = true };
    ui.begin(640, 300);
    const r1 = timeline.timelineEditor(&ui, "tl", tracks[0..], &playhead, &st, .{ .time_max = 10 });
    ui.paint();
    try std.testing.expect(r1.scrubbing);
    try std.testing.expectApproxEqAbs(@as(f32, 5), playhead, 0.6);

    ui.input = .{ .mouse = .{ .x = x5, .y = 10 }, .down = false };
    ui.begin(640, 300);
    _ = timeline.timelineEditor(&ui, "tl", tracks[0..], &playhead, &st, .{ .time_max = 10 });
    ui.paint();

    // 点第 2 个关键帧（6 秒处）
    const kx = lane_x + lane_w * 0.6;
    const ky = 22 + 2 + 26 / 2;
    ui.input = .{ .mouse = .{ .x = kx, .y = ky }, .click = .{ .x = kx, .y = ky } };
    ui.begin(640, 300);
    const r2 = timeline.timelineEditor(&ui, "tl", tracks[0..], &playhead, &st, .{ .time_max = 10 });
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), r2.picked_track);
    try std.testing.expectEqual(@as(i32, 1), r2.picked_key);
    try std.testing.expect(tracks[0].keys[1].selected);
}

// 冒烟：旋钮 + 代码 + JSON + 十六进制 + 月历 + 时间线同页不溢出。
test "smoke: dials + codeview + month + timeline build without overflowing" {
    var ui = core.Context{};
    var knob_v: f32 = 30;
    var knob_st = dials.KnobState{};
    var fader_v: f32 = 0.4;
    var fader_st = dials.FaderState{};
    var meter_st = dials.LevelMeterState{};
    const levels = [_]f32{ 0.6, 0.3 };
    var sel = codeview.HexSelection{};
    var json_st = codeview.JsonState{};
    var cur = month.Date{ .year = 2026, .month = 11, .day = 1 };
    var keys = [_]timeline.TimelineKey{.{ .time = 3 }};
    var tracks = [_]timeline.TimelineTrack{.{ .name = "A", .keys = keys[0..] }};
    var playhead: f32 = 1;
    var tl_st = timeline.TimelineState{};

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(900, 1600);
        var col = ui.column(.{ .pad = 12, .gap = 10 });
        defer col.end();

        var row = ui.row(.{ .gap = 12 });
        _ = dials.knob(&ui, "k", &knob_v, 0, 100, &knob_st, .{ .label = "Gain", .unit = "%" });
        _ = dials.fader(&ui, "f", &fader_v, 0, 1, &fader_st, .{ .length = 100, .label = "Level" });
        dials.levelMeter(&ui, "m", levels[0..], &meter_st, .{ .length = 100 });
        row.end();

        codeview.codeBlock(&ui, "cb", "var x: u32 = 1;\nvar y = x + 1;", .{ .title = "main.zig", .highlight_from = 1, .highlight_to = 1 });
        _ = codeview.jsonView(&ui, "jv", "{\"name\":\"zzui\",\"tags\":[\"ui\",\"zig\"]}", &json_st, .{});
        _ = codeview.hexView(&ui, "hx", "The quick brown fox jumps over the lazy dog!!", &sel, .{ .height = 120 });
        _ = month.monthCalendar(&ui, "mc", &cur, &.{}, .{ .cell_height = 44 });
        _ = timeline.timelineEditor(&ui, "tl", tracks[0..], &playhead, &tl_st, .{ .height = 120, .time_max = 8 });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}
